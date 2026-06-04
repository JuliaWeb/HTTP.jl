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
    trailers_complete::Bool
    handler_started::Bool
    handler_finished::Bool
    aborted::Bool
    cancel_kind::UInt8
end

function _H2ServerStreamState(stream_id::UInt32)
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
        256 * 1024,
        Int64(-1),
        Int64(0),
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
    @atomic closed::Bool
end

function _H2SendWindowState()
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
        false,
    )
end

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

mutable struct _H2ServerConnControl
    @atomic shutdown_requested::Bool
    @atomic goaway_sent::Bool
    @atomic graceful_last_stream_id::UInt32
end

function _H2ServerConnControl()
    return _H2ServerConnControl(false, false, UInt32(0))
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

const _H2_FLOW_CONTROL_MAX_WINDOW = Int64(0x7fff_ffff)
const _H2_ERROR_PROTOCOL = UInt32(0x1)
const _H2_ERROR_INTERNAL = UInt32(0x2)
const _H2_ERROR_CANCEL = UInt32(0x8)

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
        size = header_table_size::Int
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

function _wait_h2_send_window_locked!(send_state::_H2SendWindowState, deadline_ns::Int64)::Nothing
    if deadline_ns == 0
        wait(send_state.window_condition)
        return nothing
    end
    remaining_ns = deadline_ns - Int64(time_ns())
    remaining_ns <= 0 && throw(IOPoll.DeadlineExceededError())
    unlock(send_state.state_lock)
    try
        IOPoll.sleep_ns(min(remaining_ns, Int64(1_000_000)))
    finally
        lock(send_state.state_lock)
    end
    return nothing
end

function _reserve_h2_send_window!(send_state::_H2SendWindowState, stream_id::UInt32, wanted::Int, deadline_ns::Int64=Int64(0))::Int
    wanted > 0 || throw(ArgumentError("wanted send window must be > 0"))
    lock(send_state.state_lock)
    try
        while true
            (@atomic :acquire send_state.closed) && throw(ProtocolError("HTTP/2 connection is closed"))
            haskey(send_state.stream_send_window, stream_id) || throw(ProtocolError("HTTP/2 stream send window is closed"))
            stream_window = send_state.stream_send_window[stream_id]
            if stream_window <= 0 || send_state.conn_send_window <= 0
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

function _send_h2_server_window_updates!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    stream_id::UInt32,
    nbytes::Int,
    stream_level::Bool=true,
)::Nothing
    nbytes <= 0 && return nothing
    increment = UInt32(nbytes)
    try
        _write_frame_h2_server_threadsafe!(write_lock, conn, WindowUpdateFrame(UInt32(0), increment))
        stream_level && _write_frame_h2_server_threadsafe!(write_lock, conn, WindowUpdateFrame(stream_id, increment))
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
        should_delete = state.handler_finished && state.stream_done && _h2_server_available_bytes(state) == 0
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

function _set_h2_server_stream_cancelled!(
    state::_H2ServerStreamState,
    kind::_H2ServerStreamCancelKind,
    aborted::Bool=true,
    discard_body::Bool=true,
    finish_if_unstarted::Bool=false,
)::Nothing
    lock(state.lock)
    try
        state.cancel_kind == UInt8(_H2_SERVER_STREAM_OPEN) && (state.cancel_kind = UInt8(kind))
        aborted && (state.aborted = true)
        state.stream_done = true
        if discard_body
            empty!(state.body)
            state.body_read_index = 1
        end
        finish_if_unstarted && !state.handler_started && (state.handler_finished = true)
        notify(state.condition)
    finally
        unlock(state.lock)
    end
    return nothing
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
    _set_h2_server_stream_cancelled!(state, _H2_SERVER_STREAM_RESET, true, true, true)
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
            _send_h2_server_window_updates!(body.conn, body.write_lock, body.stream_id, nread)
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
    lock(body.state.lock)
    try
        if !body.state.stream_done && !body.state.aborted
            body.state.aborted = true
            should_reset = true
        elseif body.state.stream_done && _h2_server_available_bytes(body.state) > 0
            body.state.aborted = true
            empty!(body.state.body)
            body.state.body_read_index = 1
        end
        notify(body.state.condition)
    finally
        unlock(body.state.lock)
    end
    if should_reset
        @try_ignore begin
            _write_frame_h2_server_threadsafe!(body.write_lock, body.conn, RSTStreamFrame(body.stream_id, UInt32(0x8)))
        end
    end
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

function _write_frame_h2_server!(conn::Union{TCP.Conn,TLS.Conn}, frame::AbstractFrame, write_deadline_ns::Int64=Int64(0))::Nothing
    io = IOBuffer()
    write_frame!(io, frame)
    write_deadline_ns > 0 && _set_write_deadline!(conn, write_deadline_ns)
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
    write_deadline_ns > 0 && _set_write_deadline!(conn, write_deadline_ns)
    # Each "batch" drains as much of the body as the peer's current send window
    # allows and emits it as DATA frames. Each frame is written as a 9-byte
    # header (from a single reused scratch buffer) followed by the payload slice
    # taken DIRECTLY from `data` (zero-copy: a unit-range view of a Vector{UInt8}
    # or Base.CodeUnits is a stride-1 StridedVector, so `write(conn, ::view)`
    # passes the underlying pointer straight to the socket — exactly like the
    # HTTP/1 body path).
    #
    # The previous implementation allocated a fresh Vector sized to the whole
    # windowed body on EVERY response and copied the body into it. Under HTTP/2's
    # per-stream `@spawn` those large, short-lived allocations are retained by the
    # glibc malloc per-thread arenas and never returned to the OS, so process RSS
    # climbs in proportion to response body size even though the Julia heap stays
    # flat. Writing the body in place removes that per-response allocation; the
    # only buffer here is the reused 9-byte frame header.
    header = Vector{UInt8}(undef, 9)
    while offset <= total_len
        # Probe the current allowed window with the size remaining.
        # Reservation is bounded by stream/conn windows only; per-frame
        # max-frame-size is applied below when slicing the reservation
        # into DATA frames. Reservation may block on a peer WINDOW_UPDATE,
        # so it must happen OUTSIDE write_lock.
        first_chunk = _reserve_h2_send_window!(send_state, stream_id, total_len - offset + 1, write_deadline_ns)
        first_chunk <= 0 && continue
        # IMPORTANT: write all frames for this reservation BEFORE attempting
        # another reservation. `_reserve_h2_send_window!` blocks if the peer's
        # send window is exhausted, and the peer won't send WINDOW_UPDATE until
        # it has received the bytes we just wrote. We hold write_lock across the
        # whole reservation so its frames stay contiguous on the wire.
        lock(write_lock)
        try
            remaining_in_res = first_chunk
            while remaining_in_res > 0
                payload = min(remaining_in_res, max_frame_size, total_len - offset + 1)
                final_chunk = (offset + payload - 1) == total_len
                _stamp_h2_data_header!(header, 1, payload, end_stream && final_chunk, stream_id)
                _write_all_h2_server!(conn, header)
                _write_h2_payload_slice!(conn, data, offset, payload)
                offset += payload
                remaining_in_res -= payload
            end
        finally
            unlock(write_lock)
        end
    end
    return nothing
end

# Write `n` bytes of the response body starting at `data[offset]` straight to the
# socket. For the body types the response path actually uses (Vector{UInt8} and
# Base.CodeUnits, both DenseVector) a unit-range view is a stride-1 StridedVector,
# so `write(conn, ::view)` hits the zero-copy pointer path. The generic fallback
# materializes only the slice (never the whole body) for any other AbstractVector.
@inline function _write_h2_payload_slice!(
    conn::Union{TCP.Conn,TLS.Conn},
    data::AbstractVector{UInt8},
    offset::Int,
    n::Int,
)::Nothing
    slice = @view data[offset:(offset + n - 1)]
    nw = write(conn, slice)
    nw == n || throw(ProtocolError("h2 server payload write made no progress"))
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
                method = normalized
            elseif name == ":scheme"
                scheme === nothing || throw(ProtocolError("duplicate HTTP/2 :scheme pseudo-header"))
                scheme = normalized
            elseif name == ":path"
                path === nothing || throw(ProtocolError("duplicate HTTP/2 :path pseudo-header"))
                path = normalized
            elseif name == ":authority"
                authority === nothing || throw(ProtocolError("duplicate HTTP/2 :authority pseudo-header"))
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
        if name == "cookie"
            if hasheader(out_headers, "Cookie")
                setheader(out_headers, "Cookie", string(header(out_headers, "Cookie"), "; ", normalized))
            else
                setheader(out_headers, "Cookie", normalized)
            end
            continue
        end
        appendheader(out_headers, name, normalized)
    end
    method === nothing && throw(ProtocolError("missing HTTP/2 :method pseudo-header"))
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

function _encode_h2_response_headers!(encoder::Encoder, response_status::Int, response_headers::Headers, max_header_list_size::Int=0)::Vector{UInt8}
    header_fields = HeaderField[HeaderField(":status", string(response_status), false)]
    _append_h2_headers!(header_fields, response_headers)
    max_header_list_size > 0 && _header_list_size(header_fields) > max_header_list_size && throw(ProtocolError("HTTP/2 response headers exceed peer SETTINGS_MAX_HEADER_LIST_SIZE"))
    return encode_header_block(encoder, header_fields)
end

function _encode_h2_trailer_headers!(encoder::Encoder, trailers::Headers, max_header_list_size::Int=0)::Vector{UInt8}
    header_fields = HeaderField[]
    _append_h2_headers!(header_fields, trailers; trailers=true)
    max_header_list_size > 0 && _header_list_size(header_fields) > max_header_list_size && throw(ProtocolError("HTTP/2 response trailers exceed peer SETTINGS_MAX_HEADER_LIST_SIZE"))
    return encode_header_block(encoder, header_fields)
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

function _write_h2_response_headers!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    response_status::Int,
    response_headers::Headers,
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
        header_block = _encode_h2_response_headers!(send_state.header_encoder, response_status, response_headers, max_header_list_size)
        _write_h2_header_block_locked!(conn, stream_id, header_block, end_stream, max_frame_size, write_deadline_ns)
    finally
        unlock(write_lock)
    end
    return nothing
end

function _write_h2_trailers!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    trailers::Headers,
    write_deadline_ns::Int64=Int64(0),
)::Nothing
    isempty(trailers) && return nothing
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
        header_block = _encode_h2_trailer_headers!(send_state.header_encoder, trailers, max_header_list_size)
        _write_h2_header_block_locked!(conn, stream_id, header_block, true, max_frame_size, write_deadline_ns)
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
    pending = UInt8[]
    have_pending = false
    try
        while true
            n = body_read!(body::AbstractBody, buf)
            if n == 0
                if have_pending
                    _write_data_frames_h2_server!(conn, write_lock, send_state, stream_id, pending; end_stream=end_stream, write_deadline_ns=write_deadline_ns)
                elseif end_stream
                    _write_frame_h2_server_threadsafe!(write_lock, conn, DataFrame(stream_id, true, UInt8[]), write_deadline_ns)
                end
                return nothing
            end
            current = Vector{UInt8}(undef, n)
            copyto!(current, 1, buf, 1, n)
            if have_pending
                _write_data_frames_h2_server!(conn, write_lock, send_state, stream_id, pending; end_stream=false, write_deadline_ns=write_deadline_ns)
            end
            pending = current
            have_pending = true
        end
    finally
        @try_ignore begin
            body_close!(body::AbstractBody)
        end
    end
end

"""
    _encode_h2_headers_frame_bytes!(send_state, write_lock, stream_id, status,
                                    headers, end_stream, max_frame_size,
                                    max_header_list_size) -> Vector{UInt8}

Encode a response's HEADERS frame (and any required CONTINUATION frames)
under `write_lock`, returning the wire bytes ready to write directly to
the connection. Caller is responsible for emitting these bytes BEFORE any
other header block emission on the same connection so HPACK dynamic-table
state stays consistent. Holds `write_lock` only for the encoding step.
"""
function _encode_h2_headers_frame_bytes_locked!(
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    response_status::Int,
    response_headers::Headers,
    end_stream::Bool,
    max_frame_size::Int,
    max_header_list_size::Int,
)::Vector{UInt8}
    header_block = _encode_h2_response_headers!(send_state.header_encoder, response_status, response_headers, max_header_list_size)
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
    response.request = request
    allows_body = _h2_response_allows_body(request, response)
    has_trailers = !isempty(response.trailers)
    if !allows_body
        @try_ignore begin
            response.body isa AbstractBody && body_close!(response.body::AbstractBody)
        end
        _write_h2_response_headers!(conn, write_lock, send_state, stream_id, response.status, response.headers, !has_trailers, write_deadline_ns)
        has_trailers && _write_h2_trailers!(conn, write_lock, send_state, stream_id, response.trailers, write_deadline_ns)
        return nothing
    end
    body_empty = response.body isa EmptyBody ||
                 (response.body isa AbstractString && isempty(response.body::AbstractString)) ||
                 (response.body isa AbstractVector{UInt8} && isempty(response.body::AbstractVector{UInt8}))
    end_stream = body_empty && !has_trailers
    body = response.body
    # Fallback path for streaming/empty bodies: original two-step path.
    if body_empty || !(body isa AbstractString || body isa AbstractVector{UInt8})
        _write_h2_response_headers!(conn, write_lock, send_state, stream_id, response.status, response.headers, end_stream, write_deadline_ns)
        body_empty || _write_response_body_h2_server!(conn, write_lock, send_state, stream_id, response, !has_trailers, write_deadline_ns)
        has_trailers && _write_h2_trailers!(conn, write_lock, send_state, stream_id, response.trailers, write_deadline_ns)
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
        response.status, response.headers,
        body_bytes, !has_trailers,
        max_frame_size, max_header_list_size, write_deadline_ns,
    )
    has_trailers && _write_h2_trailers!(conn, write_lock, send_state, stream_id, response.trailers, write_deadline_ns)
    return nothing
end

"""
    _write_h2_headers_and_first_batch!(...) -> Nothing

Emit the HEADERS frame + as many DATA frames as the current send window
allows in one socket write, holding `write_lock` across encoder + emit so
HPACK state stays consistent. Any body bytes that don't fit in the first
window reservation fall through to the regular `_write_data_frames_h2_server!`
batching path (which re-acquires the lock per batch).
"""
function _write_h2_headers_and_first_batch!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    response_status::Int,
    response_headers::Headers,
    body::AbstractVector{UInt8},
    body_end_stream::Bool,
    max_frame_size::Int,
    max_header_list_size::Int,
    write_deadline_ns::Int64,
)::Nothing
    write_deadline_ns > 0 && _set_write_deadline!(conn, write_deadline_ns)
    total_len = length(body)
    # Per-frame cap — the smaller of our local cap and the peer's setting.
    peer_max = lock(send_state.state_lock) do
        send_state.peer_max_send_frame_size
    end
    server_max = min(Int(_H2_SERVER_MAX_DATA_FRAME_SIZE), peer_max)
    # Reserve send window for as much of the body as we can take immediately.
    first_chunk = total_len == 0 ? 0 : _reserve_h2_send_window!(send_state, stream_id, total_len, write_deadline_ns)
    # Acquire write_lock and emit HEADERS + DATA batch atomically.
    lock(write_lock)
    try
        # 1. HEADERS frame bytes (encoder state advances under the lock).
        headers_bytes = _encode_h2_headers_frame_bytes_locked!(
            send_state, stream_id, response_status, response_headers,
            total_len == 0 ? body_end_stream : false,
            max_frame_size, max_header_list_size,
        )
        if total_len == 0
            _write_all_h2_server!(conn, headers_bytes)
            return nothing
        end
        # 2. Vectored write of [HEADERS][DATA-hdr_1][body_slice_1]…
        # We build a single iovec list that points directly into the
        # caller's body memory — no per-batch body copy. Only the small
        # 9-byte DATA frame headers are freshly allocated.
        _writev_headers_and_batch!(conn, stream_id, body, headers_bytes,
                                   1, first_chunk, server_max, body_end_stream, total_len)
        offset = 1 + first_chunk
        # 3. More body? Same idea but no headers prelude.
        while offset <= total_len
            extra = _reserve_h2_send_window!(send_state, stream_id, total_len - offset + 1, write_deadline_ns)
            extra <= 0 && break
            _writev_headers_and_batch!(conn, stream_id, body, nothing,
                                       offset, extra, server_max, body_end_stream, total_len)
            offset += extra
        end
    finally
        unlock(write_lock)
    end
    return nothing
end

@inline function _writev_headers_and_batch!(
    conn::Union{TCP.Conn,TLS.Conn},
    stream_id::UInt32,
    body::AbstractVector{UInt8},
    headers_bytes::Union{Nothing,Vector{UInt8}},
    body_offset::Int,
    body_len::Int,
    server_max::Int,
    body_end_stream::Bool,
    total_len::Int,
)::Nothing
    # Emit the optional HEADERS frame and the DATA frames for this batch,
    # writing each frame's payload directly from `body` (no body copy). See
    # `_write_h2_batch_via_single_buffer!` for the per-response-allocation
    # rationale. A future `Reseau.TCP.writev` (sendmsg/iovec) could coalesce the
    # frame headers and payload slices into a single vectored syscall.
    _write_h2_batch_via_single_buffer!(conn, stream_id, body,
        headers_bytes, body_offset, body_len, server_max, body_end_stream, total_len)
    return nothing
end

@inline function _write_h2_batch_via_single_buffer!(
    conn::Union{TCP.Conn,TLS.Conn},
    stream_id::UInt32,
    body::AbstractVector{UInt8},
    headers_bytes::Union{Nothing,Vector{UInt8}},
    body_offset::Int,
    body_len::Int,
    server_max::Int,
    body_end_stream::Bool,
    total_len::Int,
)::Nothing
    # Caller holds write_lock. Emit the optional HEADERS frame, then each DATA
    # frame as a 9-byte header (reused scratch) followed by its payload slice
    # taken DIRECTLY from `body` (zero-copy: a unit-range view of a Vector{UInt8}
    # or Base.CodeUnits is a stride-1 StridedVector, so `write(conn, ::view)`
    # passes the underlying pointer straight to the socket).
    #
    # The previous implementation built one body-sized buffer (HEADERS + DATA
    # headers + a full copy of the body) and issued a single write. That copy is
    # the dominant per-response allocation on the buffered-response fast path;
    # under HTTP/2's per-stream `@spawn` the freed buffers are retained by the
    # glibc malloc arenas and inflate process RSS in proportion to response body
    # size (HTTP/2-only — the HTTP/1 path writes the body in place). Writing the
    # body in place here removes that allocation; only the small HEADERS-frame
    # bytes and the reused 9-byte DATA header remain.
    headers_bytes === nothing || _write_all_h2_server!(conn, headers_bytes)
    header = Vector{UInt8}(undef, 9)
    rem = body_len
    cur = body_offset
    while rem > 0
        payload = min(rem, server_max, total_len - cur + 1)
        final_chunk = (cur + payload - 1) == total_len
        _stamp_h2_data_header!(header, 1, payload, body_end_stream && final_chunk, stream_id)
        _write_all_h2_server!(conn, header)
        _write_h2_payload_slice!(conn, body, cur, payload)
        cur += payload
        rem -= payload
    end
    return nothing
end

function _write_h2_buffered_stream_response!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    request::Request,
    stream::Stream,
    write_deadline_ns::Int64=Int64(0),
)::Nothing
    response = stream.response::Response
    response.request = request
    allows_body = _h2_response_allows_body(request, response)
    body_bytes = take!(stream.request_buffer)
    if !allows_body
        empty!(body_bytes)
    elseif response.content_length >= 0 && length(body_bytes) != response.content_length
        throw(ProtocolError("response body bytes did not match Content-Length"))
    end
    has_body = !isempty(body_bytes)
    has_trailers = !isempty(response.trailers)
    end_stream = !has_body && !has_trailers
    _write_h2_response_headers!(conn, write_lock, send_state, stream_id, response.status, response.headers, end_stream, write_deadline_ns)
    has_body && _write_data_frames_h2_server!(conn, write_lock, send_state, stream_id, body_bytes; end_stream=!has_trailers, write_deadline_ns=write_deadline_ns)
    has_trailers && _write_h2_trailers!(conn, write_lock, send_state, stream_id, response.trailers, write_deadline_ns)
    return nothing
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
                if @atomic :acquire stream.response_started
                    @try_ignore begin
                        _write_frame_h2_server_threadsafe!(write_lock, conn, RSTStreamFrame(stream_id, UInt32(0x2)))
                    end
                else
                    status = _server_error_status(err::Exception)
                    stream.request_buffer = IOBuffer()
                    stream.response = Response(
                        status === nothing ? 500 : status::Int;
                        proto_major=2,
                        proto_minor=0,
                        request=request,
                    )
                    @atomic :release stream.response_started = false
                    @atomic :release stream.write_closed = false
                    @atomic :release stream.read_closed = false
                    closewrite(stream)
                end
                closeread(stream)
            end
        else
            handler_request = request
            response = try
                handler_request = _buffer_server_request(request)
                server.handler(handler_request)
            catch err
                status = _server_error_status(err::Exception)
                _write_h2_response!(
                    conn,
                    write_lock,
                    send_state,
                    stream_id,
                    request,
                    Response(
                        status === nothing ? 500 : status::Int;
                        proto_major=2,
                        proto_minor=0,
                        request=request,
                    ),
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
                    Response(500; proto_major=2, proto_minor=0, request=request),
                    _server_write_deadline_ns(server),
                )
                return nothing
            end
            response_obj = response::Response
            _write_h2_response!(conn, write_lock, send_state, stream_id, handler_request, response_obj, _server_write_deadline_ns(server))
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
            rethrow(err)
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
    Threads.@spawn _handle_h2_stream!(server, tracked, conn, write_lock, send_state, states_lock, states, state.stream_id, state, decoded_headers::Vector{HeaderField})
    return nothing
end

function _try_write_h2_goaway!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    last_stream_id::UInt32,
    error_code::UInt32,
)::Nothing
    @try_ignore begin
        _write_frame_h2_server_threadsafe!(write_lock, conn, GoAwayFrame(last_stream_id, error_code, UInt8[]))
    end
    return nothing
end

function _request_h2_conn_shutdown!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    control::_H2ServerConnControl,
)::Nothing
    @atomic :release control.shutdown_requested = true
    (@atomic :acquire control.goaway_sent) && return nothing
    last_stream_id = @atomic :acquire control.graceful_last_stream_id
    _try_write_h2_goaway!(conn, write_lock, last_stream_id, UInt32(0))
    @atomic :release control.goaway_sent = true
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
    send_state = _H2SendWindowState()
    conn_control = _H2ServerConnControl()
    states = Dict{UInt32,_H2ServerStreamState}()
    continuation_stream = UInt32(0)
    max_stream_id = UInt32(0)
    peer_goaway_last_stream_id = typemax(UInt32)
    close_kind = _H2_CONN_CLOSE_CLEAN
    try
        preface = _read_exact_h2_server!(reader_source, length(_H2_PREFACE))
        preface == _H2_PREFACE || throw(ProtocolError("invalid h2 client preface"))
        reader = _ConnReader(reader_source)
        client_settings = read_frame!(reader)
        client_settings isa SettingsFrame || throw(ProtocolError("expected initial h2 SETTINGS frame"))
        (client_settings::SettingsFrame).ack && throw(ProtocolError("initial h2 SETTINGS frame must not be ACK"))
        _apply_h2_peer_settings!(send_state, write_lock, (client_settings::SettingsFrame).settings)
        _write_frame_h2_server_threadsafe!(write_lock, conn, SettingsFrame(false, Pair{UInt16,UInt32}[]), _server_write_deadline_ns(server))
        _write_frame_h2_server_threadsafe!(write_lock, conn, SettingsFrame(true, Pair{UInt16,UInt32}[]), _server_write_deadline_ns(server))
        _clear_deadlines!(conn)
        _set_conn_shutdown_hook!(tracked, () -> _request_h2_conn_shutdown!(conn, write_lock, conn_control))
        _set_conn_state!(tracked, _ConnState.IDLE)
        while true
            _server_shutting_down(server) && return nothing
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
                _set_h2_server_stream_cancelled!(state, _H2_SERVER_STREAM_RESET, true, true, true)
                _unregister_h2_send_window!(send_state, rst.stream_id)
                _maybe_cleanup_h2_server_state!(tracked, states_lock, states, state, send_state)
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
                if (@atomic :acquire conn_control.shutdown_requested) && hf.stream_id > (@atomic :acquire conn_control.graceful_last_stream_id)
                    throw(ProtocolError("client opened stream after server GOAWAY"))
                end
                lock(states_lock)
                state = try
                    if hf.stream_id < max_stream_id && !haskey(states, hf.stream_id)
                        throw(ProtocolError("HEADERS stream id must increase monotonically"))
                    end
                    if hf.stream_id > max_stream_id
                        max_stream_id = hf.stream_id
                        @atomic :release conn_control.graceful_last_stream_id = max_stream_id
                    end
                    if haskey(states, hf.stream_id)
                        states[hf.stream_id]
                    else
                        created = _H2ServerStreamState(hf.stream_id)
                        states[hf.stream_id] = created
                        _register_h2_send_window!(send_state, hf.stream_id)
                        created
                    end
                finally
                    unlock(states_lock)
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
                    remaining = max_header_block_bytes - length(state.header_block)
                    remaining >= 0 && length(hf.header_block_fragment) <= remaining || throw(ProtocolError("HTTP/2 request header block exceeded maximum size", _PROTOCOL_ERROR_HEADERS_TOO_LARGE))
                    append!(state.header_block, hf.header_block_fragment)
                    if hf.end_headers
                        decoded = decode_header_block(decoder, state.header_block)
                        empty!(state.header_block)
                        if initial_headers
                            state.decoded_headers = decoded
                            state.headers_complete = true
                        else
                            trailers = _decode_h2_trailer_headers(decoded)
                            for key in header_keys(trailers)
                                values = headers(trailers, key)
                                for value in values
                                    appendheader(state.trailers, key, value)
                                end
                            end
                            state.trailers_complete = true
                        end
                    end
                    hf.end_headers || (continuation_stream = hf.stream_id)
                    if hf.end_stream
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
                lock(state.lock)
                try
                    initial_headers = !state.headers_complete
                    remaining = max_header_block_bytes - length(state.header_block)
                    remaining >= 0 && length(cf.header_block_fragment) <= remaining || throw(ProtocolError("HTTP/2 request header block exceeded maximum size", _PROTOCOL_ERROR_HEADERS_TOO_LARGE))
                    append!(state.header_block, cf.header_block_fragment)
                    if cf.end_headers
                        decoded = decode_header_block(decoder, state.header_block)
                        empty!(state.header_block)
                        if initial_headers
                            state.decoded_headers = decoded
                            state.headers_complete = true
                        else
                            trailers = _decode_h2_trailer_headers(decoded)
                            for key in header_keys(trailers)
                                values = headers(trailers, key)
                                for value in values
                                    appendheader(state.trailers, key, value)
                                end
                            end
                            state.trailers_complete = true
                        end
                        continuation_stream = UInt32(0)
                    else
                        continuation_stream = cf.stream_id
                    end
                    notify(state.condition)
                finally
                    unlock(state.lock)
                end
                cf.end_headers && !state.trailers_complete && _dispatch_h2_stream!(server, tracked, conn, write_lock, send_state, states_lock, states, state)
                continue
            end
            if frame isa DataFrame
                df = frame::DataFrame
                df.stream_id == UInt32(0) && throw(ProtocolError("DATA stream id must be non-zero"))
                iseven(df.stream_id) && throw(ProtocolError("DATA stream id must be odd for client-initiated streams"))
                lock(states_lock)
                state = try
                    get(() -> throw(ProtocolError("DATA frame received before HEADERS")), states, df.stream_id)
                finally
                    unlock(states_lock)
                end
                stream_error = false
                lock(state.lock)
                try
                    state.headers_complete || throw(ProtocolError("DATA frame received before END_HEADERS"))
                    if state.stream_done || state.trailers_complete
                        stream_error = true
                    elseif state.aborted
                        df.end_stream && (state.stream_done = true)
                        notify(state.condition)
                    else
                        new_received = state.received_body_bytes + Int64(length(df.data))
                        if state.declared_body_bytes >= 0 && new_received > state.declared_body_bytes
                            stream_error = true
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
                if stream_error
                    _fail_h2_server_stream!(server, tracked, conn, write_lock, states_lock, states, send_state, state, _H2_ERROR_PROTOCOL)
                elseif state.aborted
                    _send_h2_server_window_updates!(conn, write_lock, df.stream_id, length(df.data), false)
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
        close_kind == _H2_CONN_CLOSE_PROTOCOL && _try_write_h2_goaway!(conn, write_lock, max_stream_id, UInt32(0x1))
        _fail_h2_send_window_state!(send_state)
        _fail_h2_server_streams!(states_lock, states, send_state)
        _set_conn_shutdown_hook!(tracked, nothing)
        _finalize_server_conn!(server, tracked)
    end
    return nothing
end
