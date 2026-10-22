mutable struct _H2ServerStreamState
    stream_id::UInt32
    lock::ReentrantLock
    condition::Threads.Condition
    header_block::Vector{UInt8}
    decoded_headers::Union{Nothing,Vector{HeaderField}}
    trailers::Headers
    request::Union{Nothing,Request}
    body::Vector{UInt8}
    body_read_index::Int
    max_buffered_bytes::Int
    declared_body_bytes::Int64
    received_body_bytes::Int64
    headers_complete::Bool
    stream_done::Bool
    header_block_end_stream::Bool
    trailers_complete::Bool
    handler_started::Bool
    handler_finished::Bool
    aborted::Bool
    cancel_kind::UInt8
end

function _H2ServerStreamState(stream_id::UInt32, max_buffered_bytes::Int=_H2_DEFAULT_MAX_BUFFERED_BYTES)
    lock = ReentrantLock()
    return _H2ServerStreamState(
        stream_id,
        lock,
        Threads.Condition(lock),
        UInt8[],
        nothing,
        Headers(),
        nothing,
        UInt8[],
        1,
        max_buffered_bytes,
        Int64(-1),
        Int64(0),
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        UInt8(0),
    )
end

mutable struct _H2SendWindowState
    state_lock::ReentrantLock
    window_condition::Threads.Condition
    conn_send_window::Int64
    initial_stream_send_window::Int64
    peer_max_send_frame_size::Int
    peer_max_header_list_size::Int
    header_encoder::Encoder
    stream_send_window::Dict{UInt32,Int64}
    # Connection-level receive window: the DATA bytes (padding included) the
    # peer may still send before it needs more WINDOW_UPDATE credit.
    @atomic conn_recv_window::Int64
    # The server's `write_timeout_ns`, for writes made without the `Server`.
    const write_timeout_ns::Int64
    @atomic closed::Bool
end

function _H2SendWindowState(write_timeout_ns::Integer=0)
    lock = ReentrantLock()
    return _H2SendWindowState(
        lock,
        Threads.Condition(lock),
        Int64(65_535),
        Int64(65_535),
        16_384,
        0,
        Encoder(),
        Dict{UInt32,Int64}(),
        Int64(_H2_DEFAULT_WINDOW_SIZE),
        Int64(write_timeout_ns),
        false,
    )
end

@inline _h2_write_deadline_ns(send_state::_H2SendWindowState)::Int64 = _deadline_after(send_state.write_timeout_ns)

@enum _H2ServerStreamCancelKind::UInt8 begin
    _H2_SERVER_STREAM_OPEN = 0
    _H2_SERVER_STREAM_RESET = 1
    _H2_SERVER_STREAM_CONN_CLOSED = 2
end

@inline function _h2_server_stream_exception(kind::_H2ServerStreamCancelKind)::ProtocolError
    if kind == _H2_SERVER_STREAM_RESET
        return ProtocolError("HTTP/2 stream reset by peer")
    end
    return ProtocolError("HTTP/2 connection is closed")
end

# A bodyless HTTP/2 status response. The request is set after construction:
# callers pass a Union of request types, and a Union-typed keyword argument
# makes the keyword call dynamically dispatched under juliac --trim.
function _h2_status_response(status::Int, request::Request)
    response = Response(status; proto_major=2, proto_minor=0)
    response.request = request
    return response
end

mutable struct _H2ServerBody <: AbstractBody
    conn::Union{TCP.Conn,TLS.Conn}
    write_lock::ReentrantLock
    states_lock::ReentrantLock
    states::Dict{UInt32,_H2ServerStreamState}
    stream_id::UInt32
    tracked::_ServerConn
    state::_H2ServerStreamState
    send_state::_H2SendWindowState
    @atomic closed::Bool
end

const _H2_ERROR_PROTOCOL = UInt32(0x1)
const _H2_ERROR_INTERNAL = UInt32(0x2)
const _H2_ERROR_CANCEL = UInt32(0x8)
# RFC 9113 error codes used for stream/connection flood protection.
const _H2_ERROR_REFUSED_STREAM = UInt32(0x7)
const _H2_ERROR_ENHANCE_YOUR_CALM = UInt32(0xb)

# SETTINGS identifier for SETTINGS_MAX_CONCURRENT_STREAMS (RFC 9113 §6.5.2).
const _H2_SETTINGS_MAX_CONCURRENT_STREAMS = UInt16(0x3)

# `_H2_DEFAULT_MAX_CONCURRENT_STREAMS` is defined in http_server.jl (which is
# loaded before this file) because it is used as a Server/listen! keyword
# default. It is the RFC 9113 §6.5.2-recommended ceiling on the number of
# concurrently open streams per connection, advertised via
# SETTINGS_MAX_CONCURRENT_STREAMS and enforced on incoming HEADERS frames.

# Allowance for peer-initiated stream resets before the connection is treated as
# abusive (the CVE-2023-44487 "Rapid Reset" pattern). Once a connection resets
# more than `max_concurrent_streams + this` streams it is sent
# GOAWAY(ENHANCE_YOUR_CALM) and stops accepting new streams. The additive slack
# keeps a few legitimate client-side cancellations from tripping the limit.
const _H2_RAPID_RESET_ALLOWANCE = 100

# Outcome of evaluating an incoming HEADERS frame that opens a new stream
# against the per-connection limits. Kept as a small pure decision so it can be
# unit-tested offline without a live connection.
@enum _H2NewStreamDecision::UInt8 begin
    _H2_NEW_STREAM_ACCEPT = 0
    _H2_NEW_STREAM_NON_MONOTONIC = 1   # stream id <= highest previously-seen id
    _H2_NEW_STREAM_REFUSED = 2         # at SETTINGS_MAX_CONCURRENT_STREAMS
    _H2_NEW_STREAM_ENHANCE_CALM = 3    # Rapid-Reset reset budget exhausted
end

# Decide how to handle a HEADERS frame that opens a *new* (not-yet-seen) stream.
# `stream_id`        : the id carried by the HEADERS frame.
# `max_stream_id`    : the highest client stream id seen so far on the conn.
# `open_streams`     : number of currently-tracked streams (in `states`).
# `reset_streams`    : number of streams the peer has opened then RST_STREAM'd.
# `max_concurrent`   : advertised SETTINGS_MAX_CONCURRENT_STREAMS (<=0 disables).
# `reset_budget`     : reset count beyond which the connection is abusive.
@inline function _h2_server_new_stream_decision(
    stream_id::UInt32,
    max_stream_id::UInt32,
    open_streams::Int,
    reset_streams::Int,
    max_concurrent::Int,
    reset_budget::Int,
)::_H2NewStreamDecision
    # RFC 9113 §5.1.1: a new client-initiated stream id must be strictly greater
    # than every id used so far. Rejecting `<=` prevents reopening a closed
    # (and cleaned-up) stream, including reuse of the highest id after GOAWAY.
    stream_id <= max_stream_id && return _H2_NEW_STREAM_NON_MONOTONIC
    # Treat sustained stream resets as a Rapid-Reset flood and stop the conn.
    reset_budget > 0 && reset_streams > reset_budget && return _H2_NEW_STREAM_ENHANCE_CALM
    # Enforce the concurrent-stream ceiling before allocating any state.
    max_concurrent > 0 && open_streams >= max_concurrent && return _H2_NEW_STREAM_REFUSED
    return _H2_NEW_STREAM_ACCEPT
end

@inline function _h2_server_available_bytes(state::_H2ServerStreamState)::Int
    available = (length(state.body) - state.body_read_index) + 1
    return available > 0 ? available : 0
end

@inline function _h2_server_content_length_error(expected::Int64, actual::Int64, too_many::Bool)::ProtocolError
    if too_many
        return ProtocolError("HTTP/2 request body exceeded Content-Length")
    end
    return ProtocolError("HTTP/2 request body ended before Content-Length bytes were received")
end

@inline function _check_h2_server_body_end_locked(state::_H2ServerStreamState)::Nothing
    expected = state.declared_body_bytes
    expected >= 0 || return nothing
    actual = state.received_body_bytes
    actual == expected || throw(_h2_server_content_length_error(expected, actual, actual > expected))
    return nothing
end

# END_STREAM is carried by the HEADERS frame that opens a header block, but the
# block may finish on a later CONTINUATION frame. Call this once the block is
# decoded: ending the stream sooner would let the body report EOF, and the
# handler run, before trailers split across CONTINUATION frames are decoded.
# Returns `true` when the received body contradicts Content-Length.
function _end_h2_server_stream_locked!(state::_H2ServerStreamState)::Bool
    state.header_block_end_stream = false
    state.stream_done = true
    try
        _check_h2_server_body_end_locked(state)
    catch err
        err isa ProtocolError || rethrow()
        return true
    end
    return false
end

function _compact_h2_server_body_buffer!(state::_H2ServerStreamState)::Nothing
    if state.body_read_index <= 1
        return nothing
    end
    if state.body_read_index > length(state.body)
        empty!(state.body)
        state.body_read_index = 1
        return nothing
    end
    if state.body_read_index > 4096 && state.body_read_index > (length(state.body) >>> 1)
        remaining = (length(state.body) - state.body_read_index) + 1
        compacted = Vector{UInt8}(undef, remaining)
        copyto!(compacted, 1, state.body, state.body_read_index, remaining)
        state.body = compacted
        state.body_read_index = 1
    end
    return nothing
end

function _fail_h2_send_window_state!(send_state::_H2SendWindowState)::Nothing
    lock(send_state.state_lock)
    try
        @atomic :release send_state.closed = true
        notify(send_state.window_condition; all=true)
    finally
        unlock(send_state.state_lock)
    end
    return nothing
end

function _register_h2_send_window!(send_state::_H2SendWindowState, stream_id::UInt32)::Nothing
    lock(send_state.state_lock)
    try
        send_state.stream_send_window[stream_id] = send_state.initial_stream_send_window
        notify(send_state.window_condition; all=true)
    finally
        unlock(send_state.state_lock)
    end
    return nothing
end

function _unregister_h2_send_window!(send_state::_H2SendWindowState, stream_id::UInt32)::Nothing
    lock(send_state.state_lock)
    try
        delete!(send_state.stream_send_window, stream_id)
        notify(send_state.window_condition; all=true)
    finally
        unlock(send_state.state_lock)
    end
    return nothing
end

function _apply_h2_peer_settings!(
    send_state::_H2SendWindowState,
    write_lock::ReentrantLock,
    settings::Vector{Pair{UInt16,UInt32}},
)::Nothing
    header_table_size = nothing
    lock(send_state.state_lock)
    try
        for setting in settings
            id = setting.first
            value = setting.second
            if id == UInt16(0x1)
                header_table_size = Int(value)
            elseif id == UInt16(0x4)
                value > UInt32(0x7fff_ffff) && throw(ProtocolError("HTTP/2 SETTINGS_INITIAL_WINDOW_SIZE too large"))
                new_window = Int64(value)
                delta = new_window - send_state.initial_stream_send_window
                send_state.initial_stream_send_window = new_window
                for stream_id in keys(send_state.stream_send_window)
                    updated = send_state.stream_send_window[stream_id] + delta
                    updated > _H2_FLOW_CONTROL_MAX_WINDOW && throw(ProtocolError("HTTP/2 stream send window overflow"))
                    send_state.stream_send_window[stream_id] = updated
                end
            elseif id == UInt16(0x2)
                value > UInt32(1) && throw(ProtocolError("HTTP/2 SETTINGS_ENABLE_PUSH must be 0 or 1"))
            elseif id == UInt16(0x5)
                value < UInt32(16_384) && throw(ProtocolError("HTTP/2 SETTINGS_MAX_FRAME_SIZE too small"))
                value > UInt32(16_777_215) && throw(ProtocolError("HTTP/2 SETTINGS_MAX_FRAME_SIZE too large"))
                send_state.peer_max_send_frame_size = Int(value)
            elseif id == UInt16(0x6)
                send_state.peer_max_header_list_size = Int(value)
            end
        end
        notify(send_state.window_condition; all=true)
    finally
        unlock(send_state.state_lock)
    end
    if header_table_size !== nothing
        size = min(header_table_size::Int, _MAX_ENCODER_DYNAMIC_TABLE_SIZE)
        lock(write_lock)
        try
            set_max_dynamic_table_size_limit!(send_state.header_encoder, size)
            set_max_dynamic_table_size!(send_state.header_encoder, size)
        finally
            unlock(write_lock)
        end
    end
    return nothing
end

function _apply_h2_window_update!(send_state::_H2SendWindowState, frame::WindowUpdateFrame)::Nothing
    lock(send_state.state_lock)
    try
        increment = Int64(frame.window_size_increment)
        if frame.stream_id == UInt32(0)
            updated = send_state.conn_send_window + increment
            updated > _H2_FLOW_CONTROL_MAX_WINDOW && throw(ProtocolError("HTTP/2 connection send window overflow"))
            send_state.conn_send_window = updated
        elseif haskey(send_state.stream_send_window, frame.stream_id)
            updated = send_state.stream_send_window[frame.stream_id] + increment
            updated > _H2_FLOW_CONTROL_MAX_WINDOW && throw(ProtocolError("HTTP/2 stream send window overflow"))
            send_state.stream_send_window[frame.stream_id] = updated
        else
            return nothing
        end
        notify(send_state.window_condition; all=true)
    finally
        unlock(send_state.state_lock)
    end
    return nothing
end

function _wait_h2_send_window_locked!(
    send_state::_H2SendWindowState,
    deadline_ns::Int64;
    clock_ns::Function=time_ns,
    wait_ns::Function=IOPoll.sleep_ns,
)::Nothing
    if deadline_ns == 0
        wait(send_state.window_condition)
        return nothing
    end
    remaining_ns = deadline_ns - Int64(clock_ns())
    remaining_ns <= 0 && throw(IOPoll.DeadlineExceededError())
    unlock(send_state.state_lock)
    try
        wait_ns(min(remaining_ns, Int64(1_000_000)))
    finally
        lock(send_state.state_lock)
    end
    return nothing
end

# Reserves up to `wanted` bytes of send credit, at most one frame's worth. It
# waits for credit, or with `block=false` returns 0 when there is none.
function _reserve_h2_send_window!(send_state::_H2SendWindowState, stream_id::UInt32, wanted::Int, deadline_ns::Int64=Int64(0); block::Bool=true)::Int
    wanted > 0 || throw(ArgumentError("wanted send window must be > 0"))
    lock(send_state.state_lock)
    try
        while true
            (@atomic :acquire send_state.closed) && throw(ProtocolError("HTTP/2 connection is closed"))
            haskey(send_state.stream_send_window, stream_id) || throw(ProtocolError("HTTP/2 stream send window is closed"))
            stream_window = send_state.stream_send_window[stream_id]
            if stream_window <= 0 || send_state.conn_send_window <= 0
                block || return 0
                _wait_h2_send_window_locked!(send_state, deadline_ns)
                continue
            end
            allowed = min(
                Int64(wanted),
                send_state.conn_send_window,
                stream_window,
                Int64(send_state.peer_max_send_frame_size),
                Int64(_H2_SERVER_MAX_DATA_FRAME_SIZE),
            )
            if allowed <= 0
                _wait_h2_send_window_locked!(send_state, deadline_ns)
                continue
            end
            send_state.conn_send_window -= allowed
            send_state.stream_send_window[stream_id] = stream_window - allowed
            return Int(allowed)
        end
    finally
        unlock(send_state.state_lock)
    end
end

# Returns `nbytes` of receive-window credit to the peer: always at the
# connection level, and at the stream level when `stream_level` is set.
function _send_h2_server_window_updates!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    nbytes::Int,
    stream_level::Bool=true,
)::Nothing
    nbytes <= 0 && return nothing
    increment = UInt32(nbytes)
    # Credit the window before the peer can see the update and use it.
    @atomic send_state.conn_recv_window += nbytes
    deadline_ns = _h2_write_deadline_ns(send_state)
    try
        _write_frame_h2_server_threadsafe!(write_lock, conn, WindowUpdateFrame(UInt32(0), increment), deadline_ns)
        stream_level && _write_frame_h2_server_threadsafe!(write_lock, conn, WindowUpdateFrame(stream_id, increment), deadline_ns)
    catch err
        if err isa EOFError || err isa IOPoll.NetClosingError || err isa SystemError
            return nothing
        end
        rethrow(err)
    end
    return nothing
end

function _maybe_cleanup_h2_server_state!(
    tracked::_ServerConn,
    states_lock::ReentrantLock,
    states::Dict{UInt32,_H2ServerStreamState},
    state::_H2ServerStreamState,
    send_state::_H2SendWindowState,
)::Nothing
    should_delete = false
    lock(state.lock)
    try
        # An aborted stream was reset by one side, so no request body is coming.
        should_delete = state.handler_finished && (state.stream_done || state.aborted) && _h2_server_available_bytes(state) == 0
    finally
        unlock(state.lock)
    end
    should_delete || return nothing
    removed = false
    lock(states_lock)
    try
        current = get(() -> nothing, states, state.stream_id)
        if current === state
            delete!(states, state.stream_id)
            removed = true
        end
    finally
        unlock(states_lock)
    end
    removed && _unregister_h2_send_window!(send_state, state.stream_id)
    _update_h2_server_conn_state!(tracked, states_lock, states)
    return nothing
end

# Drops the request bytes buffered for `state` and returns how many there were,
# so the caller can return their connection-level credit. Callers hold `state.lock`.
function _take_h2_server_unread_bytes!(state::_H2ServerStreamState)::Int
    unread = _h2_server_available_bytes(state)
    empty!(state.body)
    state.body_read_index = 1
    return unread
end

# Returns the number of buffered request bytes discarded (0 unless `discard_body`).
function _set_h2_server_stream_cancelled!(
    state::_H2ServerStreamState,
    kind::_H2ServerStreamCancelKind,
    aborted::Bool=true,
    discard_body::Bool=true,
    finish_if_unstarted::Bool=false,
)::Int
    discarded = 0
    lock(state.lock)
    try
        state.cancel_kind == UInt8(_H2_SERVER_STREAM_OPEN) && (state.cancel_kind = UInt8(kind))
        aborted && (state.aborted = true)
        state.stream_done = true
        discard_body && (discarded = _take_h2_server_unread_bytes!(state))
        finish_if_unstarted && !state.handler_started && (state.handler_finished = true)
        notify(state.condition)
    finally
        unlock(state.lock)
    end
    return discarded
end

function _fail_h2_server_streams!(
    states_lock::ReentrantLock,
    states::Dict{UInt32,_H2ServerStreamState},
    send_state::_H2SendWindowState,
)::Nothing
    snapshot = _H2ServerStreamState[]
    lock(states_lock)
    try
        append!(snapshot, values(states))
    finally
        unlock(states_lock)
    end
    for state in snapshot
        _set_h2_server_stream_cancelled!(state, _H2_SERVER_STREAM_CONN_CLOSED, true, true, true)
        _unregister_h2_send_window!(send_state, state.stream_id)
    end
    return nothing
end

function _fail_h2_server_stream!(
    server::Server,
    tracked::_ServerConn,
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    states_lock::ReentrantLock,
    states::Dict{UInt32,_H2ServerStreamState},
    send_state::_H2SendWindowState,
    state::_H2ServerStreamState,
    error_code::UInt32,
)::Nothing
    should_reset = false
    lock(state.lock)
    try
        should_reset = state.cancel_kind == UInt8(_H2_SERVER_STREAM_OPEN)
    finally
        unlock(state.lock)
    end
    discarded = _set_h2_server_stream_cancelled!(state, _H2_SERVER_STREAM_RESET, true, true, true)
    if should_reset
        @try_ignore begin
            _write_frame_h2_server_threadsafe!(
                write_lock,
                conn,
                RSTStreamFrame(state.stream_id, error_code),
                _server_write_deadline_ns(server),
            )
        end
    end
    @try_ignore _send_h2_server_window_updates!(conn, write_lock, send_state, state.stream_id, discarded, false)
    _unregister_h2_send_window!(send_state, state.stream_id)
    _maybe_cleanup_h2_server_state!(tracked, states_lock, states, state, send_state)
    return nothing
end

function body_closed(body::_H2ServerBody)::Bool
    return @atomic :acquire body.closed
end

function _h2_server_body_fully_consumed(body::_H2ServerBody)::Bool
    lock(body.state.lock)
    try
        return body.state.stream_done && _h2_server_available_bytes(body.state) == 0 && !body.state.aborted
    finally
        unlock(body.state.lock)
    end
end

function body_read!(body::_H2ServerBody, dst::Vector{UInt8})::Int
    isempty(dst) && return 0
    body_closed(body) && return 0
    while true
        nread = 0
        done = false
        lock(body.state.lock)
        try
            if body.state.cancel_kind != UInt8(_H2_SERVER_STREAM_OPEN)
                throw(_h2_server_stream_exception(_H2ServerStreamCancelKind(body.state.cancel_kind)))
            end
            available = _h2_server_available_bytes(body.state)
            if available > 0
                nread = min(length(dst), available)
                copyto!(dst, 1, body.state.body, body.state.body_read_index, nread)
                body.state.body_read_index += nread
                _compact_h2_server_body_buffer!(body.state)
                notify(body.state.condition)
            elseif body.state.stream_done
                done = true
            else
                wait(body.state.condition)
                continue
            end
        finally
            unlock(body.state.lock)
        end
        if nread > 0
            _send_h2_server_window_updates!(body.conn, body.write_lock, body.send_state, body.stream_id, nread)
            return nread
        end
        if done
            @atomic :release body.closed = true
            _maybe_cleanup_h2_server_state!(body.tracked, body.states_lock, body.states, body.state, body.send_state)
            return 0
        end
    end
end

function body_close!(body::_H2ServerBody)::Nothing
    was_closed = body_closed(body)
    was_closed && return nothing
    @atomic :release body.closed = true
    should_reset = false
    unread = 0
    lock(body.state.lock)
    try
        if !body.state.aborted
            # Nobody reads these bytes now; their connection credit goes back below.
            unread = _take_h2_server_unread_bytes!(body.state)
            if !body.state.stream_done
                body.state.aborted = true
                should_reset = true
            elseif unread > 0
                body.state.aborted = true
            end
        end
        notify(body.state.condition)
    finally
        unlock(body.state.lock)
    end
    if should_reset
        @try_ignore begin
            _write_frame_h2_server_threadsafe!(body.write_lock, body.conn, RSTStreamFrame(body.stream_id, UInt32(0x8)), _h2_write_deadline_ns(body.send_state))
        end
    end
    @try_ignore _send_h2_server_window_updates!(body.conn, body.write_lock, body.send_state, body.stream_id, unread, false)
    _maybe_cleanup_h2_server_state!(body.tracked, body.states_lock, body.states, body.state, body.send_state)
    return nothing
end

@inline function _h2_response_allows_body(request::Request, response::Response)::Bool
    _body_allowed_for_status(response.status) || return false
    request.method == "HEAD" && return false
    return true
end

@inline function _skip_h2_header(name::AbstractString)::Bool
    lower = lowercase(name)
    return lower == "connection" ||
           lower == "proxy-connection" ||
           lower == "keep-alive" ||
           lower == "te" ||
           lower == "transfer-encoding" ||
           lower == "upgrade" ||
           lower == "trailer"
end

function _append_h2_headers!(out::Vector{HeaderField}, hdrs::Headers; trailers::Bool=false)::Nothing
    for key in header_keys(hdrs)
        if trailers
            _valid_trailer_header_name(key) || throw(ProtocolError("invalid HTTP/2 trailer field name: $(repr(key))"))
        else
            _valid_header_field_name(key) || throw(ProtocolError("invalid HTTP/2 header field name: $(repr(key))"))
            _skip_h2_header(key) && continue
        end
        lower = lowercase(key)
        values = headers(hdrs, key)
        for value in values
            normalized = _normalize_strict_header_field_value(value)
            normalized === nothing && throw(ProtocolError("invalid HTTP/2 header field value for $(repr(key))"))
            push!(out, HeaderField(lower, normalized, false))
        end
    end
    return nothing
end

# Server-side cap on how large an outgoing DATA frame can be. The HTTP/2
# minimum-required value is 16 KiB; we still respect the peer's advertised
# `SETTINGS_MAX_FRAME_SIZE` at flow-control reservation time, so the
# effective frame size on the wire is `min(this, peer.SETTINGS_MAX_FRAME_SIZE)`.
# Larger values reduce per-frame framing overhead (9-byte header per chunk)
# and let `_write_data_frames_h2_server!` batch fewer frames into each
# socket write. 64 KiB is well within the 16 MiB protocol upper bound and
# matches what most production HTTP/2 servers (nginx, h2o) advertise.
const _H2_SERVER_MAX_DATA_FRAME_SIZE = 65_536

mutable struct _ServerPrefaceConn{C} <: IO
    prefix::Vector{UInt8}
    next::Int
    conn::C
end

function _ServerPrefaceConn(prefix::Vector{UInt8}, conn::C) where {C}
    return _ServerPrefaceConn{C}(prefix, 1, conn)
end

function _ConnReader(conn::_ServerPrefaceConn{TCP.Conn}, buffer_bytes::Integer=_CONN_READER_DEFAULT_BUFFER_BYTES)
    reader = _ConnReader(conn.conn::TCP.Conn, buffer_bytes)
    available = max(0, length(conn.prefix) - conn.next + 1)
    if available > 0
        available > length(reader.buf) && resize!(reader.buf, available)
        copyto!(reader.buf, 1, conn.prefix, conn.next, available)
        reader.next = 1
        reader.stop = available
    end
    return reader
end

function Base.read!(conn::_ServerPrefaceConn, dst::Vector{UInt8})::Int
    n = readbytes!(conn, dst)
    n == length(dst) || throw(EOFError())
    return n
end

function Base.readbytes!(
    conn::_ServerPrefaceConn,
    dst::AbstractVector{UInt8},
    nb::Integer=length(dst);
    all::Bool=true,
)::Int
    isempty(dst) && return 0
    requested = min(length(dst), Int(nb))
    requested < 0 && throw(ArgumentError("nb must be >= 0"))
    requested == 0 && return 0
    target = requested == length(dst) ? dst : @view(dst[1:requested])
    available = (length(conn.prefix) - conn.next) + 1
    if available > 0
        n = min(length(target), available)
        copyto!(target, 1, conn.prefix, conn.next, n)
        conn.next += n
        (!all || n == length(target)) && return n
        return n + readbytes!(conn.conn, @view(target[(n+1):end]); all=true)
    end
    return readbytes!(conn.conn, target; all=all)
end

function Base.readavailable(conn::_ServerPrefaceConn)::Vector{UInt8}
    available = (length(conn.prefix) - conn.next) + 1
    if available > 0
        out = Vector{UInt8}(undef, available)
        copyto!(out, 1, conn.prefix, conn.next, available)
        conn.next += available
        return out
    end
    return readavailable(conn.conn)
end

function _h2_preface_prefix_matches(prefix::Vector{UInt8})::Bool
    @inbounds for i in 1:length(prefix)
        prefix[i] == _H2_PREFACE[i] || return false
    end
    return true
end

function _probe_h2_preface!(server::Server, conn::TCP.Conn)::Tuple{Bool,_ServerPrefaceConn{TCP.Conn}}
    # With h2c off, read nothing: the h1 path arms its own header deadline.
    server.allow_h2c || return false, _ServerPrefaceConn(UInt8[], conn)
    # Cleartext HTTP/2 has no ALPN, so we sniff enough of the connection preface
    # to choose h2 and replay the same bytes into the h1 parser otherwise.
    _set_read_deadline_for_header!(server, conn)
    prefix = UInt8[]
    chunk = Vector{UInt8}(undef, 1)
    while length(prefix) < length(_H2_PREFACE)
        n = readbytes!(conn, chunk, 1)
        n > 0 || break
        push!(prefix, chunk[1])
        _h2_preface_prefix_matches(prefix) || return false, _ServerPrefaceConn(prefix, conn)
        length(prefix) == length(_H2_PREFACE) && return true, _ServerPrefaceConn(prefix, conn)
    end
    return false, _ServerPrefaceConn(prefix, conn)
end

function _write_all_h2_server!(conn::Union{TCP.Conn,TLS.Conn}, bytes::Vector{UInt8})::Nothing
    total = 0
    while total < length(bytes)
        chunk = total == 0 ? bytes : bytes[(total+1):end]
        n = write(conn, chunk)
        n > 0 || throw(ProtocolError("h2 server write made no progress"))
        total += n
    end
    return nothing
end

# Callers hold the connection's write lock. Every write sets the socket's write
# deadline, `0` for none: the deadline outlives the write, and another task's
# expired deadline would fail this one.
function _write_frame_h2_server!(conn::Union{TCP.Conn,TLS.Conn}, frame::AbstractFrame, write_deadline_ns::Int64=Int64(0))::Nothing
    io = IOBuffer()
    write_frame!(io, frame)
    _set_write_deadline!(conn, write_deadline_ns)
    _write_all_h2_server!(conn, take!(io))
    return nothing
end

function _write_frame_h2_server_threadsafe!(
    write_lock::ReentrantLock,
    conn::Union{TCP.Conn,TLS.Conn},
    frame::AbstractFrame,
    write_deadline_ns::Int64=Int64(0),
)::Nothing
    lock(write_lock)
    try
        _write_frame_h2_server!(conn, frame, write_deadline_ns)
    finally
        unlock(write_lock)
    end
    return nothing
end

@inline function _stamp_h2_data_header!(buf::Vector{UInt8}, pos::Int, payload_len::Int, end_stream::Bool, stream_id::UInt32)::Nothing
    @inbounds buf[pos]     = UInt8((payload_len >> 16) & 0xff)
    @inbounds buf[pos + 1] = UInt8((payload_len >> 8) & 0xff)
    @inbounds buf[pos + 2] = UInt8(payload_len & 0xff)
    @inbounds buf[pos + 3] = FRAME_DATA
    @inbounds buf[pos + 4] = end_stream ? UInt8(0x01) : UInt8(0x00)
    sid = stream_id & 0x7fff_ffff
    @inbounds buf[pos + 5] = UInt8((sid >> 24) & 0xff)
    @inbounds buf[pos + 6] = UInt8((sid >> 16) & 0xff)
    @inbounds buf[pos + 7] = UInt8((sid >> 8) & 0xff)
    @inbounds buf[pos + 8] = UInt8(sid & 0xff)
    return nothing
end

@inline function _copy_h2_payload!(
    dst::Vector{UInt8},
    dst_pos::Int,
    src::Vector{UInt8},
    src_pos::Int,
    n::Int,
)::Nothing
    unsafe_copyto!(dst, dst_pos, src, src_pos, n)
    return nothing
end

@inline function _copy_h2_payload!(
    dst::Vector{UInt8},
    dst_pos::Int,
    src::AbstractVector{UInt8},
    src_pos::Int,
    n::Int,
)::Nothing
    copyto!(dst, dst_pos, src, src_pos, n)
    return nothing
end

function _write_data_frames_h2_server!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    data::AbstractVector{UInt8};
    end_stream::Bool,
    write_deadline_ns::Int64=Int64(0),
)::Nothing
    isempty(data) && return nothing
    offset = 1
    total_len = length(data)
    peer_max = lock(send_state.state_lock) do
        send_state.peer_max_send_frame_size
    end
    max_frame_size = min(Int(_H2_SERVER_MAX_DATA_FRAME_SIZE), peer_max)
    # Each pass reserves send window (at most one frame's worth), copies the
    # DATA frame header and payload into one buffer, and writes it in one call.
    while offset <= total_len
        first_chunk = _reserve_h2_send_window!(send_state, stream_id, total_len - offset + 1, write_deadline_ns)
        first_chunk <= 0 && continue
        # Pre-size an output Vector that fits this batch exactly.
        n_frames_first = cld(first_chunk, max_frame_size)
        batch_len = first_chunk + 9 * n_frames_first
        out = Vector{UInt8}(undef, batch_len)
        out_pos = 1
        # Emit frames covering this reservation.
        remaining_in_res = first_chunk
        while remaining_in_res > 0
            payload = min(remaining_in_res, max_frame_size, total_len - offset + 1)
            final_chunk = (offset + payload - 1) == total_len
            _stamp_h2_data_header!(out, out_pos, payload, end_stream && final_chunk, stream_id)
            out_pos += 9
            _copy_h2_payload!(out, out_pos, data, offset, payload)
            out_pos += payload
            offset += payload
            remaining_in_res -= payload
        end
        # IMPORTANT: write the bytes we have in `out` BEFORE attempting
        # another reservation. `_reserve_h2_send_window!` blocks if the
        # peer's send window is exhausted, and the peer won't send
        # WINDOW_UPDATE until it has received the bytes we just buffered.
        # Trying to "drain more before writing" deadlocks against tests
        # like `HTTP/2 server honors peer response-header filtering and
        # stream flow control` that intentionally use a small initial
        # window and gate further DATA on a WINDOW_UPDATE frame.
        if out_pos - 1 != length(out)
            resize!(out, out_pos - 1)
        end
        lock(write_lock)
        try
            _set_write_deadline!(conn, write_deadline_ns)
            _write_all_h2_server!(conn, out)
        finally
            unlock(write_lock)
        end
    end
    return nothing
end

function _h2_server_has_active_streams(states_lock::ReentrantLock, states::Dict{UInt32,_H2ServerStreamState})::Bool
    lock(states_lock)
    try
        return !isempty(states)
    finally
        unlock(states_lock)
    end
end

function _set_h2_frame_read_deadline!(
    server::Server,
    conn::Union{TCP.Conn,TLS.Conn},
    states_lock::ReentrantLock,
    states::Dict{UInt32,_H2ServerStreamState},
    continuation_stream::UInt32,
)::Nothing
    timeout = Int64(0)
    if continuation_stream != UInt32(0)
        timeout = server.read_header_timeout_ns > 0 ? server.read_header_timeout_ns : server.read_timeout_ns
    elseif _h2_server_has_active_streams(states_lock, states)
        timeout = server.read_timeout_ns
    elseif server.idle_timeout_ns > 0
        timeout = server.idle_timeout_ns
    else
        timeout = server.read_header_timeout_ns > 0 ? server.read_header_timeout_ns : server.read_timeout_ns
    end
    _set_read_deadline!(conn, _deadline_after(timeout))
    return nothing
end

function _update_h2_server_conn_state!(tracked::_ServerConn, states_lock::ReentrantLock, states::Dict{UInt32,_H2ServerStreamState})::Nothing
    state = _conn_state(tracked)
    state == _ConnState.CLOSED && return nothing
    if _h2_server_has_active_streams(states_lock, states)
        state == _ConnState.ACTIVE || _set_conn_state!(tracked, _ConnState.ACTIVE)
    else
        state == _ConnState.IDLE || _set_conn_state!(tracked, _ConnState.IDLE)
    end
    return nothing
end

function _read_exact_h2_server!(io, n::Int)::Vector{UInt8}
    out = Vector{UInt8}(undef, n)
    offset = 0
    while offset < n
        chunk = Vector{UInt8}(undef, n - offset)
        nr = readbytes!(io, chunk)
        nr > 0 || throw(EOFError())
        copyto!(out, offset + 1, chunk, 1, nr)
        offset += nr
    end
    return out
end

function _validate_h2_request_headers!(headers::Vector{HeaderField})::Tuple{String,Union{Nothing,String},Union{Nothing,String},Union{Nothing,String},Headers}
    method = nothing
    scheme = nothing
    path = nothing
    authority = nothing
    saw_regular = false
    out_headers = Headers()
    for field in headers
        name = field.name
        value = field.value
        name == lowercase(name) || throw(ProtocolError("HTTP/2 header field names must be lowercase"))
        normalized = _normalize_strict_header_field_value(value)
        normalized === nothing && throw(ProtocolError("invalid HTTP/2 header field value for $(repr(name))"))
        if startswith(name, ':')
            saw_regular && throw(ProtocolError("HTTP/2 pseudo-headers must precede regular headers"))
            if name == ":method"
                method === nothing || throw(ProtocolError("duplicate HTTP/2 :method pseudo-header"))
                # RFC 9113 8.3.1 / RFC 9110 9.1: :method carries an HTTP method,
                # which is a `token`. `_normalize_strict_header_field_value` only
                # rejects CR/LF/CTL and permits SP/HTAB, so a value such as
                # "GET /admin?x=" would otherwise be accepted and smuggled into an
                # HTTP/1 request line verbatim. Enforce the RFC 9110 token charset
                # (same check the h1 server and h2 client apply to the method).
                _valid_header_field_name(normalized) || throw(ProtocolError("invalid HTTP/2 :method pseudo-header: $(repr(normalized))"))
                method = normalized
            elseif name == ":scheme"
                scheme === nothing || throw(ProtocolError("duplicate HTTP/2 :scheme pseudo-header"))
                scheme = normalized
            elseif name == ":path"
                path === nothing || throw(ProtocolError("duplicate HTTP/2 :path pseudo-header"))
                # RFC 9113 8.3.1: :path conveys the request-target's path/query and
                # MUST NOT contain whitespace. Interior SP/HTAB would otherwise be
                # written verbatim into an HTTP/1 request line, splitting the target
                # and enabling request smuggling past path-based ACLs.
                _string_contains_whitespace_byte(normalized) && throw(ProtocolError("invalid HTTP/2 :path pseudo-header: $(repr(normalized))"))
                path = normalized
            elseif name == ":authority"
                authority === nothing || throw(ProtocolError("duplicate HTTP/2 :authority pseudo-header"))
                # RFC 9113 8.3.1: :authority is the request authority (host[:port]).
                # Validate it with the same host validator used by the h1 server so
                # interior whitespace / invalid host characters are rejected rather
                # than forwarded verbatim to an HTTP/1 origin.
                _valid_host_header(normalized) || throw(ProtocolError("invalid HTTP/2 :authority pseudo-header: $(repr(normalized))"))
                authority = normalized
            else
                throw(ProtocolError("unsupported HTTP/2 pseudo-header $(repr(name))"))
            end
            continue
        end
        saw_regular = true
        _valid_header_field_name(name) || throw(ProtocolError("invalid HTTP/2 header field name: $(repr(name))"))
        if name == "connection" || name == "proxy-connection" || name == "keep-alive" || name == "upgrade"
            throw(ProtocolError("forbidden HTTP/2 connection-specific header $(repr(name))"))
        end
        if name == "transfer-encoding"
            throw(ProtocolError("forbidden HTTP/2 transfer-encoding header"))
        end
        if name == "te"
            lowercase(_trim_http_ows(normalized)) == "trailers" || throw(ProtocolError("HTTP/2 TE header may only contain trailers"))
        end
        push!(out_headers, canonical_header_key(name) => normalized)
    end
    _fold_received_fields!(out_headers)
    method === nothing && throw(ProtocolError("missing HTTP/2 :method pseudo-header"))
    # RFC 9113 8.3.1: "If the :authority pseudo-header field is present, the
    # endpoint MUST NOT generate a request with a Host header field that differs
    # from the :authority field." Treat an inbound request that carries any
    # Host header differing from :authority as malformed; otherwise a proxy
    # could authorize on the benign :authority while a hostile Host header is
    # forwarded to (and prefers over request.host at) an HTTP/1 origin. Every
    # Host value must match: a request may carry multiple (possibly
    # non-adjacent) Host headers, and the HTTP/1 serializer forwards them all
    # verbatim, so checking only the first value would leave a smuggling path.
    # (The function parameter is named `headers`, so iterate the stored entries
    # directly rather than calling the `headers(::Headers, key)` accessor.)
    if authority !== nothing
        for (entry_name, entry_value) in out_headers.entries
            _ascii_equal_fold(entry_name, "Host") || continue
            entry_value == authority || throw(ProtocolError("HTTP/2 Host header does not match :authority"))
        end
    end
    if method == "CONNECT"
        authority === nothing && throw(ProtocolError("CONNECT requests require :authority"))
        scheme === nothing || throw(ProtocolError("CONNECT requests must not include :scheme"))
        path === nothing || throw(ProtocolError("CONNECT requests must not include :path"))
    else
        scheme === nothing && throw(ProtocolError("missing HTTP/2 :scheme pseudo-header"))
        path === nothing && throw(ProtocolError("missing HTTP/2 :path pseudo-header"))
    end
    return method::String, scheme, path, authority, out_headers
end

function _decode_h2_request(headers::Vector{HeaderField}, body::AbstractBody, stream_done::Bool=false)::Request
    method, _scheme, path, authority, out_headers = _validate_h2_request_headers!(headers)
    target = method == "CONNECT" ? authority::String : (path::String)
    host = authority === nothing ? header(out_headers, "Host") : authority
    content_length = _parse_content_length(out_headers)
    if stream_done && content_length >= 0
        if body isa BytesBody
            actual = Int64(length((body::BytesBody).data))
            actual == content_length || throw(ProtocolError("HTTP/2 request body bytes did not match Content-Length"))
        elseif body isa EmptyBody
            content_length == 0 || throw(ProtocolError("HTTP/2 request body ended before Content-Length bytes were received"))
        end
    end
    if content_length < 0
        if body isa BytesBody
            content_length = Int64(length((body::BytesBody).data))
        elseif body isa EmptyBody && stream_done
            content_length = Int64(0)
        end
    end
    return Request(
        method,
        target;
        headers=out_headers,
        body=body,
        host=host,
        content_length=content_length,
        proto_major=2,
        proto_minor=0,
    )
end

function _decode_h2_request(headers::Vector{HeaderField}, body::Vector{UInt8})::Request
    request_body = isempty(body) ? EmptyBody() : BytesBody(body)
    return _decode_h2_request(headers, request_body, true)
end

# The header fields of a response head. Throws `ProtocolError` for a field
# HTTP/2 cannot carry.
function _h2_response_header_fields(response_status::Int, response_headers::Headers)::Vector{HeaderField}
    # A final response has a three-digit status that is not informational (RFC 9113 §8.1).
    200 <= response_status <= 999 || throw(ProtocolError("invalid HTTP/2 response status code: $(response_status)"))
    header_fields = HeaderField[HeaderField(":status", string(response_status), false)]
    _append_h2_headers!(header_fields, response_headers)
    return header_fields
end

function _h2_trailer_header_fields(trailers::Headers)::Vector{HeaderField}
    header_fields = HeaderField[]
    _append_h2_headers!(header_fields, trailers; trailers=true)
    return header_fields
end

# Callers hold the write lock: the encoder's table changes must reach the wire in order.
function _encode_h2_header_fields!(encoder::Encoder, header_fields::Vector{HeaderField}, max_header_list_size::Int)::Vector{UInt8}
    max_header_list_size > 0 && _header_list_size(header_fields) > max_header_list_size && throw(ProtocolError("HTTP/2 response header block exceeds peer SETTINGS_MAX_HEADER_LIST_SIZE"))
    return encode_header_block(encoder, header_fields)
end

# The header and trailer fields of `response`. Throws, before anything is
# written, for a response the server cannot send.
function _h2_response_head(request::Request, response::Response)::Tuple{Vector{HeaderField},Vector{HeaderField}}
    _check_response_body_unsent(response, request)
    trailer_fields = isempty(response.trailers) ? HeaderField[] : _h2_trailer_header_fields(response.trailers)
    return _h2_response_header_fields(response.status, response.headers), trailer_fields
end

function _write_h2_header_block_locked!(
    conn::Union{TCP.Conn,TLS.Conn},
    stream_id::UInt32,
    header_block::Vector{UInt8},
    end_stream::Bool,
    max_frame_size::Int,
    write_deadline_ns::Int64=Int64(0),
)::Nothing
    _header_block_frames(stream_id, end_stream, header_block, max_frame_size) do frame
        _write_frame_h2_server!(conn, frame, write_deadline_ns)
    end
    return nothing
end

# Writes one header block, response headers or trailers, as HEADERS and any
# CONTINUATION frames it needs.
function _write_h2_header_fields!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    header_fields::Vector{HeaderField},
    end_stream::Bool,
    write_deadline_ns::Int64=Int64(0),
)::Nothing
    max_frame_size = 16_384
    max_header_list_size = 0
    lock(send_state.state_lock)
    try
        max_frame_size = send_state.peer_max_send_frame_size
        max_header_list_size = send_state.peer_max_header_list_size
    finally
        unlock(send_state.state_lock)
    end
    lock(write_lock)
    try
        header_block = _encode_h2_header_fields!(send_state.header_encoder, header_fields, max_header_list_size)
        _write_h2_header_block_locked!(conn, stream_id, header_block, end_stream, max_frame_size, write_deadline_ns)
    finally
        unlock(write_lock)
    end
    return nothing
end

function _write_response_body_h2_server!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    response::Response,
    end_stream::Bool=true,
    write_deadline_ns::Int64=Int64(0),
)::Nothing
    body = response.body
    body isa EmptyBody && return nothing
    if body isa BytesBody
        bytes_body = body::BytesBody
        try
            if body_closed(bytes_body)
                end_stream && _write_frame_h2_server_threadsafe!(write_lock, conn, DataFrame(stream_id, true, UInt8[]), write_deadline_ns)
                return nothing
            end
            first = bytes_body.next_index
            last = length(bytes_body.data)
            if first <= last
                data = first == 1 ? bytes_body.data : @view(bytes_body.data[first:last])
                _write_data_frames_h2_server!(conn, write_lock, send_state, stream_id, data; end_stream=end_stream, write_deadline_ns=write_deadline_ns)
                bytes_body.next_index = last + 1
            elseif end_stream
                _write_frame_h2_server_threadsafe!(write_lock, conn, DataFrame(stream_id, true, UInt8[]), write_deadline_ns)
            end
        finally
            body_close!(bytes_body)
        end
        return nothing
    end
    if body isa AbstractString
        # Zero-copy fast path: alias the String's codeunits (immutable) instead
        # of allocating a fresh Vector{UInt8} of the same length.
        s = String(body)
        ncodeunits(s) == 0 && return nothing
        _write_data_frames_h2_server!(conn, write_lock, send_state, stream_id, codeunits(s); end_stream=end_stream, write_deadline_ns=write_deadline_ns)
        return nothing
    end
    if body isa AbstractVector{UInt8}
        bytes = body isa Vector{UInt8} ? body : Vector{UInt8}(body)
        isempty(bytes) || _write_data_frames_h2_server!(conn, write_lock, send_state, stream_id, bytes; end_stream=end_stream, write_deadline_ns=write_deadline_ns)
        return nothing
    end
    body isa AbstractBody || throw(ProtocolError("unsupported HTTP/2 response body type $(typeof(body))"))
    buf = Vector{UInt8}(undef, 16 * 1024)
    try
        while true
            n = body_read!(body::AbstractBody, buf)
            if n == 0
                end_stream && _write_frame_h2_server_threadsafe!(write_lock, conn, DataFrame(stream_id, true, UInt8[]), write_deadline_ns)
                return nothing
            end
            _write_data_frames_h2_server!(
                conn,
                write_lock,
                send_state,
                stream_id,
                @view(buf[1:n]);
                end_stream=false,
                write_deadline_ns=write_deadline_ns,
            )
        end
    finally
        @try_ignore begin
            body_close!(body::AbstractBody)
        end
    end
end

"""
    _encode_h2_headers_frame_bytes_locked!(send_state, stream_id, header_fields,
                                           end_stream, max_frame_size,
                                           max_header_list_size) -> Vector{UInt8}

Encode a response's HEADERS frame (and any required CONTINUATION frames)
while the caller holds `write_lock`, returning the wire bytes ready to write
directly to the connection. The caller writes these bytes before releasing
`write_lock`, so the HPACK encoder's table changes reach the peer in order.
"""
function _encode_h2_headers_frame_bytes_locked!(
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    header_fields::Vector{HeaderField},
    end_stream::Bool,
    max_frame_size::Int,
    max_header_list_size::Int,
)::Vector{UInt8}
    header_block = _encode_h2_header_fields!(send_state.header_encoder, header_fields, max_header_list_size)
    out = IOBuffer()
    _header_block_frames(stream_id, end_stream, header_block, max_frame_size) do frame
        write_frame!(out, frame)
    end
    return take!(out)
end

function _write_h2_response!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    request::Request,
    response::Response,
    write_deadline_ns::Int64=Int64(0),
)::Nothing
    header_fields, trailer_fields = _h2_response_head(request, response)
    _write_h2_response!(conn, write_lock, send_state, stream_id, request, response, header_fields, trailer_fields, write_deadline_ns)
    return nothing
end

# Writes `response`, whose head `_h2_response_head` built. A handler may return
# one response for many requests at once, so nothing here modifies it.
function _write_h2_response!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    request::Request,
    response::Response,
    header_fields::Vector{HeaderField},
    trailer_fields::Vector{HeaderField},
    write_deadline_ns::Int64,
)::Nothing
    allows_body = _h2_response_allows_body(request, response)
    has_trailers = !isempty(trailer_fields)
    if !allows_body
        @try_ignore begin
            response.body isa AbstractBody && body_close!(response.body::AbstractBody)
        end
        _write_h2_header_fields!(conn, write_lock, send_state, stream_id, header_fields, !has_trailers, write_deadline_ns)
        has_trailers && _write_h2_header_fields!(conn, write_lock, send_state, stream_id, trailer_fields, true, write_deadline_ns)
        return nothing
    end
    body_empty = response.body isa EmptyBody ||
                 (response.body isa AbstractString && isempty(response.body::AbstractString)) ||
                 (response.body isa AbstractVector{UInt8} && isempty(response.body::AbstractVector{UInt8}))
    end_stream = body_empty && !has_trailers
    body = response.body
    # Streaming or empty bodies: write HEADERS, then the body and trailers.
    if body_empty || !(body isa AbstractString || body isa AbstractVector{UInt8})
        _write_h2_header_fields!(conn, write_lock, send_state, stream_id, header_fields, end_stream, write_deadline_ns)
        body_empty || _write_response_body_h2_server!(conn, write_lock, send_state, stream_id, response, !has_trailers, write_deadline_ns)
        has_trailers && _write_h2_header_fields!(conn, write_lock, send_state, stream_id, trailer_fields, true, write_deadline_ns)
        return nothing
    end
    # Fast path for buffered bodies (AbstractString or AbstractVector{UInt8}):
    # encode the HEADERS frame and emit headers + first DATA batch in a
    # single socket write under one write_lock acquisition. This both saves
    # syscalls and preserves HPACK ordering — the encoder mutation is on
    # the same lock as the wire emission.
    max_frame_size = 16_384
    max_header_list_size = 0
    lock(send_state.state_lock)
    try
        max_frame_size = send_state.peer_max_send_frame_size
        max_header_list_size = send_state.peer_max_header_list_size
    finally
        unlock(send_state.state_lock)
    end
    body_bytes::AbstractVector{UInt8} = body isa AbstractString ?
        codeunits(String(body)) :
        (body isa Vector{UInt8} ? body : Vector{UInt8}(body))
    _write_h2_headers_and_first_batch!(
        conn, write_lock, send_state, stream_id,
        header_fields,
        body_bytes, !has_trailers,
        max_frame_size, max_header_list_size, write_deadline_ns,
    )
    has_trailers && _write_h2_header_fields!(conn, write_lock, send_state, stream_id, trailer_fields, true, write_deadline_ns)
    return nothing
end

"""
    _write_h2_headers_and_first_batch!(...) -> Nothing

Write the HEADERS frame, and the first DATA frame if the peer has granted
credit, in one socket write, holding `write_lock` across encoding and writing
so HPACK state stays consistent. The rest of the body goes through
`_write_data_frames_h2_server!`, which waits for send credit without holding
`write_lock`.
"""
function _write_h2_headers_and_first_batch!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    header_fields::Vector{HeaderField},
    body::AbstractVector{UInt8},
    body_end_stream::Bool,
    max_frame_size::Int,
    max_header_list_size::Int,
    write_deadline_ns::Int64,
)::Nothing
    total_len = length(body)
    # Per-frame cap — the smaller of our local cap and the peer's setting.
    peer_max = lock(send_state.state_lock) do
        send_state.peer_max_send_frame_size
    end
    server_max = min(Int(_H2_SERVER_MAX_DATA_FRAME_SIZE), peer_max)
    # Take only the credit available now for the first DATA frame: HEADERS are
    # not flow-controlled and must not wait for WINDOW_UPDATE.
    first_chunk = total_len == 0 ? 0 : _reserve_h2_send_window!(send_state, stream_id, total_len; block=false)
    # Acquire write_lock and emit HEADERS + DATA batch atomically.
    lock(write_lock)
    try
        _set_write_deadline!(conn, write_deadline_ns)
        # 1. HEADERS frame bytes (encoder state advances under the lock).
        headers_bytes = _encode_h2_headers_frame_bytes_locked!(
            send_state, stream_id, header_fields,
            total_len == 0 ? body_end_stream : false,
            max_frame_size, max_header_list_size,
        )
        if total_len == 0
            _write_all_h2_server!(conn, headers_bytes)
            return nothing
        end
        # 2. Write HEADERS and the first DATA frame as one buffer.
        _write_h2_batch_via_single_buffer!(conn, stream_id, body, headers_bytes,
                                           1, first_chunk, server_max, body_end_stream, total_len)
    finally
        unlock(write_lock)
    end
    # 3. Wait for more credit without the lock: the read loop needs it to
    # answer PING and SETTINGS before it can read the WINDOW_UPDATE.
    first_chunk < total_len && _write_data_frames_h2_server!(
        conn, write_lock, send_state, stream_id, @view(body[(first_chunk + 1):total_len]);
        end_stream=body_end_stream, write_deadline_ns=write_deadline_ns,
    )
    return nothing
end

@inline function _write_h2_batch_via_single_buffer!(
    conn::Union{TCP.Conn,TLS.Conn},
    stream_id::UInt32,
    body::AbstractVector{UInt8},
    headers_bytes::Vector{UInt8},
    body_offset::Int,
    body_len::Int,
    server_max::Int,
    body_end_stream::Bool,
    total_len::Int,
)::Nothing
    n_data_frames = cld(body_len, server_max)
    out_len = length(headers_bytes) + body_len + 9 * n_data_frames
    out = Vector{UInt8}(undef, out_len)
    unsafe_copyto!(out, 1, headers_bytes, 1, length(headers_bytes))
    out_pos = length(headers_bytes) + 1
    rem = body_len
    cur = body_offset
    while rem > 0
        payload = min(rem, server_max, total_len - cur + 1)
        final_chunk = (cur + payload - 1) == total_len
        _stamp_h2_data_header!(out, out_pos, payload, body_end_stream && final_chunk, stream_id)
        out_pos += 9
        _copy_h2_payload!(out, out_pos, body, cur, payload)
        out_pos += payload
        cur += payload
        rem -= payload
    end
    write(conn, out)
    return nothing
end

# An error from the connection itself: the client closed it or a deadline passed.
@inline function _is_h2_transport_error(err)::Bool
    err isa Exception || return false
    return _classify_h2_conn_close(err::Exception) == _H2_CONN_CLOSE_PEER || _is_peer_close_error(err::Exception)
end

# Whether the stream can still carry a response: nobody reset it and the connection is up.
function _h2_server_stream_writable(state::_H2ServerStreamState, send_state::_H2SendWindowState)::Bool
    (@atomic :acquire send_state.closed) && return false
    lock(state.lock)
    try
        return state.cancel_kind == UInt8(_H2_SERVER_STREAM_OPEN)
    finally
        unlock(state.lock)
    end
end

function _handle_h2_stream!(
    server::Server,
    tracked::_ServerConn,
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    states_lock::ReentrantLock,
    states::Dict{UInt32,_H2ServerStreamState},
    stream_id::UInt32,
    state::_H2ServerStreamState,
    decoded_headers::Vector{HeaderField},
)::Nothing
    stream_done = false
    request_body = nothing
    lock(state.lock)
    try
        stream_done = state.stream_done
        if state.stream_done && _h2_server_available_bytes(state) == 0
            request_body = EmptyBody()
        else
            request_body = _H2ServerBody(conn, write_lock, states_lock, states, stream_id, tracked, state, send_state, false)
        end
    finally
        unlock(state.lock)
    end
    try
        request = _decode_h2_request(decoded_headers, request_body::AbstractBody, stream_done)
        request.trailers = state.trailers
        lock(state.lock)
        try
            state.request = request
        finally
            unlock(state.lock)
        end
        if server.stream
            stream = Stream(server, tracked, conn, write_lock, send_state, stream_id, request)
            try
                server.handler(stream)
                if !(@atomic :acquire stream.write_closed)
                    closewrite(stream)
                end
                closeread(stream)
            catch err
                # The stream's own reads and writes fail when the client resets
                # the stream or the connection fails; anything else is a handler bug.
                io_failed = err === stream.io_error
                io_failed || _log_handler_error(err, catch_backtrace(), request, conn)
                if io_failed || (@atomic :acquire stream.response_started)
                    # No 500 can follow a sent head or replace a broken stream.
                    _fail_h2_server_stream!(server, tracked, conn, write_lock, states_lock, states, send_state, state, _H2_ERROR_INTERNAL)
                else
                    stream.request_buffer = IOBuffer()
                    stream.response = _h2_status_response(500, request)
                    @atomic :release stream.response_started = false
                    @atomic :release stream.write_closed = false
                    @atomic :release stream.read_closed = false
                    closewrite(stream)
                end
                closeread(stream)
            end
        else
            handler_request = try
                _buffer_server_request(request, server.max_body_bytes; close_body_on_error=false)
            catch err
                # A request body that cannot be read keeps its status, such as 413.
                if _h2_server_stream_writable(state, send_state)
                    status = _server_error_status(err)
                    _write_h2_response!(
                        conn,
                        write_lock,
                        send_state,
                        stream_id,
                        request,
                        _h2_status_response(status === nothing ? 500 : status::Int, request),
                        _server_write_deadline_ns(server),
                    )
                end
                @try_ignore body_close!(request.body)
                return nothing
            end
            response = try
                server.handler(handler_request)
            catch err
                _log_handler_error(err, catch_backtrace(), request, conn)
                _write_h2_response!(
                    conn,
                    write_lock,
                    send_state,
                    stream_id,
                    request,
                    _h2_status_response(500, request),
                    _server_write_deadline_ns(server),
                )
                return nothing
            end
            if !(response isa Response)
                @error "h2 server handler must return HTTP.Response, got $(typeof(response))"
                _write_h2_response!(
                    conn,
                    write_lock,
                    send_state,
                    stream_id,
                    request,
                    _h2_status_response(500, request),
                    _server_write_deadline_ns(server),
                )
                return nothing
            end
            response_obj = response::Response
            # Build the head before writing, so a response that cannot be sent,
            # such as one with an invalid header or a spent body, gets 500.
            header_fields, trailer_fields = try
                _h2_response_head(handler_request, response_obj)
            catch err
                _log_handler_error(err, catch_backtrace(), request, conn)
                response_obj.body isa AbstractBody && @try_ignore body_close!(response_obj.body::AbstractBody)
                response_obj = _h2_status_response(500, handler_request)
                _h2_response_head(handler_request, response_obj)
            end
            _write_h2_response!(conn, write_lock, send_state, stream_id, handler_request, response_obj, header_fields, trailer_fields, _server_write_deadline_ns(server))
        end
        _request_body_fully_consumed(request) || body_close!(request.body)
    catch err
        stream_cancelled = false
        lock(state.lock)
        try
            stream_cancelled = state.cancel_kind != UInt8(_H2_SERVER_STREAM_OPEN) || state.aborted
        finally
            unlock(state.lock)
        end
        if !(stream_cancelled || (@atomic :acquire send_state.closed))
            # The response could not be sent; reset the stream so the client
            # does not wait for it. A peer that went away needs no log.
            _is_h2_transport_error(err) || @error "h2 server could not send the response" exception = err
            _fail_h2_server_stream!(server, tracked, conn, write_lock, states_lock, states, send_state, state, _H2_ERROR_INTERNAL)
        end
    finally
        lock(state.lock)
        try
            state.handler_finished = true
            notify(state.condition)
        finally
            unlock(state.lock)
        end
        _maybe_cleanup_h2_server_state!(tracked, states_lock, states, state, send_state)
    end
    return nothing
end

function _dispatch_h2_stream!(
    server::Server,
    tracked::_ServerConn,
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    states_lock::ReentrantLock,
    states::Dict{UInt32,_H2ServerStreamState},
    state::_H2ServerStreamState,
)::Nothing
    decoded_headers = nothing
    body_end_error = false
    lock(state.lock)
    try
        state.handler_started && return nothing
        state.headers_complete || return nothing
        state.decoded_headers === nothing && throw(ProtocolError("HTTP/2 request missing decoded headers"))
        decoded_headers = copy(state.decoded_headers::Vector{HeaderField})
    finally
        unlock(state.lock)
    end
    _, _, _, _, request_headers = _validate_h2_request_headers!(decoded_headers::Vector{HeaderField})
    declared_body_bytes = _parse_content_length(request_headers)
    lock(state.lock)
    try
        state.handler_started && return nothing
        state.declared_body_bytes = declared_body_bytes
        if state.stream_done
            try
                _check_h2_server_body_end_locked(state)
            catch err
                if err isa ProtocolError
                    body_end_error = true
                else
                    rethrow(err)
                end
            end
        end
        body_end_error || (state.handler_started = true)
    finally
        unlock(state.lock)
    end
    if body_end_error
        _fail_h2_server_stream!(server, tracked, conn, write_lock, states_lock, states, send_state, state, _H2_ERROR_PROTOCOL)
        return nothing
    end
    @_spawn_interactive _handle_h2_stream!(
        server, tracked, conn, write_lock, send_state, states_lock, states,
        state.stream_id, state, decoded_headers::Vector{HeaderField},
    )
    return nothing
end

function _try_write_h2_goaway!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    last_stream_id::UInt32,
    error_code::UInt32,
    write_deadline_ns::Int64,
)::Nothing
    @try_ignore begin
        _write_frame_h2_server_threadsafe!(write_lock, conn, GoAwayFrame(last_stream_id, error_code, UInt8[]), write_deadline_ns)
    end
    return nothing
end

function _request_h2_conn_shutdown!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    control::_H2ServerConnControl,
    write_deadline_ns::Int64,
)::Nothing
    @atomic :release control.shutdown_requested = true
    (@atomic :acquire control.goaway_sent) && return nothing
    last_stream_id = @atomic :acquire control.graceful_last_stream_id
    _try_write_h2_goaway!(conn, write_lock, last_stream_id, UInt32(0), write_deadline_ns)
    @atomic :release control.goaway_sent = true
    return nothing
end

# Adds one HEADERS or CONTINUATION frame to the size of the header block being
# received. Each frame's 9-byte header counts too, so a peer cannot stretch a
# block across endless empty CONTINUATION frames.
@inline function _h2_charge_header_block_frame(block_bytes::Int, fragment::Vector{UInt8}, max_header_block_bytes::Int)::Int
    block_bytes += 9 + length(fragment)
    block_bytes <= max_header_block_bytes || throw(ProtocolError("HTTP/2 request header block exceeded maximum size", _PROTOCOL_ERROR_HEADERS_TOO_LARGE))
    return block_bytes
end

# Refuse a new HTTP/2 stream without allocating per-stream state or spawning a
# handler. The header block is still decoded into the connection-wide HPACK
# decoder so the connection does not desync; CONTINUATION frames belonging to
# the refused stream are consumed inline using a throwaway buffer. Finally a
# RST_STREAM(`error_code`) is sent for the refused stream id.
function _h2_server_refuse_stream!(
    server::Server,
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    reader::IO,
    decoder::Decoder,
    hf::HeadersFrame,
    max_header_block_bytes::Int,
    error_code::UInt32,
)::Nothing
    block = copy(hf.header_block_fragment)
    block_bytes = _h2_charge_header_block_frame(0, block, max_header_block_bytes)
    end_headers = hf.end_headers
    while !end_headers
        # The peer must complete the header block with CONTINUATION frames for
        # this same stream before any other frame (RFC 9113 §6.10). Reuse the
        # request-header read deadline so a stalled block cannot hold the slot.
        _set_read_deadline!(conn, _deadline_after(server.read_header_timeout_ns > 0 ? server.read_header_timeout_ns : server.read_timeout_ns))
        frame = read_frame!(reader)
        frame isa ContinuationFrame || throw(ProtocolError("expected CONTINUATION for stream $(hf.stream_id)"))
        cf = frame::ContinuationFrame
        cf.stream_id == hf.stream_id || throw(ProtocolError("expected CONTINUATION for stream $(hf.stream_id)"))
        block_bytes = _h2_charge_header_block_frame(block_bytes, cf.header_block_fragment, max_header_block_bytes)
        append!(block, cf.header_block_fragment)
        end_headers = cf.end_headers
    end
    # Keep the shared HPACK decoder state consistent with the peer's encoder.
    decode_header_block(decoder, block)
    @try_ignore begin
        _write_frame_h2_server_threadsafe!(
            write_lock,
            conn,
            RSTStreamFrame(hf.stream_id, error_code),
            _server_write_deadline_ns(server),
        )
    end
    return nothing
end

function _serve_h2_conn!(server::Server, tracked::_ServerConn, reader_source)::Nothing
    conn = tracked.conn
    decoder = Decoder(
        max_string_length=server.max_header_bytes,
        max_header_list_size=server.max_header_bytes,
    )
    max_header_block_bytes = _h2_max_header_block_bytes(server)
    write_lock = ReentrantLock()
    states_lock = ReentrantLock()
    send_state = _H2SendWindowState(server.write_timeout_ns)
    conn_control = _H2ServerConnControl()
    states = Dict{UInt32,_H2ServerStreamState}()
    continuation_stream = UInt32(0)
    # Size of the header block being received; see `_h2_charge_header_block_frame`.
    header_block_bytes = 0
    max_stream_id = UInt32(0)
    peer_goaway_last_stream_id = typemax(UInt32)
    # Per-connection stream-flood limits.
    max_concurrent_streams = server.max_concurrent_streams
    # Number of streams the peer has opened and then reset/closed via RST_STREAM.
    # Tracked to detect the CVE-2023-44487 "Rapid Reset" pattern, where the peer
    # keeps its own concurrent-stream count low by immediately cancelling each
    # stream it opens.
    reset_stream_count = 0
    # Once the peer resets more than this many streams, treat the connection as
    # abusive: send GOAWAY(ENHANCE_YOUR_CALM) and stop accepting new streams.
    rapid_reset_budget = max_concurrent_streams > 0 ?
        max_concurrent_streams + _H2_RAPID_RESET_ALLOWANCE : 0
    close_kind = _H2_CONN_CLOSE_CLEAN
    try
        preface = _read_exact_h2_server!(reader_source, length(_H2_PREFACE))
        preface == _H2_PREFACE || throw(ProtocolError("invalid h2 client preface"))
        reader = _ConnReader(reader_source)
        client_settings = read_frame!(reader)
        client_settings isa SettingsFrame || throw(ProtocolError("expected initial h2 SETTINGS frame"))
        (client_settings::SettingsFrame).ack && throw(ProtocolError("initial h2 SETTINGS frame must not be ACK"))
        _apply_h2_peer_settings!(send_state, write_lock, (client_settings::SettingsFrame).settings)
        initial_settings = Pair{UInt16,UInt32}[]
        if max_concurrent_streams > 0
            push!(initial_settings, _H2_SETTINGS_MAX_CONCURRENT_STREAMS => UInt32(max_concurrent_streams))
        end
        if server.http2_settings.initial_window_size != _H2_DEFAULT_WINDOW_SIZE
            push!(initial_settings, _H2_SETTINGS_INITIAL_WINDOW_SIZE => UInt32(server.http2_settings.initial_window_size))
        end
        _write_frame_h2_server_threadsafe!(write_lock, conn, SettingsFrame(false, initial_settings), _server_write_deadline_ns(server))
        _write_frame_h2_server_threadsafe!(write_lock, conn, SettingsFrame(true, Pair{UInt16,UInt32}[]), _server_write_deadline_ns(server))
        if server.http2_settings.connection_window_size > _H2_DEFAULT_WINDOW_SIZE
            bump = server.http2_settings.connection_window_size - _H2_DEFAULT_WINDOW_SIZE
            @atomic send_state.conn_recv_window += bump
            _write_frame_h2_server_threadsafe!(write_lock, conn, WindowUpdateFrame(UInt32(0), UInt32(bump)), _server_write_deadline_ns(server))
        end
        _clear_deadlines!(conn)
        _set_conn_shutdown_hook!(tracked, _H2ShutdownHook(write_lock, conn_control))
        _set_conn_state!(tracked, _ConnState.IDLE)
        while true
            # A graceful shutdown keeps reading until the streams its GOAWAY
            # covered are done; they still need WINDOW_UPDATE, PING, and DATA.
            _server_shutting_down(server) && !_h2_server_has_active_streams(states_lock, states) && return nothing
            _set_h2_frame_read_deadline!(server, conn, states_lock, states, continuation_stream)
            frame = try
                read_frame!(reader)
            catch err
                if err isa EOFError || err isa IOPoll.NetClosingError || err isa TLS.TLSError
                    return nothing
                end
                rethrow(err)
            end
            if continuation_stream != UInt32(0)
                if !(frame isa ContinuationFrame && (frame::ContinuationFrame).stream_id == continuation_stream)
                    throw(ProtocolError("expected CONTINUATION for stream $(continuation_stream)"))
                end
            elseif frame isa ContinuationFrame
                throw(ProtocolError("unexpected CONTINUATION frame"))
            end
            if frame isa SettingsFrame
                sf = frame::SettingsFrame
                if !sf.ack
                    _apply_h2_peer_settings!(send_state, write_lock, sf.settings)
                    _write_frame_h2_server_threadsafe!(write_lock, conn, SettingsFrame(true, Pair{UInt16,UInt32}[]), _server_write_deadline_ns(server))
                end
                continue
            end
            if frame isa PingFrame
                ping = frame::PingFrame
                ping.ack || _write_frame_h2_server_threadsafe!(write_lock, conn, PingFrame(true, ping.opaque_data), _server_write_deadline_ns(server))
                continue
            end
            if frame isa WindowUpdateFrame
                _apply_h2_window_update!(send_state, frame::WindowUpdateFrame)
                continue
            end
            if frame isa RSTStreamFrame
                rst = frame::RSTStreamFrame
                rst.stream_id == UInt32(0) && throw(ProtocolError("RST_STREAM stream id must be non-zero"))
                lock(states_lock)
                state = try
                    get(() -> nothing, states, rst.stream_id)
                finally
                    unlock(states_lock)
                end
                state === nothing && continue
                # Count this as a peer-initiated reset only on the first
                # OPEN -> RESET transition so duplicate RST_STREAM frames for the
                # same in-flight stream cannot inflate the Rapid-Reset counter.
                first_reset = false
                lock(state.lock)
                try
                    first_reset = state.cancel_kind == UInt8(_H2_SERVER_STREAM_OPEN)
                finally
                    unlock(state.lock)
                end
                discarded = _set_h2_server_stream_cancelled!(state, _H2_SERVER_STREAM_RESET, true, true, true)
                _unregister_h2_send_window!(send_state, rst.stream_id)
                _send_h2_server_window_updates!(conn, write_lock, send_state, rst.stream_id, discarded, false)
                _maybe_cleanup_h2_server_state!(tracked, states_lock, states, state, send_state)
                if first_reset
                    reset_stream_count += 1
                    # Rapid Reset (CVE-2023-44487): a peer that keeps opening and
                    # immediately resetting streams drives unbounded handler/task
                    # creation while keeping its own concurrent-stream count low.
                    # Past the budget, send GOAWAY(ENHANCE_YOUR_CALM) and refuse
                    # any further new streams by draining the connection.
                    if rapid_reset_budget > 0 && reset_stream_count > rapid_reset_budget &&
                        !(@atomic :acquire conn_control.goaway_sent)
                        @try_ignore begin
                            _write_frame_h2_server_threadsafe!(
                                write_lock,
                                conn,
                                GoAwayFrame(max_stream_id, _H2_ERROR_ENHANCE_YOUR_CALM, UInt8[]),
                                _server_write_deadline_ns(server),
                            )
                        end
                        @atomic :release conn_control.goaway_sent = true
                        @atomic :release conn_control.shutdown_requested = true
                        @atomic :release conn_control.graceful_last_stream_id = max_stream_id
                    end
                end
                continue
            end
            if frame isa GoAwayFrame
                goaway = frame::GoAwayFrame
                peer_goaway_last_stream_id = min(peer_goaway_last_stream_id, goaway.last_stream_id)
                goaway.error_code == UInt32(0) || throw(ProtocolError("HTTP/2 peer sent GOAWAY"))
                continue
            end
            if frame isa HeadersFrame
                hf = frame::HeadersFrame
                hf.stream_id == UInt32(0) && throw(ProtocolError("HEADERS stream id must be non-zero"))
                iseven(hf.stream_id) && throw(ProtocolError("HEADERS stream id must be odd for client-initiated streams"))
                hf.stream_id > peer_goaway_last_stream_id && throw(ProtocolError("client opened stream after GOAWAY"))
                goaway_refused = false
                if (@atomic :acquire conn_control.shutdown_requested) && hf.stream_id > (@atomic :acquire conn_control.graceful_last_stream_id)
                    # A graceful shutdown refuses the streams its GOAWAY did not
                    # cover (RFC 9113 §6.8); after an error GOAWAY this is fatal.
                    _server_shutting_down(server) || throw(ProtocolError("client opened stream after server GOAWAY"))
                    goaway_refused = true
                end
                # A HEADERS frame either continues an already-tracked stream
                # (e.g. request trailers) or opens a brand-new one. New streams
                # must pass the stream-id monotonicity check and the
                # concurrent-stream / Rapid-Reset limits before any state is
                # allocated or any handler is dispatched.
                refuse_stream = false
                refuse_enhance_calm = false
                lock(states_lock)
                state = try
                    if haskey(states, hf.stream_id)
                        states[hf.stream_id]
                    else
                        decision = _h2_server_new_stream_decision(
                            hf.stream_id,
                            max_stream_id,
                            length(states),
                            reset_stream_count,
                            max_concurrent_streams,
                            rapid_reset_budget,
                        )
                        if decision == _H2_NEW_STREAM_NON_MONOTONIC
                            # RFC 9113 §5.1.1: reusing a closed/old id is a
                            # connection error, not a per-stream refusal.
                            throw(ProtocolError("HEADERS stream id must increase monotonically"))
                        end
                        # Even when refusing, advance `max_stream_id` so the same
                        # id can never be retried and HPACK ordering is preserved.
                        max_stream_id = hf.stream_id
                        goaway_refused || (@atomic :release conn_control.graceful_last_stream_id = max_stream_id)
                        if goaway_refused || decision == _H2_NEW_STREAM_REFUSED
                            refuse_stream = true
                            nothing
                        elseif decision == _H2_NEW_STREAM_ENHANCE_CALM
                            refuse_stream = true
                            refuse_enhance_calm = true
                            nothing
                        else
                            created = _H2ServerStreamState(hf.stream_id, _h2_buffered_bytes(server.http2_settings))
                            states[hf.stream_id] = created
                            _register_h2_send_window!(send_state, hf.stream_id)
                            created
                        end
                    end
                finally
                    unlock(states_lock)
                end
                if refuse_stream
                    # Decode the header block to keep the connection-wide HPACK
                    # decoder in sync, but allocate no per-stream state and spawn
                    # no handler. Multi-frame header blocks are accumulated in a
                    # throwaway buffer that is discarded once END_HEADERS arrives.
                    _h2_server_refuse_stream!(
                        server, conn, write_lock, reader, decoder,
                        hf, max_header_block_bytes,
                        refuse_enhance_calm ? _H2_ERROR_ENHANCE_YOUR_CALM : _H2_ERROR_REFUSED_STREAM,
                    )
                    if refuse_enhance_calm && !(@atomic :acquire conn_control.goaway_sent)
                        @try_ignore begin
                            _write_frame_h2_server_threadsafe!(
                                write_lock,
                                conn,
                                GoAwayFrame(max_stream_id, _H2_ERROR_ENHANCE_YOUR_CALM, UInt8[]),
                                _server_write_deadline_ns(server),
                            )
                        end
                        @atomic :release conn_control.goaway_sent = true
                        @atomic :release conn_control.shutdown_requested = true
                        @atomic :release conn_control.graceful_last_stream_id = max_stream_id
                    end
                    continue
                end
                stream_error = false
                lock(state.lock)
                try
                    initial_headers = !state.headers_complete
                    if !initial_headers
                        state.stream_done && throw(ProtocolError("unexpected additional HTTP/2 HEADERS on request stream"))
                        state.trailers_complete && throw(ProtocolError("unexpected additional HTTP/2 HEADERS on request stream"))
                        hf.end_stream || throw(ProtocolError("HTTP/2 request trailers must end the stream"))
                    end
                    header_block_bytes = _h2_charge_header_block_frame(0, hf.header_block_fragment, max_header_block_bytes)
                    append!(state.header_block, hf.header_block_fragment)
                    hf.end_stream && (state.header_block_end_stream = true)
                    if hf.end_headers
                        decoded = decode_header_block(decoder, state.header_block)
                        empty!(state.header_block)
                        if initial_headers
                            state.decoded_headers = decoded
                            state.headers_complete = true
                        else
                            # One pass in wire order: a peer picks how many
                            # trailer fields arrive, so no per-name rescans.
                            append!(state.trailers, _decode_h2_trailer_headers(decoded))
                            state.trailers_complete = true
                        end
                        state.header_block_end_stream && (stream_error = _end_h2_server_stream_locked!(state))
                    end
                    hf.end_headers || (continuation_stream = hf.stream_id)
                    notify(state.condition)
                finally
                    unlock(state.lock)
                end
                _update_h2_server_conn_state!(tracked, states_lock, states)
                if stream_error
                    _fail_h2_server_stream!(server, tracked, conn, write_lock, states_lock, states, send_state, state, _H2_ERROR_PROTOCOL)
                    continue
                end
                if hf.end_headers
                    continuation_stream = UInt32(0)
                    !state.trailers_complete && _dispatch_h2_stream!(server, tracked, conn, write_lock, send_state, states_lock, states, state)
                end
                continue
            end
            if frame isa ContinuationFrame
                cf = frame::ContinuationFrame
                cf.stream_id == UInt32(0) && throw(ProtocolError("CONTINUATION stream id must be non-zero"))
                lock(states_lock)
                state = try
                    get(() -> throw(ProtocolError("CONTINUATION received for unknown stream")), states, cf.stream_id)
                finally
                    unlock(states_lock)
                end
                stream_error = false
                lock(state.lock)
                try
                    initial_headers = !state.headers_complete
                    header_block_bytes = _h2_charge_header_block_frame(header_block_bytes, cf.header_block_fragment, max_header_block_bytes)
                    append!(state.header_block, cf.header_block_fragment)
                    if cf.end_headers
                        decoded = decode_header_block(decoder, state.header_block)
                        empty!(state.header_block)
                        if initial_headers
                            state.decoded_headers = decoded
                            state.headers_complete = true
                        else
                            # One pass in wire order: a peer picks how many
                            # trailer fields arrive, so no per-name rescans.
                            append!(state.trailers, _decode_h2_trailer_headers(decoded))
                            state.trailers_complete = true
                        end
                        state.header_block_end_stream && (stream_error = _end_h2_server_stream_locked!(state))
                        continuation_stream = UInt32(0)
                    else
                        continuation_stream = cf.stream_id
                    end
                    notify(state.condition)
                finally
                    unlock(state.lock)
                end
                if stream_error
                    _fail_h2_server_stream!(server, tracked, conn, write_lock, states_lock, states, send_state, state, _H2_ERROR_PROTOCOL)
                    continue
                end
                cf.end_headers && !state.trailers_complete && _dispatch_h2_stream!(server, tracked, conn, write_lock, send_state, states_lock, states, state)
                continue
            end
            if frame isa DataFrame
                df = frame::DataFrame
                df.stream_id == UInt32(0) && throw(ProtocolError("DATA stream id must be non-zero"))
                iseven(df.stream_id) && throw(ProtocolError("DATA stream id must be odd for client-initiated streams"))
                # RFC 9113 §6.9.1: the whole payload, padding included, counts
                # against the connection window, whatever becomes of the frame.
                frame_bytes = length(df.data) + df.padding
                (@atomic send_state.conn_recv_window -= frame_bytes) >= 0 ||
                    throw(ProtocolError("HTTP/2 DATA exceeded the connection flow-control window"))
                lock(states_lock)
                state = try
                    get(states, df.stream_id, nothing)
                finally
                    unlock(states_lock)
                end
                if state === nothing
                    df.stream_id > max_stream_id && throw(ProtocolError("DATA frame received before HEADERS"))
                    # A refused or finished stream: drop the DATA but return its
                    # connection-level flow-control credit.
                    _send_h2_server_window_updates!(conn, write_lock, send_state, df.stream_id, frame_bytes, false)
                    continue
                end
                stream_error = false
                # Set for DATA that is not buffered for the handler, whose credit goes back now.
                dropped = false
                lock(state.lock)
                try
                    state.headers_complete || throw(ProtocolError("DATA frame received before END_HEADERS"))
                    if state.stream_done || state.trailers_complete
                        stream_error = true
                        dropped = true
                    elseif state.aborted
                        dropped = true
                        df.end_stream && (state.stream_done = true)
                        notify(state.condition)
                    else
                        new_received = state.received_body_bytes + Int64(length(df.data))
                        if state.declared_body_bytes >= 0 && new_received > state.declared_body_bytes
                            stream_error = true
                            dropped = true
                        else
                            available_after = _h2_server_available_bytes(state) + length(df.data)
                            available_after <= state.max_buffered_bytes || throw(ProtocolError("HTTP/2 request body exceeded buffered server limit"))
                            append!(state.body, df.data)
                            state.received_body_bytes = new_received
                            if df.end_stream
                                state.stream_done = true
                                try
                                    _check_h2_server_body_end_locked(state)
                                catch err
                                    if err isa ProtocolError
                                        stream_error = true
                                    else
                                        rethrow(err)
                                    end
                                end
                            end
                        end
                        notify(state.condition)
                    end
                finally
                    unlock(state.lock)
                end
                if dropped
                    _send_h2_server_window_updates!(conn, write_lock, send_state, df.stream_id, frame_bytes, false)
                else
                    # Padding never reaches the handler, so it goes back now; at
                    # the stream level only while the stream can carry more DATA.
                    _send_h2_server_window_updates!(conn, write_lock, send_state, df.stream_id, df.padding, !df.end_stream && !stream_error)
                end
                if stream_error
                    _fail_h2_server_stream!(server, tracked, conn, write_lock, states_lock, states, send_state, state, _H2_ERROR_PROTOCOL)
                elseif dropped
                    _maybe_cleanup_h2_server_state!(tracked, states_lock, states, state, send_state)
                end
                continue
            end
        end
    catch err
        close_kind = _classify_h2_conn_close(err::Exception)
        close_kind == _H2_CONN_CLOSE_INTERNAL && rethrow(err)
        return nothing
    finally
        close_kind == _H2_CONN_CLOSE_PROTOCOL && _try_write_h2_goaway!(conn, write_lock, max_stream_id, UInt32(0x1), _server_write_deadline_ns(server))
        _fail_h2_send_window_state!(send_state)
        _fail_h2_server_streams!(states_lock, states, send_state)
        _set_conn_shutdown_hook!(tracked, nothing)
        _finalize_server_conn!(server, tracked)
    end
    return nothing
end
