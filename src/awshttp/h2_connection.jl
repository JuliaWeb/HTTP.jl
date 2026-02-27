# HTTP/2 Connection - Stream management, flow control, settings, GOAWAY, PING
# Port of aws-c-http/source/h2_connection.c, h2_connection.h

using Reseau: ReseauError

# ─── Pending GOAWAY ───

struct H2PendingGoaway
    allow_more_streams::Bool
    http2_error::UInt32
    debug_data::Memory{UInt8}
end

# ─── Pending PING ───

const _H2PingResult = Tuple{UInt64, Int}

mutable struct H2PendingPing
    opaque_data::Memory{UInt8}  # 8 bytes
    started_time_ns::UInt64
    future::EventLoops.Future{_H2PingResult}
end

# ─── Pending settings change ───

mutable struct H2PendingSettings
    settings::Vector{Http2Setting}
    future::EventLoops.Future{Int}
end

# ─── Stream closed reason ───

@enumx H2StreamClosedWhen::UInt8 begin
    UNKNOWN = 0
    BOTH_SIDES_END_STREAM = 1
    RST_STREAM_RECEIVED = 2
    RST_STREAM_SENT = 3
end

# ─── H2 Connection ───

const _H2_PENDING_SETTINGS_MAX = 16
const _H2_MIN_WINDOW_SIZE = 256

mutable struct H2Connection <: HttpConnection
    # ── Connection identity ──
    http_version::HttpVersion.T
    is_client::Bool
    on_incoming_request::Union{Nothing, Function}
    server_configured::Bool
    remote_endpoint::String

    # ── Frame encoder/decoder ──
    encoder::H2FrameEncoder
    decoder::H2Decoder
    incoming_buffer::Vector{UInt8}
    incoming_buffer_pos::Int

    # ── Stream management ──
    active_streams::Dict{UInt32, Any}  # stream_id => stream object (heterogeneous H2Stream types)
    next_stream_id::UInt32             # client=1, server=2; increments by 2
    latest_peer_stream_id::UInt32      # latest stream ID from peer

    # ── Settings (indexed by Http2SettingsId) ──
    settings_local::Dict{Http2SettingsId.T, UInt32}   # our confirmed settings
    settings_remote::Dict{Http2SettingsId.T, UInt32}   # peer's settings
    pending_settings_queue::Vector{H2PendingSettings}  # awaiting ACK

    # ── Flow control (connection level) ──
    window_size_peer::Int64     # peer's send window (reduced by DATA we receive)
    window_size_self::Int64     # our send window (reduced by DATA we send)
    manual_window_management::Bool
    window_size_threshold::UInt32  # threshold to send WINDOW_UPDATE

    # ── GOAWAY state ──
    goaway_sent_last_stream_id::UInt32
    goaway_sent_error_code::UInt32
    goaway_received_last_stream_id::UInt32
    goaway_received_error_code::UInt32
    goaway_sent::Bool
    goaway_received::Bool

    # ── PING state ──
    pending_pings::Vector{H2PendingPing}

    # ── State flags ──
    is_open::Bool
    new_requests_allowed::Bool
    connection_preface_sent::Bool
    connection_preface_received::Bool
    initial_settings_sent::Bool
    has_errored::Bool

    # ── Outgoing frame queue ──
    outgoing_frames::Vector{Memory{UInt8}}      # control frames
    outgoing_high_priority::Vector{Memory{UInt8}}  # high priority (PING ACK, SETTINGS ACK, etc.)

    # ── Callbacks ──
    # late-init: reassigned after construction in some usage patterns
    on_goaway_received::Union{Nothing, Function}    # (last_stream_id, error_code, debug_data) -> Nothing
    on_remote_settings_change::Union{Nothing, Function}  # (settings::Vector{Http2Setting}) -> Nothing
    on_shutdown::Union{Nothing, Function}           # (connection, error_code) -> Nothing

    # ── Channel integration ──
    # late-init: set by channel_slot_set_handler!
    slot::Union{Sockets.ChannelSlot, Nothing}
end

# Set the channel slot when installed in a pipeline.
function Sockets.setchannelslot!(handler::H2Connection, slot::Sockets.ChannelSlot)::Nothing
    handler.slot = slot
    if !handler.connection_preface_sent
        status, preface = h2_connection_get_preface(handler)
        if status == OP_SUCCESS && !isempty(preface)
            push!(handler.outgoing_frames, Memory{UInt8}(preface))
            handler.connection_preface_sent = true
            _h2_connection_flush_outgoing!(handler)
        end
    end
    return nothing
end

# ─── Connection creation ───

function h2_connection_new(;
    is_client::Bool=true,
    manual_window_management::Bool=false,
    initial_window_size::UInt32=UInt32(H2_INIT_WINDOW_SIZE),
    on_goaway_received=nothing,
    on_remote_settings_change=nothing,
    on_shutdown=nothing,
)::H2Connection

    # Initialize settings to RFC defaults
    settings_local = Dict{Http2SettingsId.T, UInt32}()
    settings_remote = Dict{Http2SettingsId.T, UInt32}()
    for (k, v) in H2_SETTINGS_INITIAL
        settings_local[k] = v
        settings_remote[k] = v
    end

    next_id = is_client ? UInt32(1) : UInt32(2)

    threshold = UInt32(initial_window_size ÷ 2)

    conn = H2Connection(
        HttpVersion.HTTP_2,
        is_client,
        nothing,
        false,
        "",
        # Encoder/decoder
        h2_frame_encoder_new(),
        h2_decoder_new(is_server=!is_client),
        UInt8[],
        1,
        # Streams
        Dict{UInt32, Any}(),
        next_id,
        UInt32(0),
        # Settings
        settings_local,
        settings_remote,
        H2PendingSettings[],
        # Flow control
        Int64(H2_INIT_WINDOW_SIZE),
        Int64(H2_INIT_WINDOW_SIZE),
        manual_window_management,
        threshold,
        # GOAWAY
        UInt32(H2_STREAM_ID_MAX),
        UInt32(0),
        UInt32(H2_STREAM_ID_MAX),
        UInt32(0),
        false, false,
        # PING
        H2PendingPing[],
        # State
        true, true, false, false, false, false,
        # Outgoing
        Memory{UInt8}[], Memory{UInt8}[],
        # Callbacks
        on_goaway_received,
        on_remote_settings_change,
        on_shutdown,
        # Channel integration
        nothing,  # slot
    )

    return conn
end

# ─── Connection preface ───

"""
    h2_connection_get_preface(conn) -> Vector{UInt8}

Get the connection preface bytes to send. Client: magic string + SETTINGS.
Server: SETTINGS frame only.
"""
function h2_connection_get_preface(conn::H2Connection)::Tuple{Int, Vector{UInt8}}
    output = UInt8[]

    # Client sends magic string first
    if conn.is_client
        append!(output, H2_CONNECTION_PREFACE_CLIENT)
    end

    # Both sides send initial SETTINGS
    initial_settings = Http2Setting[]
    # Send non-default settings
    for (k, v) in conn.settings_local
        if v != H2_SETTINGS_INITIAL[k]
            push!(initial_settings, Http2Setting(k, v))
        end
    end

    status, settings_frame = h2_encode_settings(initial_settings)
    if status != OP_SUCCESS
        return (status, UInt8[])
    end
    append!(output, settings_frame)

    # Track initial settings so we can process the peer's SETTINGS ACK
    push!(conn.pending_settings_queue, H2PendingSettings(copy(initial_settings), EventLoops.Future{Int}()))

    # If automatic window management, send WINDOW_UPDATE to expand connection window
    if !conn.manual_window_management
        extra = UInt32(H2_WINDOW_UPDATE_MAX) - UInt32(H2_INIT_WINDOW_SIZE)
        if extra > 0
            status2, wu_frame = h2_encode_window_update(UInt32(0), extra)
            if status2 == OP_SUCCESS
                append!(output, wu_frame)
                conn.window_size_self = Int64(H2_WINDOW_UPDATE_MAX)
            end
        end
    end

    conn.connection_preface_sent = true
    conn.initial_settings_sent = true
    return (OP_SUCCESS, output)
end

# ─── Settings management ───

@inline function _h2_ready_result(value)
    fut = EventLoops.Future{typeof(value)}()
    notify(fut, value)
    return fut
end

"""
    h2_connection_change_settings!(conn, settings) -> Future{Int}

Queue a SETTINGS frame to change local settings. The future resolves with
`OP_SUCCESS` once the peer acknowledges with SETTINGS ACK, or an error code.
"""
function h2_connection_change_settings!(conn::H2Connection, settings::Vector{Http2Setting})::EventLoops.Future{Int}
    if !conn.is_open
        raise_error(ERROR_HTTP_CONNECTION_CLOSED)
        return _h2_ready_result(ERROR_HTTP_CONNECTION_CLOSED)
    end
    if length(conn.pending_settings_queue) >= _H2_PENDING_SETTINGS_MAX
        raise_error(ERROR_INVALID_STATE)
        return _h2_ready_result(ERROR_INVALID_STATE)
    end

    # Validate settings
    for s in settings
        bounds = get(H2_SETTINGS_BOUNDS, s.id, nothing)
        if bounds === nothing
            raise_error(ERROR_INVALID_ARGUMENT)
            return _h2_ready_result(ERROR_INVALID_ARGUMENT)
        end
        if s.value < bounds[1] || s.value > bounds[2]
            raise_error(ERROR_INVALID_ARGUMENT)
            return _h2_ready_result(ERROR_INVALID_ARGUMENT)
        end
    end

    # Create and queue pending settings
    future = EventLoops.Future{Int}()
    pending = H2PendingSettings(copy(settings), future)
    push!(conn.pending_settings_queue, pending)

    # Encode and queue SETTINGS frame
    status, frame_data = h2_encode_settings(settings)
    if status != OP_SUCCESS
        pop!(conn.pending_settings_queue)
        notify(future, status)
        return future
    end
    push!(conn.outgoing_frames, frame_data)

    _h2_connection_flush_outgoing!(conn)
    return future
end

"""
    h2_connection_on_settings_received!(conn, settings) -> H2Err

Handle received SETTINGS frame from peer. Updates remote settings and sends ACK.
"""
function h2_connection_on_settings_received!(conn::H2Connection, settings::Vector{Http2Setting})::H2Err
    # Apply settings
    changed = Http2Setting[]
    for s in settings
        old_val = get(conn.settings_remote, s.id, nothing)
        if old_val === nothing || old_val != s.value
            conn.settings_remote[s.id] = s.value
            push!(changed, s)

            # Apply side effects
            if s.id == Http2SettingsId.HEADER_TABLE_SIZE
                h2_frame_encoder_set_setting_header_table_size!(conn.encoder, s.value)
            elseif s.id == Http2SettingsId.MAX_FRAME_SIZE
                h2_frame_encoder_set_setting_max_frame_size!(conn.encoder, s.value)
            elseif s.id == Http2SettingsId.INITIAL_WINDOW_SIZE
                # Adjust all active stream send windows by delta (RFC 7540 §6.9.2)
                if old_val !== nothing
                    delta = Int32(Int64(s.value) - Int64(old_val))
                    for (_, stream) in conn.active_streams
                        if stream isa H2Stream
                            h2_stream_window_size_change!(stream, delta, false)
                        end
                    end
                end
            end
        end
    end

    # Send SETTINGS ACK
    status, ack = h2_encode_settings(Http2Setting[]; ack=true)
    if status == OP_SUCCESS
        push!(conn.outgoing_high_priority, ack)
    end

    # Invoke callback
    if conn.on_remote_settings_change !== nothing && !isempty(changed)
        conn.on_remote_settings_change(changed)
    end

    return H2ERR_SUCCESS
end

function h2_connection_apply_remote_settings!(conn::H2Connection, settings::Vector{Http2Setting})::Int
    changed = Http2Setting[]
    for s in settings
        old_val = get(() -> nothing, conn.settings_remote, s.id)
        if old_val === nothing || old_val != s.value
            conn.settings_remote[s.id] = s.value
            push!(changed, s)
            if s.id == Http2SettingsId.HEADER_TABLE_SIZE
                h2_frame_encoder_set_setting_header_table_size!(conn.encoder, s.value)
            elseif s.id == Http2SettingsId.MAX_FRAME_SIZE
                h2_frame_encoder_set_setting_max_frame_size!(conn.encoder, s.value)
            elseif s.id == Http2SettingsId.INITIAL_WINDOW_SIZE
                if old_val !== nothing
                    delta = Int32(Int64(s.value) - Int64(old_val))
                    for (_, stream) in conn.active_streams
                        if stream isa H2Stream
                            h2_stream_window_size_change!(stream, delta, false)
                        end
                    end
                end
            end
        end
    end
    if conn.on_remote_settings_change !== nothing && !isempty(changed)
        conn.on_remote_settings_change(changed)
    end
    return OP_SUCCESS
end

"""
    h2_connection_on_settings_ack!(conn) -> H2Err

Handle received SETTINGS ACK. Confirms pending local settings.
"""
function h2_connection_on_settings_ack!(conn::H2Connection)::H2Err
    if isempty(conn.pending_settings_queue)
        return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
    end

    pending = popfirst!(conn.pending_settings_queue)

    # Apply confirmed settings locally
    for s in pending.settings
        old_val = get(conn.settings_local, s.id, nothing)
        conn.settings_local[s.id] = s.value

        # Apply side effects
        if s.id == Http2SettingsId.HEADER_TABLE_SIZE
            h2_decoder_set_setting_header_table_size!(conn.decoder, s.value)
        elseif s.id == Http2SettingsId.MAX_FRAME_SIZE
            h2_decoder_set_setting_max_frame_size!(conn.decoder, s.value)
        end
    end

    notify(pending.future, OP_SUCCESS)

    return H2ERR_SUCCESS
end

# ─── GOAWAY handling ───

"""
    h2_connection_send_goaway!(conn; allow_more_streams, error_code, debug_data) -> Int

Send a GOAWAY frame. If allow_more_streams, uses MAX_STREAM_ID to allow in-flight streams.
"""
function h2_connection_send_goaway!(conn::H2Connection;
    allow_more_streams::Bool=false,
    error_code::UInt32=UInt32(0),
    debug_data::AbstractVector{UInt8}=Memory{UInt8}(undef, 0))::Int

    if !conn.is_open
        return raise_error(ERROR_HTTP_CONNECTION_CLOSED)
    end

    last_stream = if allow_more_streams
        UInt32(H2_STREAM_ID_MAX)
    else
        min(conn.latest_peer_stream_id, conn.goaway_sent_last_stream_id)
    end

    # Can't send higher last_stream_id than previous GOAWAY
    if conn.goaway_sent && last_stream > conn.goaway_sent_last_stream_id
        last_stream = conn.goaway_sent_last_stream_id
    end

    status, frame_data = h2_encode_goaway(last_stream, error_code; debug_data=debug_data)
    if status != OP_SUCCESS
        return status
    end

    push!(conn.outgoing_high_priority, frame_data)
    conn.goaway_sent = true
    conn.goaway_sent_last_stream_id = last_stream
    conn.goaway_sent_error_code = error_code

    if !allow_more_streams
        conn.new_requests_allowed = false
    end

    _h2_connection_flush_outgoing!(conn)
    return OP_SUCCESS
end

"""
    h2_connection_on_goaway_received!(conn, last_stream_id, error_code, debug_data) -> H2Err

Handle received GOAWAY frame from peer.
"""
function h2_connection_on_goaway_received!(conn::H2Connection, last_stream_id::UInt32,
    error_code::UInt32, debug_data::AbstractVector{UInt8})::H2Err

    # last_stream_id must not increase
    if conn.goaway_received && last_stream_id > conn.goaway_received_last_stream_id
        return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
    end

    conn.goaway_received = true
    conn.goaway_received_last_stream_id = last_stream_id
    conn.goaway_received_error_code = error_code
    conn.new_requests_allowed = false

    # Invoke callback
    if conn.on_goaway_received !== nothing
        conn.on_goaway_received(last_stream_id, error_code, debug_data)
    end

    return H2ERR_SUCCESS
end

# ─── PING handling ───

"""
    h2_connection_send_ping!(conn, opaque_data) -> Future{Tuple{UInt64, Int}}

Send a PING frame. The future resolves with `(rtt_ns, error_code)` once
PING ACK is received.
"""
function h2_connection_send_ping!(
    conn::H2Connection,
    opaque_data::AbstractVector{UInt8}=zeros(UInt8, H2_PING_DATA_SIZE),
)::EventLoops.Future{_H2PingResult}
    if !conn.is_open
        raise_error(ERROR_HTTP_CONNECTION_CLOSED)
        return _h2_ready_result((UInt64(0), ERROR_HTTP_CONNECTION_CLOSED))
    end
    if length(opaque_data) != H2_PING_DATA_SIZE
        raise_error(ERROR_INVALID_ARGUMENT)
        return _h2_ready_result((UInt64(0), ERROR_INVALID_ARGUMENT))
    end

    timestamp = Reseau.monotonic_time_ns()
    opaque_copy = Memory{UInt8}(undef, H2_PING_DATA_SIZE)
    copyto!(opaque_copy, 1, opaque_data, 1, H2_PING_DATA_SIZE)
    future = EventLoops.Future{_H2PingResult}()
    pending = H2PendingPing(opaque_copy, UInt64(timestamp), future)
    push!(conn.pending_pings, pending)

    status, frame_data = h2_encode_ping(opaque_data; ack=false)
    if status != OP_SUCCESS
        pop!(conn.pending_pings)
        notify(future, (UInt64(0), status))
        return future
    end
    push!(conn.outgoing_frames, frame_data)

    _h2_connection_flush_outgoing!(conn)
    return future
end

"""
    h2_connection_on_ping!(conn, opaque_data) -> H2Err

Handle received PING (not ACK). Immediately queues PING ACK response.
"""
function h2_connection_on_ping!(conn::H2Connection, opaque_data::AbstractVector{UInt8})::H2Err
    status, ack_frame = h2_encode_ping(opaque_data; ack=true)
    if status == OP_SUCCESS
        push!(conn.outgoing_high_priority, ack_frame)
    end
    _h2_connection_flush_outgoing!(conn)
    return H2ERR_SUCCESS
end

"""
    h2_connection_on_ping_ack!(conn, opaque_data) -> H2Err

Handle received PING ACK. Matches with pending PING and calculates RTT.
"""
function h2_connection_on_ping_ack!(conn::H2Connection, opaque_data::AbstractVector{UInt8})::H2Err
    if isempty(conn.pending_pings)
        return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
    end

    pending = popfirst!(conn.pending_pings)

    if pending.opaque_data != opaque_data
        return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
    end

    rtt_ns = Reseau.monotonic_time_ns() - pending.started_time_ns
    notify(pending.future, (UInt64(rtt_ns), OP_SUCCESS))

    return H2ERR_SUCCESS
end

# ─── Flow control ───

"""
    h2_connection_update_window!(conn, increment) -> Int

Send a connection-level WINDOW_UPDATE frame.
"""
function h2_connection_update_window!(conn::H2Connection, increment::UInt32)::Int
    if increment == 0 || increment > H2_WINDOW_UPDATE_MAX
        return raise_error(ERROR_INVALID_ARGUMENT)
    end

    # Cap to prevent overflow
    new_window = conn.window_size_self + Int64(increment)
    if new_window > Int64(H2_WINDOW_UPDATE_MAX)
        return raise_error(ERROR_INVALID_ARGUMENT)
    end

    status, frame_data = h2_encode_window_update(UInt32(0), increment)
    if status != OP_SUCCESS
        return status
    end

    conn.window_size_self = new_window
    push!(conn.outgoing_frames, frame_data)
    _h2_connection_flush_outgoing!(conn)
    return OP_SUCCESS
end

# ─── Frame dispatch (decode incoming data) ───

"""
    h2_connection_decode!(conn, data) -> (H2Err, Vector{H2DecodedFrame}, Int)

Feed incoming data to the connection's frame decoder. Returns decoded frames
and the number of bytes consumed. Handles connection-level frames (SETTINGS,
GOAWAY, PING, WINDOW_UPDATE) internally. Returns stream-level frames (DATA,
HEADERS, RST_STREAM, PRIORITY) for the caller.
"""
function h2_connection_decode!(conn::H2Connection, data::AbstractVector{UInt8})::Tuple{H2Err, Vector{H2DecodedFrame}, Int}
    stream_frames = H2DecodedFrame[]
    pos = 1

    while pos <= length(data)
        err, frame, new_pos = h2_decode_frame(conn.decoder, data, pos)

        if h2err_failed(err)
            Reseau.logf(
                Reseau.LogLevel.ERROR,
                LS_HTTP_DECODER,
                "H2 $(conn.is_client ? "client" : "server") decode error h2_code=$(Int(err.h2_code)) aws_code=$(err.aws_code)",
            )
            conn.has_errored = true
            return (err, stream_frames, pos - 1)
        end

        # No progress = need more data
        if new_pos == pos
            break
        end
        pos = new_pos

        # Skip empty/incomplete frames
        if frame.frame_type == H2FrameType.UNKNOWN && frame.stream_id == 0 && frame.flags == 0
            continue
        end

        _h2_log_frame(conn, frame)

        # Dispatch connection-level frames internally
        dispatch_err = _h2_dispatch_connection_frame!(conn, frame)
        if h2err_failed(dispatch_err)
            Reseau.logf(
                Reseau.LogLevel.ERROR,
                LS_HTTP_DECODER,
                "H2 $(conn.is_client ? "client" : "server") dispatch error h2_code=$(Int(dispatch_err.h2_code)) aws_code=$(dispatch_err.aws_code)",
            )
            conn.has_errored = true
            return (dispatch_err, stream_frames, pos - 1)
        end

        # Pass stream-level frames to caller
        if frame.frame_type in (H2FrameType.DATA, H2FrameType.HEADERS,
            H2FrameType.RST_STREAM, H2FrameType.PRIORITY, H2FrameType.PUSH_PROMISE) ||
           (frame.frame_type == H2FrameType.WINDOW_UPDATE && frame.stream_id != 0)
            push!(stream_frames, frame)
        end
    end

    return (H2ERR_SUCCESS, stream_frames, pos - 1)
end

function _h2_log_frame(conn::H2Connection, frame::H2DecodedFrame)::Nothing
    role = conn.is_client ? "client" : "server"
    chan_id = if conn.slot !== nothing && conn.slot.channel !== nothing
        Int(conn.slot.channel.channel_id)
    else
        -1
    end
    if frame.frame_type == H2FrameType.DATA
        Reseau.logf(
            Reseau.LogLevel.TRACE,
            LS_HTTP_DECODER,
            "H2 $(role) frame DATA ch=$(chan_id) stream=$(Int(frame.stream_id)) flags=0x$(lpad(string(Int(frame.flags), base = 16), 2, '0')) end_stream=$(frame.end_stream ? 1 : 0) len=$(length(frame.data))",
        )
    elseif frame.frame_type == H2FrameType.HEADERS
        Reseau.logf(
            Reseau.LogLevel.TRACE,
            LS_HTTP_DECODER,
            "H2 $(role) frame HEADERS ch=$(chan_id) stream=$(Int(frame.stream_id)) flags=0x$(lpad(string(Int(frame.flags), base = 16), 2, '0')) end_stream=$(frame.end_stream ? 1 : 0) headers=$(length(frame.headers))",
        )
    else
        Reseau.logf(
            Reseau.LogLevel.TRACE,
            LS_HTTP_DECODER,
            "H2 $(role) frame $(h2_frame_type_to_str(frame.frame_type)) ch=$(chan_id) stream=$(Int(frame.stream_id)) flags=0x$(lpad(string(Int(frame.flags), base = 16), 2, '0')) end_stream=$(frame.end_stream ? 1 : 0)",
        )
    end
    return nothing
end

function _h2_dispatch_connection_frame!(conn::H2Connection, frame::H2DecodedFrame)::H2Err
    ft = frame.frame_type

    if ft == H2FrameType.SETTINGS
        if frame.ack
            return h2_connection_on_settings_ack!(conn)
        else
            return h2_connection_on_settings_received!(conn, frame.settings)
        end
    elseif ft == H2FrameType.PING
        if frame.ack
            return h2_connection_on_ping_ack!(conn, frame.opaque_data)
        else
            return h2_connection_on_ping!(conn, frame.opaque_data)
        end
    elseif ft == H2FrameType.GOAWAY
        return h2_connection_on_goaway_received!(conn, frame.last_stream_id,
            frame.goaway_error_code, frame.debug_data)
    elseif ft == H2FrameType.WINDOW_UPDATE && frame.stream_id == 0
        # Connection-level WINDOW_UPDATE
        if frame.window_increment == 0
            return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
        end
        new_window = conn.window_size_peer + Int64(frame.window_increment)
        if new_window > Int64(H2_WINDOW_UPDATE_MAX)
            return h2err_from_h2_code(Http2ErrorCode.FLOW_CONTROL_ERROR)
        end
        conn.window_size_peer = new_window
        return H2ERR_SUCCESS
    end

    return H2ERR_SUCCESS
end

# ─── Outgoing frame collection ───

"""
    h2_connection_get_outgoing_frames!(conn) -> Vector{UInt8}

Collect all queued outgoing frames (high priority first) into a single buffer.
Clears the outgoing queues.
"""
function h2_connection_get_outgoing_frames!(conn::H2Connection)::Vector{UInt8}
    output = UInt8[]

    # High priority first (PING ACK, SETTINGS ACK, RST_STREAM, GOAWAY)
    for frame in conn.outgoing_high_priority
        append!(output, frame)
    end
    empty!(conn.outgoing_high_priority)

    # Normal priority
    for frame in conn.outgoing_frames
        append!(output, frame)
    end
    empty!(conn.outgoing_frames)

    return output
end

# ─── Query functions ───

function h2_connection_get_local_settings(conn::H2Connection)::Dict{Http2SettingsId.T, UInt32}
    return copy(conn.settings_local)
end

function h2_connection_get_remote_settings(conn::H2Connection)::Dict{Http2SettingsId.T, UInt32}
    return copy(conn.settings_remote)
end

function h2_connection_get_sent_goaway(conn::H2Connection)::Tuple{Bool, UInt32, UInt32}
    return (conn.goaway_sent, conn.goaway_sent_last_stream_id, conn.goaway_sent_error_code)
end

function h2_connection_get_received_goaway(conn::H2Connection)::Tuple{Bool, UInt32, UInt32}
    return (conn.goaway_received, conn.goaway_received_last_stream_id, conn.goaway_received_error_code)
end

# ─── Internal: auto window updates ───

function _h2_connection_auto_window_update!(conn::H2Connection)::Nothing
    if conn.window_size_self < conn.window_size_threshold
        increment = UInt32(H2_WINDOW_UPDATE_MAX) - UInt32(max(0, conn.window_size_self))
        if increment > 0 && increment <= UInt32(H2_WINDOW_UPDATE_MAX)
            status, frame = h2_encode_window_update(UInt32(0), increment)
            if status == OP_SUCCESS
                conn.window_size_self = Int64(H2_WINDOW_UPDATE_MAX)
                push!(conn.outgoing_frames, frame)
            end
        end
    end
    return nothing
end

function _h2_connection_collect_stream_frames!(conn::H2Connection)::Vector{UInt8}
    output = UInt8[]
    for stream in values(conn.active_streams)
        stream isa H2Stream || continue
        while h2_stream_has_outgoing_data(stream) && !h2_stream_is_write_stalled(stream, conn)
            status, encode_status = h2_stream_encode_data_frame!(stream, conn)
            status != OP_SUCCESS && break
            encode_status == H2DataEncodeStatus.ONGOING_WINDOW_STALL && break
            encode_status == H2DataEncodeStatus.COMPLETE && break
        end
        frames = h2_stream_get_outgoing_frames!(stream)
        !isempty(frames) && append!(output, frames)
    end
    return output
end

function _h2_connection_flush_outgoing!(conn::H2Connection)::Nothing
    slot = conn.slot
    slot === nothing && return nothing
    channel = slot.channel
    channel === nothing && return nothing

    if !Sockets.channel_thread_is_callers_thread(channel)
        task = Sockets.ChannelTask(Reseau.EventCallable(status -> begin
            Reseau.TaskStatus.T(status) == Reseau.TaskStatus.RUN_READY || return nothing
            try
                _h2_connection_flush_outgoing!(conn)
            catch e
                @error "h2 flush task failed" exception=(e, catch_backtrace())
            end
            return nothing
        end), "http_h2_flush_outgoing")
        Sockets.channel_schedule_task_now!(channel, task)
        return nothing
    end

    output = h2_connection_get_outgoing_frames!(conn)
    stream_frames = _h2_connection_collect_stream_frames!(conn)
    !isempty(stream_frames) && append!(output, stream_frames)
    isempty(output) && return nothing

    _h2_log_outgoing_frames(conn, output)

    msg = Sockets.IoMessage(length(output))
    buf = msg.message_data
    @inbounds for i in 1:length(output)
        buf.mem[i] = output[i]
    end
    buf.len = Csize_t(length(output))
    try
        Sockets.channel_slot_send_message(slot, msg, Sockets.ChannelDirection.WRITE)
    catch e
        if e isa Reseau.ReseauError
            Sockets.channel_shutdown!(channel, e.code)
            return nothing
        end
        rethrow()
    end
    return nothing
end

function _h2_log_outgoing_frames(conn::H2Connection, output::Vector{UInt8})::Nothing
    role = conn.is_client ? "client" : "server"
    chan_id = if conn.slot !== nothing && conn.slot.channel !== nothing
        Int(conn.slot.channel.channel_id)
    else
        -1
    end
    pos = 1
    while pos + 8 <= length(output)
        prefix, next_pos = _h2_decode_frame_prefix(output, pos)
        ft = h2_frame_type_to_str(prefix.frame_type)
        end_stream = ((prefix.flags & H2_FRAME_F_END_STREAM) != 0) ? 1 : 0
        Reseau.logf(
            Reseau.LogLevel.TRACE,
            LS_HTTP_ENCODER,
            "H2 $(role) send frame $(ft) ch=$(chan_id) stream=$(Int(prefix.stream_id)) flags=0x$(lpad(string(Int(prefix.flags), base = 16), 2, '0')) end_stream=$(end_stream) len=$(Int(prefix.payload_len))",
        )
        pos = next_pos + Int(prefix.payload_len)
    end
    return nothing
end

function _h2_handle_stream_frame!(conn::H2Connection, frame::H2DecodedFrame)::H2Err
    sid = frame.stream_id
    if frame.frame_type == H2FrameType.HEADERS
        stream = get(conn.active_streams, sid, nothing)
        if stream === nothing
            if conn.is_client
                return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
            end
            if conn.on_incoming_request === nothing
                return h2err_from_aws_code(ERROR_HTTP_REACTION_REQUIRED)
            end
            stream = conn.on_incoming_request(conn)
            stream isa H2Stream || return h2err_from_aws_code(ERROR_INVALID_ARGUMENT)
            stream.id = sid
            stream.metrics = HttpStreamMetrics(
                stream.metrics.send_start_timestamp_ns,
                stream.metrics.send_end_timestamp_ns,
                stream.metrics.sending_duration_ns,
                stream.metrics.receive_start_timestamp_ns,
                stream.metrics.receive_end_timestamp_ns,
                stream.metrics.receiving_duration_ns,
                sid,
            )
            h2_stream_init_window_sizes!(stream, conn)
            conn.active_streams[sid] = stream
        end
        err = h2_stream_on_headers_begin!(stream)
        h2err_failed(err) && return err
        err = h2_stream_on_headers!(stream, frame.headers, frame.header_block_type, frame.end_stream)
        h2err_failed(err) && return err
        err = h2_stream_on_headers_end!(stream, frame.header_block_type, frame.end_stream)
        h2err_failed(err) && return err
        if stream.state == H2StreamState.CLOSED && stream.api_state != H2StreamApiState.COMPLETE
            h2_stream_complete!(stream, Reseau.OP_SUCCESS)
        end
        return H2ERR_SUCCESS
    elseif frame.frame_type == H2FrameType.DATA
        stream = get(conn.active_streams, sid, nothing)
        stream === nothing && return h2err_from_h2_code(Http2ErrorCode.STREAM_CLOSED)
        payload_len = UInt32(length(frame.data))
        if payload_len > 0
            if Int64(payload_len) > conn.window_size_self
                return h2err_from_h2_code(Http2ErrorCode.FLOW_CONTROL_ERROR)
            end
            conn.window_size_self -= Int64(payload_len)
        end
        err = h2_stream_on_data!(stream, frame.data, payload_len, frame.end_stream)
        h2err_failed(err) && return err
        if !conn.manual_window_management
            _h2_stream_auto_window_update!(stream)
            _h2_connection_auto_window_update!(conn)
        end
        if stream.state == H2StreamState.CLOSED && stream.api_state != H2StreamApiState.COMPLETE
            h2_stream_complete!(stream, Reseau.OP_SUCCESS)
        end
        return H2ERR_SUCCESS
    elseif frame.frame_type == H2FrameType.RST_STREAM
        stream = get(conn.active_streams, sid, nothing)
        stream === nothing && return H2ERR_SUCCESS
        err = h2_stream_on_rst_stream!(stream, frame.error_code)
        h2err_failed(err) && return err
        if stream.api_state != H2StreamApiState.COMPLETE
            h2_stream_complete!(stream, ERROR_HTTP_RST_STREAM_RECEIVED)
        end
        return H2ERR_SUCCESS
    elseif frame.frame_type == H2FrameType.PRIORITY
        stream = get(conn.active_streams, sid, nothing)
        stream === nothing && return H2ERR_SUCCESS
        frame.priority === nothing && return H2ERR_SUCCESS
        return h2_stream_update_priority!(stream, frame.priority)
    elseif frame.frame_type == H2FrameType.WINDOW_UPDATE
        if sid == 0
            if frame.window_increment == 0
                return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
            end
            new_window = conn.window_size_peer + Int64(frame.window_increment)
            if new_window > Int64(H2_WINDOW_UPDATE_MAX)
                return h2err_from_h2_code(Http2ErrorCode.FLOW_CONTROL_ERROR)
            end
            conn.window_size_peer = new_window
            return H2ERR_SUCCESS
        end
        stream = get(conn.active_streams, sid, nothing)
        stream === nothing && return H2ERR_SUCCESS
        err, window_resumed = h2_stream_on_window_update!(stream, frame.window_increment)
        h2err_failed(err) && return err
        if window_resumed
            _h2_connection_flush_outgoing!(conn)
        end
        return H2ERR_SUCCESS
    elseif frame.frame_type == H2FrameType.PUSH_PROMISE
        stream = get(conn.active_streams, sid, nothing)
        stream === nothing && return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
        err = h2_stream_on_push_promise!(stream, frame.promised_stream_id)
        h2err_failed(err) && return err
        if conn.is_client
            if get(conn.settings_local, Http2SettingsId.ENABLE_PUSH, UInt32(1)) == 0
                return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
            end
            promised_id = frame.promised_stream_id
            if promised_id == 0 || isodd(promised_id) || haskey(conn.active_streams, promised_id)
                return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
            end
            req = http2_message_new_request()
            status = http_message_add_header_array(req, frame.headers)
            if status != OP_SUCCESS
                return h2err_from_aws_code(Reseau.last_error())
            end
            promised_stream = h2_stream_new_push_promise(conn, promised_id, req)
            h2_stream_init_window_sizes!(promised_stream, conn)
            promised_stream.metrics = HttpStreamMetrics(
                promised_stream.metrics.send_start_timestamp_ns,
                promised_stream.metrics.send_end_timestamp_ns,
                promised_stream.metrics.sending_duration_ns,
                promised_stream.metrics.receive_start_timestamp_ns,
                promised_stream.metrics.receive_end_timestamp_ns,
                promised_stream.metrics.receiving_duration_ns,
                promised_id,
            )
            conn.active_streams[promised_id] = promised_stream
        end
        if stream.on_incoming_push_promise !== nothing
            stream.on_incoming_push_promise(stream, frame.promised_stream_id, frame.headers)
        end
        return H2ERR_SUCCESS
    end
    return H2ERR_SUCCESS
end

# ─── Connection interface implementation ───

http_connection_close(conn::H2Connection) = begin
    conn.is_open = false
    conn.new_requests_allowed = false
end

http_connection_is_open(conn::H2Connection) = conn.is_open

http_connection_new_requests_allowed(conn::H2Connection) = conn.new_requests_allowed && conn.is_open

http_connection_is_client(conn::H2Connection) = conn.is_client

http_connection_get_version(conn::H2Connection) = conn.http_version

function http_connection_make_request(
    conn::H2Connection;
    request::HttpMessage,
    on_response_headers=nothing,
    on_response_header_block_done=nothing,
    on_response_body=nothing,
    on_metrics=nothing,
    on_complete=nothing,
    on_destroy=nothing,
    http2_use_manual_data_writes::Bool=false,
    http2_priority=nothing,
    http2_headers_pad_length::UInt32=UInt32(0),
)::Union{H2Stream, Nothing}
    if !conn.is_client
        raise_error(ERROR_INVALID_STATE)
        return nothing
    end
    if !conn.is_open || !conn.new_requests_allowed
        raise_error(ERROR_HTTP_CONNECTION_CLOSED)
        return nothing
    end
    return h2_stream_new_request(
        conn;
        request=request,
        on_response_headers=on_response_headers,
        on_response_header_block_done=on_response_header_block_done,
        on_response_body=on_response_body,
        on_metrics=on_metrics,
        on_complete=on_complete,
        on_destroy=on_destroy,
        http2_use_manual_data_writes=http2_use_manual_data_writes,
        http2_priority=http2_priority,
        http2_headers_pad_length=http2_headers_pad_length,
    )
end

http_connection_stop_new_requests(conn::H2Connection) = begin conn.new_requests_allowed = false; nothing end

function http_connection_new_request_handler(
    conn::H2Connection;
    on_request_headers=nothing,
    on_request_header_block_done=nothing,
    on_request_body=nothing,
    on_request_done=nothing,
    on_complete=nothing,
    on_destroy=nothing,
)::Union{H2Stream, Nothing}
    if conn.is_client
        raise_error(ERROR_INVALID_STATE)
        return nothing
    end
    if !conn.is_open
        raise_error(ERROR_HTTP_CONNECTION_CLOSED)
        return nothing
    end
    return h2_stream_new_request_handler(
        conn;
        on_request_headers=on_request_headers,
        on_request_header_block_done=on_request_header_block_done,
        on_request_body=on_request_body,
        on_request_done=on_request_done,
        on_complete=on_complete,
        on_destroy=on_destroy,
    )
end

http_connection_get_remote_endpoint(conn::H2Connection)::String = conn.remote_endpoint

# ─── Channel handler interface ───

function Sockets.handler_process_read_message(conn::H2Connection, slot::Sockets.ChannelSlot, message::Sockets.IoMessage)::Nothing
    data = Reseau.byte_buffer_as_vector(message.message_data)
    try
        if !isempty(data)
            chan_id = if conn.slot !== nothing && conn.slot.channel !== nothing
                Int(conn.slot.channel.channel_id)
            else
                -1
            end
            Reseau.logf(
                Reseau.LogLevel.TRACE,
                LS_HTTP_DECODER,
                "H2 $(conn.is_client ? "client" : "server") received $(length(data)) bytes ch=$(chan_id)",
            )
            if length(data) <= 64
                Reseau.logf(
                    Reseau.LogLevel.TRACE,
                    LS_HTTP_DECODER,
                    "H2 $(conn.is_client ? "client" : "server") bytes ch=$(chan_id): $(_h2_hex_preview(data))",
                )
            end
            if conn.incoming_buffer_pos > length(conn.incoming_buffer)
                empty!(conn.incoming_buffer)
                conn.incoming_buffer_pos = 1
            end
            append!(conn.incoming_buffer, data)
            buffer_view = @view conn.incoming_buffer[conn.incoming_buffer_pos:end]
            err, frames, consumed = h2_connection_decode!(conn, buffer_view)
            if h2err_failed(err)
                Reseau.throw_error(err.aws_code != 0 ? err.aws_code : ERROR_HTTP_PROTOCOL_ERROR)
            end

            if consumed > 0
                conn.incoming_buffer_pos += consumed
                if conn.incoming_buffer_pos > length(conn.incoming_buffer)
                    empty!(conn.incoming_buffer)
                    conn.incoming_buffer_pos = 1
                elseif conn.incoming_buffer_pos > 4096 &&
                        conn.incoming_buffer_pos > length(conn.incoming_buffer) ÷ 2
                    remaining = length(conn.incoming_buffer) - conn.incoming_buffer_pos + 1
                    copyto!(conn.incoming_buffer, 1, conn.incoming_buffer, conn.incoming_buffer_pos, remaining)
                    resize!(conn.incoming_buffer, remaining)
                    conn.incoming_buffer_pos = 1
                end
            end

            for frame in frames
                frame_err = _h2_handle_stream_frame!(conn, frame)
                if h2err_failed(frame_err)
                    Reseau.logf(
                        Reseau.LogLevel.ERROR,
                        LS_HTTP_DECODER,
                        "H2 $(conn.is_client ? "client" : "server") stream frame error h2_code=$(Int(frame_err.h2_code)) aws_code=$(frame_err.aws_code)",
                    )
                    Reseau.throw_error(frame_err.aws_code != 0 ? frame_err.aws_code : ERROR_HTTP_PROTOCOL_ERROR)
                end
            end
            _h2_connection_flush_outgoing!(conn)
        end
        Sockets.channel_slot_increment_read_window!(slot, message.message_data.len)
    finally
        if slot.channel !== nothing
            Sockets.channel_release_message_to_pool!(slot.channel, message)
        end
    end
    return nothing
end

function _h2_hex_preview(data::AbstractVector{UInt8}, max_len::Int=32)::String
    n = min(length(data), max_len)
    parts = Vector{String}(undef, n)
    @inbounds for i in 1:n
        parts[i] = lpad(string(data[i], base = 16), 2, '0')
    end
    return join(parts, " ")
end

function Sockets.handler_process_write_message(conn::H2Connection, slot::Sockets.ChannelSlot, message::Sockets.IoMessage)::Nothing
    Sockets.channel_slot_send_message(slot, message, Sockets.ChannelDirection.WRITE)
    return nothing
end

function Sockets.handler_increment_read_window(conn::H2Connection, slot::Sockets.ChannelSlot, size::Csize_t)::Nothing
    Sockets.channel_slot_increment_read_window!(slot, size)
    return nothing
end

function Sockets.handler_shutdown(
    conn::H2Connection,
    slot::Sockets.ChannelSlot,
    direction::Sockets.ChannelDirection.T,
    error_code::Int,
    free_scarce_resources_immediately::Bool,
)::Nothing
    conn.is_open = false
    conn.new_requests_allowed = false
    err_code = error_code != 0 ? error_code : ERROR_HTTP_CONNECTION_CLOSED
    for stream in collect(values(conn.active_streams))
        stream isa H2Stream || continue
        h2_stream_complete!(stream, err_code)
    end
    Sockets.channel_slot_on_handler_shutdown_complete!(slot, direction, error_code, free_scarce_resources_immediately)
    return nothing
end

Sockets.handler_initial_window_size(conn::H2Connection)::Csize_t =
    conn.manual_window_management ? Csize_t(conn.window_size_self) : Csize_t(typemax(Csize_t))

Sockets.handler_message_overhead(conn::H2Connection)::Csize_t = Csize_t(0)

function Sockets.handler_destroy(conn::H2Connection)::Nothing
    empty!(conn.active_streams)
    empty!(conn.incoming_buffer)
    conn.incoming_buffer_pos = 1
    return nothing
end
