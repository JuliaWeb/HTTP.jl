# HTTP/2 Stream - Per-stream state machine, flow control, and frame generation
# Port of aws-c-http/source/h2_stream.c, h2_stream.h

# ─── Stream state (RFC 7540 section 5.1) ───

@enumx H2StreamState::UInt8 begin
    IDLE = 0
    RESERVED_LOCAL = 1
    RESERVED_REMOTE = 2
    OPEN = 3
    HALF_CLOSED_LOCAL = 4
    HALF_CLOSED_REMOTE = 5
    CLOSED = 6
end

const _H2_STREAM_STATE_STRINGS = Dict{H2StreamState.T, String}(
    H2StreamState.IDLE => "IDLE",
    H2StreamState.RESERVED_LOCAL => "RESERVED_LOCAL",
    H2StreamState.RESERVED_REMOTE => "RESERVED_REMOTE",
    H2StreamState.OPEN => "OPEN",
    H2StreamState.HALF_CLOSED_LOCAL => "HALF_CLOSED_LOCAL",
    H2StreamState.HALF_CLOSED_REMOTE => "HALF_CLOSED_REMOTE",
    H2StreamState.CLOSED => "CLOSED",
)

h2_stream_state_to_str(s::H2StreamState.T)::String = get(_H2_STREAM_STATE_STRINGS, s, "UNKNOWN")

# ─── Stream API state (simplified view for external users) ───

@enumx H2StreamApiState::UInt8 begin
    INIT = 0
    ACTIVE = 1
    COMPLETE = 2
end

# ─── Stream body state ───

@enumx H2StreamBodyState::UInt8 begin
    NONE = 0
    WAITING_WRITES = 1
    ONGOING = 2
end

# ─── Pending data write ───

mutable struct H2StreamDataWrite
    data::Vector{UInt8}       # data payload
    end_stream::Bool          # whether END_STREAM flag should be set
    pad_length::UInt8         # frame padding (0-255)
    on_complete::Any           # (error_code) -> Nothing
end

# ─── H2 Stream ───

const H2_PRIORITY_DEFAULT_WEIGHT = UInt16(16)

mutable struct H2Stream
    # ── Identity ──
    owning_connection::HttpConnection
    id::UInt32
    is_client::Bool

    # ── Callbacks ──
    on_incoming_headers::Any          # (stream, block_type, headers) -> Int
    on_incoming_header_block_done::Any  # (stream, block_type) -> Int
    on_incoming_body::Any             # (stream, data) -> Int
    on_request_done::Any              # (stream) -> Int (server only)
    on_metrics::Any                    # (stream, metrics) -> Nothing
    on_complete::Any                   # (stream, error_code) -> Nothing
    # late-init: reassigned after construction in some patterns
    on_destroy::Any                   # (stream) -> Nothing
    on_incoming_push_promise::Any    # (stream, promised_stream_id, headers) -> Nothing

    # ── Metrics ──
    metrics::HttpStreamMetrics

    # ── State machine ──
    state::H2StreamState.T
    api_state::H2StreamApiState.T
    body_state::H2StreamBodyState.T

    # ── Request/response data ──
    outgoing_message::Union{HttpMessage, Nothing}
    request_method::HttpMethod.T
    request_method_str::String
    request_path::String
    response_status::Int

    # ── Incoming state ──
    received_main_headers::Bool
    incoming_content_length::Int64   # -1 if no Content-Length
    incoming_data_length::Int64      # total DATA payload received

    # ── Outgoing state ──
    outgoing_trailing_headers::Union{HttpHeaders, Nothing}
    outgoing_trailing_pad_length::UInt8
    outgoing_headers_pad_length::UInt8
    outgoing_writes::Vector{H2StreamDataWrite}
    manual_write::Bool
    manual_write_ended::Bool
    end_stream_sent::Bool
    end_stream_received::Bool

    # ── RST_STREAM tracking ──
    sent_reset_error_code::Int64     # -1 if none
    received_reset_error_code::Int64 # -1 if none

    # ── Flow control (per-stream) ──
    window_size_peer::Int32     # peer's window for us to send DATA
    window_size_self::Int32     # our window for peer to send DATA
    window_size_threshold::Int32  # threshold to send WINDOW_UPDATE

    # ── Priority ──
    priority::Http2PrioritySettings

    # ── Outgoing frame buffer ──
    outgoing_frames::Vector{Memory{UInt8}}
end

# ─── Stream creation ───

function _h2_body_to_bytes(body)::Vector{UInt8}
    if body isa AbstractVector{UInt8}
        return copy(body)
    elseif body isa IOBuffer
        return take!(copy(body))
    elseif body isa IO
        return read(body)
    elseif body isa Sockets.AbstractInputStream
        out = UInt8[]
        buf = Vector{UInt8}(undef, 8192)
        while true
            n = readbytes!(body, buf, length(buf))
            n > 0 && append!(out, @view buf[1:n])
            n == 0 && eof(body) && break
        end
        return out
    end
    return UInt8[]
end

"""
    h2_stream_new_request(connection, options::HttpMakeRequestOptions) -> Union{H2Stream, Nothing}

Create a new client request stream. The stream is not yet active; call `h2_stream_activate!`.
"""
function h2_stream_new_request(connection, options::HttpMakeRequestOptions)::Union{H2Stream, Nothing}
    msg = options.request

    # Get the method for tracking
    method_str = http_message_get_request_method(msg)
    method_enum = method_str !== nothing ? http_str_to_method(method_str) : HttpMethod.UNKNOWN
    method_str_val = method_str === nothing ? "" : String(method_str)

    # Convert H1 messages to H2 if needed
    outgoing_msg = if http_message_get_protocol_version(msg) != HttpVersion.HTTP_2
        converted = http2_message_new_from_http1(msg)
        converted === nothing && return nothing
        converted
    else
        msg
    end

    # Track request path for server-side access
    path_str = http_message_get_request_path(outgoing_msg)
    path_str_val = path_str === nothing ? "" : String(path_str)

    # Determine body state
    has_body = http_message_get_body_stream(outgoing_msg) !== nothing
    manual = options.http2_use_manual_data_writes
    initial_body_state = if manual
        H2StreamBodyState.WAITING_WRITES
    elseif has_body
        H2StreamBodyState.ONGOING
    else
        H2StreamBodyState.NONE
    end
    if options.http2_headers_pad_length > typemax(UInt8)
        raise_error(ERROR_INVALID_ARGUMENT)
        return nothing
    end
    headers_pad_length = UInt8(options.http2_headers_pad_length)
    priority = options.http2_priority === nothing ? Http2PrioritySettings() : options.http2_priority

    stream = H2Stream(
        connection,
        UInt32(0),   # id assigned on activation
        true,        # is_client
        # Callbacks
        options.on_response_headers,
        options.on_response_header_block_done,
        options.on_response_body,
        nothing,  # on_request_done (client)
        options.on_metrics,
        options.on_complete,
        options.on_destroy,
        nothing,     # on_incoming_push_promise
        # Metrics
        HttpStreamMetrics(),
        # State
        H2StreamState.IDLE,
        H2StreamApiState.INIT,
        initial_body_state,
        # Request/response
        outgoing_msg,
        method_enum,
        method_str_val,
        path_str_val,
        HTTP_STATUS_CODE_UNKNOWN,
        # Incoming
        false,   # received_main_headers
        Int64(-1),  # incoming_content_length
        Int64(0),   # incoming_data_length
        # Outgoing
        nothing,  # trailing headers
        UInt8(0), UInt8(0),  # pad lengths
        H2StreamDataWrite[],
        manual,
        !manual,  # manual_write_ended: true if not manual (body comes from message)
        false, false,  # end_stream sent/received
        # RST
        Int64(-1), Int64(-1),
        # Flow control (initialized later)
        Int32(H2_INIT_WINDOW_SIZE),
        Int32(H2_INIT_WINDOW_SIZE),
        Int32(H2_INIT_WINDOW_SIZE ÷ 2),
        # Priority
        Http2PrioritySettings(),
        # Outgoing frames
        Memory{UInt8}[],
    )
    stream.priority = priority
    stream.outgoing_headers_pad_length = headers_pad_length

    # If body stream exists in non-manual mode, create an initial write from it
    if has_body && !manual
        body = http_message_get_body_stream(outgoing_msg)
        body_data = _h2_body_to_bytes(body)
        write_entry = H2StreamDataWrite(body_data, true, UInt8(0), nothing)
        push!(stream.outgoing_writes, write_entry)
    end

    return stream
end

"""
    h2_stream_new_request_handler(connection, options::HttpRequestHandlerOptions) -> H2Stream

Create a new server request handler stream for an incoming request.
"""
function h2_stream_new_request_handler(connection, options::HttpRequestHandlerOptions;
    manual_write::Bool=false)::H2Stream
    stream = H2Stream(
        connection,
        UInt32(0),
        false,  # is_client = false (server)
        # Callbacks
        options.on_request_headers,
        options.on_request_header_block_done,
        options.on_request_body,
        options.on_request_done,
        nothing,  # on_metrics
        options.on_complete,
        options.on_destroy,
        nothing,  # on_incoming_push_promise
        # Metrics
        HttpStreamMetrics(),
        # State
        H2StreamState.IDLE,
        H2StreamApiState.ACTIVE,
        H2StreamBodyState.NONE,
        # Request/response
        nothing,  # outgoing_message (set when sending response)
        HttpMethod.UNKNOWN,
        "",
        "",
        HTTP_STATUS_CODE_UNKNOWN,
        # Incoming
        false, Int64(-1), Int64(0),
        # Outgoing
        nothing, UInt8(0), UInt8(0),
        H2StreamDataWrite[],
        manual_write, !manual_write,  # manual_write, manual_write_ended
        false, false,
        # RST
        Int64(-1), Int64(-1),
        # Flow control
        Int32(H2_INIT_WINDOW_SIZE),
        Int32(H2_INIT_WINDOW_SIZE),
        Int32(H2_INIT_WINDOW_SIZE ÷ 2),
        # Priority
        Http2PrioritySettings(),
        # Outgoing frames
        Memory{UInt8}[],
    )
    return stream
end

"""
    h2_stream_new_push_promise(connection, promised_stream_id, request; kwargs...) -> H2Stream

Create a stream from a received PUSH_PROMISE frame (client side).
"""
function h2_stream_new_push_promise(connection, promised_stream_id::UInt32, request::HttpMessage;
    on_response_headers=nothing,
    on_response_header_block_done=nothing,
    on_response_body=nothing,
    on_complete=nothing,
    on_destroy=nothing,
)::H2Stream
    method_str = http_message_get_request_method(request)
    method_enum = method_str !== nothing ? http_str_to_method(method_str) : HttpMethod.UNKNOWN
    method_str_val = method_str === nothing ? "" : String(method_str)
    path_str = http_message_get_request_path(request)
    path_str_val = path_str === nothing ? "" : String(path_str)
    stream = H2Stream(
        connection,
        promised_stream_id,
        true,  # client receives push
        # Callbacks
        on_response_headers,
        on_response_header_block_done,
        on_response_body,
        nothing, # on_request_done (client)
        nothing, on_complete, on_destroy, nothing,
        # Metrics
        HttpStreamMetrics(),
        # State: RESERVED_REMOTE (push promise received)
        H2StreamState.RESERVED_REMOTE,
        H2StreamApiState.ACTIVE,
        H2StreamBodyState.NONE,
        # Request/response
        nothing,
        method_enum,
        method_str_val,
        path_str_val,
        HTTP_STATUS_CODE_UNKNOWN,
        # Incoming
        false, Int64(-1), Int64(0),
        # Outgoing
        nothing, UInt8(0), UInt8(0),
        H2StreamDataWrite[],
        false, true,
        false, false,
        # RST
        Int64(-1), Int64(-1),
        # Flow control
        Int32(H2_INIT_WINDOW_SIZE),
        Int32(H2_INIT_WINDOW_SIZE),
        Int32(H2_INIT_WINDOW_SIZE ÷ 2),
        # Priority
        Http2PrioritySettings(),
        Memory{UInt8}[],
    )
    return stream
end

# ─── Stream lifecycle ───


h2_stream_get_id(stream::H2Stream)::UInt32 = stream.id
h2_stream_get_state(stream::H2Stream)::H2StreamState.T = stream.state

function h2_stream_get_incoming_response_status(stream::H2Stream)::Int
    return stream.response_status
end

function h2_stream_get_connection(stream::H2Stream)
    return stream.owning_connection
end

http_stream_get_incoming_request_method(stream::H2Stream)::String = stream.request_method_str
http_stream_get_incoming_request_uri(stream::H2Stream)::String = stream.request_path

# ─── Window initialization ───

"""
    h2_stream_init_window_sizes!(stream, connection) -> Nothing

Initialize per-stream flow control windows from connection settings.
"""
function h2_stream_init_window_sizes!(stream::H2Stream, conn)::Nothing
    initial_window = get(conn.settings_remote, Http2SettingsId.INITIAL_WINDOW_SIZE,
                         UInt32(H2_INIT_WINDOW_SIZE))
    stream.window_size_peer = Int32(initial_window)

    local_initial = get(conn.settings_local, Http2SettingsId.INITIAL_WINDOW_SIZE,
                        UInt32(H2_INIT_WINDOW_SIZE))
    stream.window_size_self = Int32(local_initial)

    if conn.manual_window_management
        stream.window_size_threshold = Int32(local_initial ÷ 2)
    else
        # Auto: set threshold so we always immediately send updates
        stream.window_size_threshold = Int32(local_initial)
    end
    return nothing
end

# ─── Flow control ───

"""
    h2_stream_window_size_change!(stream, delta, is_self) -> H2Err

Handle window size change from SETTINGS INITIAL_WINDOW_SIZE or WINDOW_UPDATE.
`is_self` = true means local receive window, false means peer's send window for us.
"""
function h2_stream_window_size_change!(stream::H2Stream, delta::Int32, is_self::Bool)::H2Err
    if is_self
        new_val = Int64(stream.window_size_self) + Int64(delta)
        if new_val > Int64(H2_WINDOW_UPDATE_MAX)
            return h2err_from_h2_code(Http2ErrorCode.FLOW_CONTROL_ERROR)
        end
        stream.window_size_self = Int32(new_val)
    else
        new_val = Int64(stream.window_size_peer) + Int64(delta)
        if new_val > Int64(H2_WINDOW_UPDATE_MAX)
            return h2err_from_h2_code(Http2ErrorCode.FLOW_CONTROL_ERROR)
        end
        stream.window_size_peer = Int32(new_val)
    end
    return H2ERR_SUCCESS
end

"""
    h2_stream_update_window!(stream, increment) -> Int

Send a stream-level WINDOW_UPDATE frame (manual window management).
"""
function h2_stream_update_window!(stream::H2Stream, increment::UInt32)::Int
    if stream.state in (H2StreamState.CLOSED, H2StreamState.HALF_CLOSED_REMOTE)
        return OP_SUCCESS  # silently ignore
    end
    if increment == 0 || increment > UInt32(H2_WINDOW_UPDATE_MAX)
        return raise_error(ERROR_INVALID_ARGUMENT)
    end
    new_val = Int64(stream.window_size_self) + Int64(increment)
    if new_val > Int64(H2_WINDOW_UPDATE_MAX)
        return raise_error(ERROR_INVALID_ARGUMENT)
    end

    status, frame = h2_encode_window_update(stream.id, increment)
    if status != OP_SUCCESS
        return status
    end

    stream.window_size_self = Int32(new_val)
    push!(stream.outgoing_frames, frame)
    _h2_stream_maybe_flush!(stream)
    return OP_SUCCESS
end

# Internal: auto-send WINDOW_UPDATE if window drops below threshold
function _h2_stream_auto_window_update!(stream::H2Stream)::Nothing
    if stream.window_size_self < stream.window_size_threshold
        increment = UInt32(H2_WINDOW_UPDATE_MAX) - UInt32(max(0, stream.window_size_self))
        if increment > 0 && increment <= UInt32(H2_WINDOW_UPDATE_MAX)
            status, frame = h2_encode_window_update(stream.id, increment)
            if status == OP_SUCCESS
                stream.window_size_self = Int32(H2_WINDOW_UPDATE_MAX)
                push!(stream.outgoing_frames, frame)
            end
        end
    end
    return nothing
end

# ─── Stream activation ───

"""
    h2_stream_activate!(stream, conn) -> (Int, H2StreamBodyState.T)

Activate the stream: assign stream ID, send initial HEADERS frame.
Returns (status, body_state) where body_state indicates if body data follows.
"""
function h2_stream_activate!(stream::H2Stream, conn)::Tuple{Int, H2StreamBodyState.T}
    if stream.api_state != H2StreamApiState.INIT
        return (raise_error(ERROR_HTTP_STREAM_NOT_ACTIVATED), H2StreamBodyState.NONE)
    end

    # Assign stream ID
    if stream.id == 0
        stream.id = conn.next_stream_id
        conn.next_stream_id += UInt32(2)
    end

    stream.api_state = H2StreamApiState.ACTIVE

    # Initialize window sizes from connection settings
    h2_stream_init_window_sizes!(stream, conn)

    # Register in connection
    conn.active_streams[stream.id] = stream

    # Send HEADERS frame for the request
    if stream.outgoing_message !== nothing
        msg = stream.outgoing_message
        hdrs = http_message_get_headers(msg)

        has_body = stream.body_state != H2StreamBodyState.NONE
        end_stream = !has_body

        status, frame = h2_encode_headers(conn.encoder, stream.id, hdrs;
            end_stream=end_stream,
            priority=(stream.priority.stream_dependency != 0 || stream.priority.weight != H2_PRIORITY_DEFAULT_WEIGHT) ? stream.priority : nothing,
            pad_length=stream.outgoing_headers_pad_length)

        if status != OP_SUCCESS
            delete!(conn.active_streams, stream.id)
            return (status, H2StreamBodyState.NONE)
        end

        push!(stream.outgoing_frames, frame)

        # State transition
        if end_stream
            stream.state = H2StreamState.HALF_CLOSED_LOCAL
            stream.end_stream_sent = true
        else
            stream.state = H2StreamState.OPEN
        end
    end

    return (OP_SUCCESS, stream.body_state)
end

# ─── Stream completion ───

"""
    h2_stream_complete!(stream, error_code) -> Nothing

Complete the stream, invoke callbacks, clean up.
"""
function h2_stream_complete!(stream::H2Stream, error_code::Int)::Nothing
    Reseau.logf(
        Reseau.LogLevel.TRACE,
        LS_HTTP_STREAM,
        "H2 stream $(Int(stream.id)) complete error=$(error_code)",
    )
    stream.api_state = H2StreamApiState.COMPLETE
    stream.state = H2StreamState.CLOSED

    # Fail pending writes
    for w in stream.outgoing_writes
        if w.on_complete !== nothing
            w.on_complete(error_code)
        end
    end
    empty!(stream.outgoing_writes)

    stream.outgoing_message = nothing

    if stream.on_metrics !== nothing
        stream.on_metrics(stream, stream.metrics)
    end

    if stream.on_complete !== nothing
        stream.on_complete(stream, error_code)
    end

    # Unregister from connection
    conn = stream.owning_connection
    if conn !== nothing
        delete!(conn.active_streams, stream.id)
    end

    if stream.on_destroy !== nothing
        stream.on_destroy(stream)
    end
    return nothing
end

# ─── RST_STREAM handling ───

"""
    h2_stream_reset!(stream, h2_error_code) -> Int

Send RST_STREAM to terminate the stream with an HTTP/2 error code.
"""
function h2_stream_reset!(stream::H2Stream, h2_error_code::UInt32)::Int
    if stream.state == H2StreamState.CLOSED || stream.state == H2StreamState.IDLE
        return raise_error(ERROR_HTTP_STREAM_HAS_COMPLETED)
    end

    status, frame = h2_encode_rst_stream(stream.id, h2_error_code)
    if status != OP_SUCCESS
        return status
    end

    stream.sent_reset_error_code = Int64(h2_error_code)
    push!(stream.outgoing_frames, frame)

    # Close the stream
    stream.state = H2StreamState.CLOSED
    _h2_stream_maybe_flush!(stream)
    return OP_SUCCESS
end

"""
    h2_stream_cancel!(stream) -> Int

Cancel the stream by sending RST_STREAM with CANCEL error code.
"""
function h2_stream_cancel!(stream::H2Stream)::Int
    return h2_stream_reset!(stream, UInt32(Http2ErrorCode.CANCEL))
end

"""
    h2_stream_get_received_reset_error_code(stream) -> Int64

Get the error code from a received RST_STREAM, or -1 if none received.
"""
h2_stream_get_received_reset_error_code(stream::H2Stream)::Int64 = stream.received_reset_error_code

"""
    h2_stream_get_sent_reset_error_code(stream) -> Int64

Get the error code from a sent RST_STREAM, or -1 if none sent.
"""
h2_stream_get_sent_reset_error_code(stream::H2Stream)::Int64 = stream.sent_reset_error_code

# ─── Priority ───

"""
    h2_stream_update_priority!(stream, priority) -> Int

Send a PRIORITY frame to update the stream's priority.
"""
function h2_stream_update_priority!(stream::H2Stream, priority::Http2PrioritySettings)::Int
    if stream.state == H2StreamState.CLOSED
        return raise_error(ERROR_HTTP_STREAM_HAS_COMPLETED)
    end

    status, frame = h2_encode_priority_frame(stream.id, priority)
    if status != OP_SUCCESS
        return status
    end

    stream.priority = priority
    push!(stream.outgoing_frames, frame)
    _h2_stream_maybe_flush!(stream)
    return OP_SUCCESS
end

# ─── Manual data writes ───

"""
    h2_stream_write_data!(stream, data; end_stream=false, pad_length=0x00, on_complete=nothing) -> Int

Submit DATA for the stream (manual write mode).
"""
function h2_stream_write_data!(stream::H2Stream, data::AbstractVector{UInt8};
    end_stream::Bool=false,
    pad_length::UInt8=UInt8(0),
    on_complete=nothing)::Int

    if stream.api_state != H2StreamApiState.ACTIVE
        return raise_error(ERROR_HTTP_STREAM_HAS_COMPLETED)
    end
    if !stream.manual_write
        return raise_error(ERROR_HTTP_MANUAL_WRITE_NOT_ENABLED)
    end
    if stream.manual_write_ended
        return raise_error(ERROR_HTTP_MANUAL_WRITE_HAS_COMPLETED)
    end

    if end_stream
        stream.manual_write_ended = true
    end

    write_entry = H2StreamDataWrite(copy(data), end_stream, pad_length, on_complete)
    push!(stream.outgoing_writes, write_entry)

    if stream.body_state == H2StreamBodyState.WAITING_WRITES
        stream.body_state = H2StreamBodyState.ONGOING
    end

    _h2_stream_maybe_flush!(stream)
    return OP_SUCCESS
end

# ─── Trailing headers ───

"""
    h2_stream_add_trailing_headers!(stream, headers; pad_length=0x00) -> Int

Add trailing headers to be sent after the body completes.
"""
function h2_stream_add_trailing_headers!(stream::H2Stream, headers::HttpHeaders;
    pad_length::UInt8=UInt8(0))::Int

    if stream.api_state != H2StreamApiState.ACTIVE
        return raise_error(ERROR_HTTP_STREAM_HAS_COMPLETED)
    end
    if stream.outgoing_trailing_headers !== nothing
        return raise_error(ERROR_INVALID_STATE)
    end
    if stream.end_stream_sent
        return raise_error(ERROR_INVALID_STATE)
    end

    stream.outgoing_trailing_headers = headers
    stream.outgoing_trailing_pad_length = pad_length
    _h2_stream_maybe_flush!(stream)
    return OP_SUCCESS
end

# ─── Server response ───

"""
    h2_stream_send_response!(stream, conn, response; pad_length=0x00) -> Int

Server sends a response for this stream. Encodes HEADERS (and optionally body).
"""
function h2_stream_send_response!(stream::H2Stream, conn, response::HttpMessage;
    pad_length::UInt8=UInt8(0))::Int

    if stream.is_client
        return raise_error(ERROR_INVALID_STATE)
    end
    if stream.state == H2StreamState.CLOSED
        return raise_error(ERROR_HTTP_STREAM_HAS_COMPLETED)
    end

    hdrs = http_message_get_headers(response)
    has_body = http_message_get_body_stream(response) !== nothing
    manual_active = stream.manual_write && !stream.manual_write_ended
    end_stream = !has_body && !manual_active

    status, frame = h2_encode_headers(conn.encoder, stream.id, hdrs;
        end_stream=end_stream, pad_length=pad_length)

    if status != OP_SUCCESS
        return status
    end

    push!(stream.outgoing_frames, frame)

    if end_stream
        stream.end_stream_sent = true
        if stream.state == H2StreamState.RESERVED_LOCAL
            stream.state = H2StreamState.CLOSED
        elseif stream.end_stream_received
            stream.state = H2StreamState.CLOSED
        else
            stream.state = H2StreamState.HALF_CLOSED_LOCAL
        end
    else
        stream.body_state = H2StreamBodyState.ONGOING
        # Queue body from response
        body = http_message_get_body_stream(response)
        if body !== nothing
            body_data = _h2_body_to_bytes(body)
            write_entry = H2StreamDataWrite(body_data, true, UInt8(0), nothing)
            push!(stream.outgoing_writes, write_entry)
        end
        if stream.state == H2StreamState.RESERVED_LOCAL
            stream.state = H2StreamState.HALF_CLOSED_REMOTE
        end
    end

    _h2_stream_maybe_flush!(stream)
    return OP_SUCCESS
end

# ─── Push promise (server sends) ───

"""
    h2_stream_send_push_promise!(stream, conn, promised_stream_id, request_headers) -> Int

Server sends a PUSH_PROMISE frame on this stream.
"""
function h2_stream_send_push_promise!(stream::H2Stream, conn, promised_stream_id::UInt32,
    request_headers::HttpHeaders; pad_length::UInt8=UInt8(0))::Int

    if stream.is_client
        return raise_error(ERROR_INVALID_STATE)
    end
    if stream.state in (H2StreamState.CLOSED, H2StreamState.IDLE)
        return raise_error(ERROR_HTTP_STREAM_HAS_COMPLETED)
    end

    status, frame = h2_encode_push_promise(conn.encoder, stream.id,
        promised_stream_id, request_headers; pad_length=pad_length)
    if status != OP_SUCCESS
        return status
    end

    push!(stream.outgoing_frames, frame)
    _h2_stream_maybe_flush!(stream)
    return OP_SUCCESS
end

# ─── DATA frame encoding (called by connection during write path) ───

# Data encode result status
@enumx H2DataEncodeStatus::UInt8 begin
    COMPLETE = 0           # All writes encoded
    ONGOING = 1            # More writes to encode
    ONGOING_WINDOW_STALL = 2  # Stalled on flow control
end

"""
    h2_stream_encode_data_frame!(stream, conn) -> (Int, H2DataEncodeStatus.T)

Encode the next pending DATA frame from the stream's write queue.
Respects per-stream and connection-level flow control windows.
Returns (status, encode_status).
"""
function h2_stream_encode_data_frame!(stream::H2Stream, conn)::Tuple{Int, H2DataEncodeStatus.T}
    if isempty(stream.outgoing_writes)
        if stream.manual_write && !stream.manual_write_ended
            stream.body_state = H2StreamBodyState.WAITING_WRITES
            return (OP_SUCCESS, H2DataEncodeStatus.COMPLETE)
        end
        return (OP_SUCCESS, H2DataEncodeStatus.COMPLETE)
    end

    write = stream.outgoing_writes[1]

    # Flow control: check both stream and connection windows
    available_window = min(Int64(stream.window_size_peer), conn.window_size_peer)

    # Allow zero-length END_STREAM frames even with zero window
    if available_window <= 0 && !(isempty(write.data) && write.end_stream)
        return (OP_SUCCESS, H2DataEncodeStatus.ONGOING_WINDOW_STALL)
    end

    # Determine how much data to send
    max_frame_size = Int64(get(conn.settings_remote, Http2SettingsId.MAX_FRAME_SIZE, UInt32(16384)))
    send_len = min(length(write.data), Int(min(available_window, max_frame_size)))

    is_final_chunk = send_len >= length(write.data)
    end_stream_flag = write.end_stream && is_final_chunk &&
                      stream.outgoing_trailing_headers === nothing

    data_to_send = @view write.data[1:send_len]
    pad = is_final_chunk ? write.pad_length : UInt8(0)

    status, frame = h2_encode_data(stream.id, data_to_send;
        end_stream=end_stream_flag, pad_length=pad)
    if status != OP_SUCCESS
        return (status, H2DataEncodeStatus.COMPLETE)
    end

    push!(stream.outgoing_frames, frame)

    # Deduct from flow control windows
    if send_len > 0
        stream.window_size_peer -= Int32(send_len)
        conn.window_size_peer -= Int64(send_len)
    end

    if is_final_chunk
        # This write is complete
        popfirst!(stream.outgoing_writes)

        if write.on_complete !== nothing
            write.on_complete(OP_SUCCESS)
        end

        if end_stream_flag
            stream.end_stream_sent = true
            _h2_stream_transition_on_send_end_stream!(stream)
        elseif write.end_stream && stream.outgoing_trailing_headers !== nothing
            # Send trailing headers instead of setting END_STREAM on DATA
            _h2_stream_send_trailing_headers!(stream, conn)
        end
    else
        # Partial write: trim sent data
        write.data = write.data[send_len+1:end]
    end

    more = !isempty(stream.outgoing_writes)
    return (OP_SUCCESS, more ? H2DataEncodeStatus.ONGOING : H2DataEncodeStatus.COMPLETE)
end

# Internal: send trailing HEADERS with END_STREAM
function _h2_stream_send_trailing_headers!(stream::H2Stream, conn)::Nothing
    trailers = stream.outgoing_trailing_headers
    trailers === nothing && return nothing

    status, frame = h2_encode_headers(conn.encoder, stream.id, trailers;
        end_stream=true,
        pad_length=stream.outgoing_trailing_pad_length)

    if status == OP_SUCCESS
        push!(stream.outgoing_frames, frame)
        stream.end_stream_sent = true
        _h2_stream_transition_on_send_end_stream!(stream)
    end

    stream.outgoing_trailing_headers = nothing
    return nothing
end

# Internal: state transition when we send END_STREAM
function _h2_stream_transition_on_send_end_stream!(stream::H2Stream)::Nothing
    if stream.state == H2StreamState.OPEN
        stream.state = H2StreamState.HALF_CLOSED_LOCAL
    elseif stream.state == H2StreamState.HALF_CLOSED_REMOTE
        stream.state = H2StreamState.CLOSED
    elseif stream.state == H2StreamState.RESERVED_LOCAL
        stream.state = H2StreamState.CLOSED
    end
    return nothing
end

# ─── Decoder callbacks (called by connection's frame dispatch) ───

"""
    h2_stream_on_headers_begin!(stream) -> H2Err

Called when a HEADERS block begins for this stream.
"""
function h2_stream_on_headers_begin!(stream::H2Stream)::H2Err
    # Validate state allows receiving headers
    if stream.state == H2StreamState.CLOSED
        return h2err_from_h2_code(Http2ErrorCode.STREAM_CLOSED)
    end
    return H2ERR_SUCCESS
end

"""
    h2_stream_on_headers!(stream, headers, block_type, end_stream) -> H2Err

Called with decoded headers from a HEADERS frame for this stream.
"""
function h2_stream_on_headers!(stream::H2Stream, headers::Vector{HttpHeader},
    block_type::HttpHeaderBlock.T, end_stream::Bool)::H2Err

    # Extract pseudo-headers for request/response tracking
    for h in headers
        name_enum = http_str_to_header_name(h.name)
        if name_enum == HttpHeaderName.STATUS
            stream.response_status = something(tryparse(Int, h.value), HTTP_STATUS_CODE_UNKNOWN)
        elseif name_enum == HttpHeaderName.METHOD
            stream.request_method = http_str_to_method(h.value)
            stream.request_method_str = String(h.value)
        elseif name_enum == HttpHeaderName.PATH
            stream.request_path = String(h.value)
        elseif name_enum == HttpHeaderName.CONTENT_LENGTH
            cl = tryparse(Int64, h.value)
            if cl !== nothing
                stream.incoming_content_length = cl
            end
        end
    end

    # Invoke header callback
    if stream.on_incoming_headers !== nothing
        result = stream.on_incoming_headers(stream, block_type, headers)
        if result != 0
            return h2err_from_aws_code(ERROR_HTTP_CALLBACK_FAILURE)
        end
    end

    return H2ERR_SUCCESS
end

"""
    h2_stream_on_headers_end!(stream, block_type, end_stream) -> H2Err

Called when a HEADERS block ends for this stream.
"""
function h2_stream_on_headers_end!(stream::H2Stream, block_type::HttpHeaderBlock.T,
    end_stream::Bool)::H2Err

    if block_type == HttpHeaderBlock.MAIN
        stream.received_main_headers = true

        # State transitions on receiving HEADERS
        if stream.state == H2StreamState.IDLE
            stream.state = H2StreamState.OPEN
        elseif stream.state == H2StreamState.RESERVED_REMOTE
            if end_stream
                stream.state = H2StreamState.CLOSED
            else
                stream.state = H2StreamState.HALF_CLOSED_LOCAL
            end
        end
    end

    # Invoke header block done callback
    if stream.on_incoming_header_block_done !== nothing
        result = stream.on_incoming_header_block_done(stream, block_type)
        if result != 0
            return h2err_from_aws_code(ERROR_HTTP_CALLBACK_FAILURE)
        end
    end

    if end_stream
        h2_stream_on_end_stream_received!(stream)
    end

    return H2ERR_SUCCESS
end

"""
    h2_stream_on_data!(stream, data, end_stream) -> H2Err

Called with DATA frame payload for this stream.
"""
function h2_stream_on_data!(stream::H2Stream, data::AbstractVector{UInt8},
    payload_len::UInt32, end_stream::Bool)::H2Err

    # Validate state
    if stream.state in (H2StreamState.IDLE, H2StreamState.CLOSED,
                        H2StreamState.HALF_CLOSED_REMOTE)
        return h2err_from_h2_code(Http2ErrorCode.STREAM_CLOSED)
    end

    if !stream.received_main_headers
        return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
    end

    # Flow control: check receive window
    if payload_len > 0
        if Int64(payload_len) > Int64(stream.window_size_self)
            return h2err_from_h2_code(Http2ErrorCode.FLOW_CONTROL_ERROR)
        end
        stream.window_size_self -= Int32(payload_len)
    end

    # Track received data length
    stream.incoming_data_length += Int64(length(data))

    # Content-Length validation
    if stream.incoming_content_length >= 0
        if stream.incoming_data_length > stream.incoming_content_length
            return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
        end
        if end_stream && stream.incoming_data_length != stream.incoming_content_length
            return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
        end
    end

    # Invoke body callback
    if stream.on_incoming_body !== nothing && !isempty(data)
        result = stream.on_incoming_body(stream, data)
        if result != 0
            return h2err_from_aws_code(ERROR_HTTP_CALLBACK_FAILURE)
        end
    end

    # Auto window update (if not manual and not end_stream)
    if !end_stream && payload_len > 0
        conn = stream.owning_connection
        if conn !== nothing && !conn.manual_window_management
            _h2_stream_auto_window_update!(stream)
        end
    end

    if end_stream
        h2_stream_on_end_stream_received!(stream)
    end

    return H2ERR_SUCCESS
end

"""
    h2_stream_on_end_stream_received!(stream) -> Nothing

Handle END_STREAM flag received on any frame.
"""
function h2_stream_on_end_stream_received!(stream::H2Stream)::Nothing
    if stream.end_stream_received
        return nothing
    end
    Reseau.logf(
        Reseau.LogLevel.TRACE,
        LS_HTTP_STREAM,
        "H2 stream $(Int(stream.id)) end_stream_received state=$(h2_stream_state_to_str(stream.state))",
    )
    stream.end_stream_received = true

    if stream.state == H2StreamState.OPEN
        stream.state = H2StreamState.HALF_CLOSED_REMOTE
    elseif stream.state == H2StreamState.HALF_CLOSED_LOCAL
        stream.state = H2StreamState.CLOSED
    elseif stream.state == H2StreamState.RESERVED_REMOTE
        stream.state = H2StreamState.CLOSED
    end

    if !stream.is_client && stream.on_request_done !== nothing
        stream.on_request_done(stream)
    end
    return nothing
end

"""
    h2_stream_on_rst_stream!(stream, h2_error_code) -> H2Err

Handle received RST_STREAM frame.
"""
function h2_stream_on_rst_stream!(stream::H2Stream, h2_error_code::UInt32)::H2Err
    stream.received_reset_error_code = Int64(h2_error_code)

    # RFC 7540 §8.1: After receiving a complete response (END_STREAM),
    # client should silently discard NO_ERROR RST_STREAM
    if stream.is_client && stream.end_stream_received &&
       h2_error_code == UInt32(Http2ErrorCode.NO_ERROR)
        stream.state = H2StreamState.CLOSED
        return H2ERR_SUCCESS
    end

    stream.state = H2StreamState.CLOSED
    return H2ERR_SUCCESS
end

"""
    h2_stream_on_window_update!(stream, increment) -> (H2Err, Bool)

Handle received stream-level WINDOW_UPDATE. Returns (err, window_resumed)
where window_resumed indicates the stream can now send data.
"""
function h2_stream_on_window_update!(stream::H2Stream, increment::UInt32)::Tuple{H2Err, Bool}
    if increment == 0
        return (h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR), false)
    end

    was_stalled = stream.window_size_peer <= 0
    new_val = Int64(stream.window_size_peer) + Int64(increment)
    if new_val > Int64(H2_WINDOW_UPDATE_MAX)
        return (h2err_from_h2_code(Http2ErrorCode.FLOW_CONTROL_ERROR), false)
    end

    stream.window_size_peer = Int32(new_val)
    window_resumed = was_stalled && stream.window_size_peer > 0

    return (H2ERR_SUCCESS, window_resumed)
end

"""
    h2_stream_on_push_promise!(stream, promised_stream_id) -> H2Err

Handle received PUSH_PROMISE on this stream.
"""
function h2_stream_on_push_promise!(stream::H2Stream, promised_stream_id::UInt32)::H2Err
    if stream.state in (H2StreamState.IDLE, H2StreamState.CLOSED)
        return h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR)
    end
    # Push promise is valid; connection should create the promised stream
    return H2ERR_SUCCESS
end

# ─── Outgoing frame collection ───

"""
    h2_stream_get_outgoing_frames!(stream) -> Vector{UInt8}

Collect all queued outgoing frames into a single buffer. Clears the queue.
"""
function h2_stream_get_outgoing_frames!(stream::H2Stream)::Vector{UInt8}
    output = UInt8[]
    for frame in stream.outgoing_frames
        append!(output, frame)
    end
    empty!(stream.outgoing_frames)
    return output
end

function _h2_stream_maybe_flush!(stream::H2Stream)::Nothing
    conn = stream.owning_connection
    conn === nothing && return nothing
    _h2_connection_flush_outgoing!(conn)
    return nothing
end

# ─── Connection integration helpers ───

"""
    h2_stream_has_outgoing_data(stream) -> Bool

Check if the stream has outgoing frames or pending writes.
"""
function h2_stream_has_outgoing_data(stream::H2Stream)::Bool
    return !isempty(stream.outgoing_frames) || !isempty(stream.outgoing_writes)
end

"""
    h2_stream_is_write_stalled(stream, conn) -> Bool

Check if the stream is stalled on flow control.
"""
function h2_stream_is_write_stalled(stream::H2Stream, conn)::Bool
    return !isempty(stream.outgoing_writes) &&
           min(Int64(stream.window_size_peer), conn.window_size_peer) <= 0
end
