# HTTP/2 client connection and roundtrip implementation.
using Reseau.TCP
using Reseau.HostResolvers
using Reseau.TLS
using Reseau.IOPoll

const _H2_PREFACE = collect(codeunits("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"))
const _H2_DEFAULT_MAX_HEADER_LIST_SIZE = 10 * 1024 * 1024
const _H2_DEFAULT_MAX_HEADER_BLOCK_BYTES = 2 * _H2_DEFAULT_MAX_HEADER_LIST_SIZE
const _TLS_CONFIG_POSITIONAL_TYPES = Tuple{
    Union{Nothing,String},
    Bool,
    Bool,
    TLS.ClientAuthMode.T,
    Union{Nothing,String},
    Union{Nothing,String},
    Union{Nothing,String},
    Union{Nothing,String},
    Vector{String},
    Vector{UInt16},
    Int64,
    Union{Nothing,UInt16},
    Union{Nothing,UInt16},
    Bool,
    Int,
}
const _TLS_CONFIG_POSITIONAL_AVAILABLE = hasmethod(TLS.Config, _TLS_CONFIG_POSITIONAL_TYPES)

"""
    H2NegotiationError

Raised when the connection transport succeeds but cannot be used for HTTP/2,
most notably when TLS ALPN negotiates a protocol other than `h2`.
"""
struct H2NegotiationError <: HTTPError
    message::String
end

function Base.showerror(io::IO, err::H2NegotiationError)
    print(io, err.message)
    return nothing
end

"""
    H2GoAwayError

Raised when an HTTP/2 connection can no longer accept a stream because the peer
sent `GOAWAY`.
"""
struct H2GoAwayError <: HTTPError
    message::String
    last_stream_id::UInt32
end

function Base.showerror(io::IO, err::H2GoAwayError)
    print(io, err.message)
    return nothing
end

@inline function _tls_config_from_parts(
    server_name::Union{Nothing,String},
    verify_peer::Bool,
    verify_hostname::Bool,
    client_auth::TLS.ClientAuthMode.T,
    cert_file::Union{Nothing,String},
    key_file::Union{Nothing,String},
    ca_file::Union{Nothing,String},
    client_ca_file::Union{Nothing,String},
    alpn_protocols::Vector{String},
    curve_preferences::Vector{UInt16},
    handshake_timeout_ns::Int64,
    min_version::Union{Nothing,UInt16},
    max_version::Union{Nothing,UInt16},
    session_tickets_disabled::Bool,
    session_cache_capacity::Int=64,
)::TLS.Config
    if _TLS_CONFIG_POSITIONAL_AVAILABLE
        return TLS.Config(
            server_name,
            verify_peer,
            verify_hostname,
            client_auth,
            cert_file,
            key_file,
            ca_file,
            client_ca_file,
            alpn_protocols,
            curve_preferences,
            handshake_timeout_ns,
            min_version,
            max_version,
            session_tickets_disabled,
            session_cache_capacity,
        )
    end
    return TLS.Config(
        server_name=server_name,
        verify_peer=verify_peer,
        verify_hostname=verify_hostname,
        client_auth=client_auth,
        cert_file=cert_file,
        key_file=key_file,
        ca_file=ca_file,
        client_ca_file=client_ca_file,
        alpn_protocols=alpn_protocols,
        curve_preferences=curve_preferences,
        handshake_timeout_ns=handshake_timeout_ns,
        min_version=min_version,
        max_version=max_version,
        session_tickets_disabled=session_tickets_disabled,
        session_cache_capacity=session_cache_capacity,
    )
end

"""
    H2StreamState

Per-stream response assembly state owned by the shared HTTP/2 client read loop.

Each active stream has exactly one `H2StreamState`. The read loop appends
header fragments and DATA payloads here, while the response body reader drains
them and returns HTTP/2 flow-control credits back to the peer.
"""
mutable struct H2StreamState
    stream_id::UInt32
    lock::ReentrantLock
    condition::Threads.Condition
    header_block::Vector{UInt8}
    decoded_headers::Union{Nothing,Vector{HeaderField}}
    pending_trailers::Headers
    response_trailers::Union{Nothing,Headers}
    body::Vector{UInt8}
    body_read_index::Int
    max_buffered_bytes::Int
    headers_complete::Bool
    stream_done::Bool
    trailers_published::Bool
    conn_errored::Bool
    stream_error::Union{Nothing,Exception}
end

function H2StreamState(stream_id::UInt32)
    lock = ReentrantLock()
    return H2StreamState(
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
        false,
        false,
        false,
        false,
        nothing,
    )
end

"""
    H2Connection

Stateful HTTP/2 client connection with HPACK codec state, stream registry, and
connection-level flow-control bookkeeping.

One `H2Connection` multiplexes many logical requests over a single TCP or TLS
transport. A dedicated background read task owns frame intake and distributes
completed data to per-stream consumers.
"""
mutable struct H2Connection
    address::String
    secure::Bool
    tcp::TCP.Conn
    tls::Union{Nothing,TLS.Conn}
    reader::_ConnReader
    peer_max_send_frame_size::Int
    encoder::Encoder
    decoder::Decoder
    next_stream_id::UInt32
    state_lock::ReentrantLock
    write_lock::ReentrantLock
    streams::Dict{UInt32,H2StreamState}
    stream_condition::Threads.Condition
    read_task::Union{Nothing,Task}
    read_loop_condition::Threads.Condition
    conn_error::Union{Nothing,ProtocolError}
    window_condition::Threads.Condition
    conn_send_window::Int64
    initial_stream_send_window::Int64
    stream_send_window::Dict{UInt32,Int64}
    peer_max_concurrent_streams::Int
    peer_max_header_list_size::Int
    peer_goaway_last_stream_id::UInt32
    accepting_new_streams::Bool
    max_header_block_bytes::Int
    @atomic closed::Bool
end

"""
    H2Body

Streaming HTTP/2 response body backed by per-stream read-loop buffers.

Reading from `H2Body` drains the buffered DATA bytes accumulated by the read
loop, and each successful read sends WINDOW_UPDATE frames so the peer can keep
transmitting.
"""
mutable struct H2Body <: AbstractBody
    conn::H2Connection
    stream_id::UInt32
    state::H2StreamState
    request::Request
    trailers::Headers
    expected_content_length::Int64
    bytes_read::Int64
    @atomic closed::Bool
end

@inline function _h2_stream(conn::H2Connection)
    if conn.secure
        conn.tls === nothing && throw(ProtocolError("HTTP/2 connection missing TLS stream"))
        return conn.tls::TLS.Conn
    end
    return conn.tcp
end

function _write_all_h2!(conn::H2Connection, bytes::Vector{UInt8})
    stream = _h2_stream(conn)
    total = 0
    while total < length(bytes)
        n = write(stream, bytes[(total+1):end])
        n > 0 || throw(ProtocolError("HTTP/2 write made no progress"))
        total += n
    end
    return nothing
end

function _set_h2_write_deadline!(conn::H2Connection, deadline_ns::Int64)::Nothing
    if conn.secure
        conn.tls === nothing || TLS.set_write_deadline!(conn.tls::TLS.Conn, deadline_ns)
    else
        TCP.set_write_deadline!(conn.tcp, deadline_ns)
    end
    return nothing
end

function _write_frame_h2!(conn::H2Connection, frame::AbstractFrame, write_deadline_ns::Int64=Int64(0))
    io = IOBuffer()
    write_frame!(io, frame)
    _set_h2_write_deadline!(conn, write_deadline_ns)
    _write_all_h2!(conn, take!(io))
    return nothing
end

function _write_frame_h2_threadsafe!(conn::H2Connection, frame::AbstractFrame, write_deadline_ns::Int64=Int64(0))
    lock(conn.write_lock)
    try
        _write_frame_h2!(conn, frame, write_deadline_ns)
    finally
        unlock(conn.write_lock)
    end
    return nothing
end

@inline function _h2_max_data_frame_size(conn::H2Connection)::Int
    return conn.peer_max_send_frame_size
end

@inline function _h2_send_window_ready_locked(conn::H2Connection, stream_id::UInt32)::Bool
    (@atomic :acquire conn.closed) && return true
    conn.conn_error !== nothing && return true
    stream_window = get(() -> Int64(0), conn.stream_send_window, stream_id)
    return stream_window > 0 && conn.conn_send_window > 0
end

function _wait_h2_send_window_locked!(conn::H2Connection, stream_id::UInt32, deadline_ns::Int64)::Nothing
    if deadline_ns == 0
        wait(conn.window_condition)
        return nothing
    end
    remaining_ns = deadline_ns - Int64(time_ns())
    remaining_ns <= 0 && throw(IOPoll.DeadlineExceededError())
    unlock(conn.state_lock)
    try
        status = IOPoll.timedwait(() -> begin
            lock(conn.state_lock)
            try
                return _h2_send_window_ready_locked(conn, stream_id)
            finally
                unlock(conn.state_lock)
            end
        end, remaining_ns / 1.0e9; pollint=0.001)
        status == :timed_out && throw(IOPoll.DeadlineExceededError())
    finally
        lock(conn.state_lock)
    end
    return nothing
end

function _reserve_send_window!(conn::H2Connection, stream_id::UInt32, wanted::Int, deadline_ns::Int64)::Int
    wanted > 0 || throw(ArgumentError("wanted send window must be > 0"))
    lock(conn.state_lock)
    try
        while true
            (@atomic :acquire conn.closed) && throw(ProtocolError("HTTP/2 connection is closed"))
            conn.conn_error === nothing || throw(conn.conn_error::ProtocolError)
            stream_window = get(() -> Int64(0), conn.stream_send_window, stream_id)
            if stream_window <= 0 || conn.conn_send_window <= 0
                # Both the connection-level and per-stream windows must allow
                # progress. The read loop replenishes these via WINDOW_UPDATE.
                _wait_h2_send_window_locked!(conn, stream_id, deadline_ns)
                continue
            end
            allowed = min(Int64(wanted), conn.conn_send_window, stream_window, Int64(_h2_max_data_frame_size(conn)))
            conn.conn_send_window -= allowed
            conn.stream_send_window[stream_id] = stream_window - allowed
            return Int(allowed)
        end
    finally
        unlock(conn.state_lock)
    end
end

function _write_data_frames_h2!(conn::H2Connection, stream_id::UInt32, request::Request, data::Vector{UInt8}, end_stream::Bool)
    isempty(data) && return nothing
    offset = 1
    total_len = length(data)
    while offset <= total_len
        remaining = total_len - offset + 1
        write_deadline_ns = _request_write_deadline_ns(request)
        chunk_len = _reserve_send_window!(conn, stream_id, remaining, write_deadline_ns)
        chunk = Vector{UInt8}(undef, chunk_len)
        copyto!(chunk, 1, data, offset, chunk_len)
        final_chunk = (offset + chunk_len - 1) == total_len
        _write_frame_h2_threadsafe!(conn, DataFrame(stream_id, end_stream && final_chunk, chunk), write_deadline_ns)
        offset += chunk_len
    end
    return nothing
end

function _apply_peer_settings!(conn::H2Connection, settings::Vector{Pair{UInt16,UInt32}})
    header_table_size = nothing
    lock(conn.state_lock)
    try
        for setting in settings
            id = setting.first
            value = setting.second
            if id == UInt16(0x1)
                header_table_size = Int(value)
            elseif id == UInt16(0x2)
                value == UInt32(0) || throw(ProtocolError("HTTP/2 servers must not enable push"))
            elseif id == UInt16(0x3)
                conn.peer_max_concurrent_streams = Int(value)
            elseif id == UInt16(0x4)
                value > UInt32(0x7fff_ffff) && throw(ProtocolError("HTTP/2 SETTINGS_INITIAL_WINDOW_SIZE too large"))
                new_window = Int64(value)
                delta = new_window - conn.initial_stream_send_window
                conn.initial_stream_send_window = new_window
                for stream_id in keys(conn.stream_send_window)
                    conn.stream_send_window[stream_id] = conn.stream_send_window[stream_id] + delta
                end
            elseif id == UInt16(0x5)
                value < UInt32(16_384) && throw(ProtocolError("HTTP/2 SETTINGS_MAX_FRAME_SIZE too small"))
                value > UInt32(16_777_215) && throw(ProtocolError("HTTP/2 SETTINGS_MAX_FRAME_SIZE too large"))
                conn.peer_max_send_frame_size = Int(value)
            elseif id == UInt16(0x6)
                conn.peer_max_header_list_size = Int(value)
            end
        end
        notify(conn.window_condition; all=true)
        notify(conn.stream_condition; all=true)
    finally
        unlock(conn.state_lock)
    end
    if header_table_size !== nothing
        size = header_table_size::Int
        lock(conn.write_lock)
        try
            set_max_dynamic_table_size_limit!(conn.encoder, size)
            set_max_dynamic_table_size!(conn.encoder, size)
        finally
            unlock(conn.write_lock)
        end
    end
    return nothing
end

function _set_stream_error!(state::H2StreamState, err::Exception)
    lock(state.lock)
    try
        state.stream_error === nothing && (state.stream_error = err)
        state.stream_done = true
        notify(state.condition)
    finally
        unlock(state.lock)
    end
    return nothing
end

@inline function _stream_failed(state::H2StreamState)::Bool
    return state.conn_errored || state.stream_error !== nothing
end

@inline function _stream_conn_error(conn::H2Connection)::ProtocolError
    err = conn.conn_error
    return err === nothing ? ProtocolError("HTTP/2 connection failed") : (err::ProtocolError)
end

function _all_streams_done(conn::H2Connection)::Bool
    lock(conn.state_lock)
    try
        for state in values(conn.streams)
            state.stream_done || return false
        end
        return true
    finally
        unlock(conn.state_lock)
    end
end

@inline function _throw_stream_error(conn::H2Connection, state::H2StreamState)::Nothing
    err = state.stream_error
    err === nothing || throw(err::Exception)
    state.conn_errored && throw(_stream_conn_error(conn))
    return nothing
end

function _set_stream_conn_errored!(state::H2StreamState)
    lock(state.lock)
    try
        state.conn_errored = true
        notify(state.condition)
    finally
        unlock(state.lock)
    end
    return nothing
end

function _stream_state(conn::H2Connection, stream_id::UInt32)::Union{Nothing,H2StreamState}
    lock(conn.state_lock)
    try
        return get(() -> nothing, conn.streams, stream_id)
    finally
        unlock(conn.state_lock)
    end
end

function _h2_conn_available(conn::H2Connection)::Bool
    lock(conn.state_lock)
    try
        (@atomic :acquire conn.closed) && return false
        conn.conn_error === nothing || return false
        conn.accepting_new_streams || return false
        conn.next_stream_id <= conn.peer_goaway_last_stream_id || return false
        return length(conn.streams) < conn.peer_max_concurrent_streams
    finally
        unlock(conn.state_lock)
    end
end

function _h2_conn_reusable(conn::H2Connection)::Bool
    lock(conn.state_lock)
    try
        (@atomic :acquire conn.closed) && return false
        conn.conn_error === nothing || return false
        return conn.accepting_new_streams && conn.next_stream_id <= conn.peer_goaway_last_stream_id
    finally
        unlock(conn.state_lock)
    end
end

function _register_stream!(conn::H2Connection)::H2StreamState
    lock(conn.state_lock)
    try
        while true
            (@atomic :acquire conn.closed) && throw(ProtocolError("HTTP/2 connection is closed"))
            conn.conn_error === nothing || throw(conn.conn_error::ProtocolError)
            if !conn.accepting_new_streams || conn.next_stream_id > conn.peer_goaway_last_stream_id
                throw(H2GoAwayError("HTTP/2 connection is draining after GOAWAY", conn.peer_goaway_last_stream_id))
            end
            if length(conn.streams) >= conn.peer_max_concurrent_streams
                wait(conn.stream_condition)
                continue
            end
            stream_id = conn.next_stream_id
            conn.next_stream_id += UInt32(2)
            state = H2StreamState(stream_id)
            conn.streams[stream_id] = state
            conn.stream_send_window[stream_id] = conn.initial_stream_send_window
            return state
        end
    finally
        unlock(conn.state_lock)
    end
end

function _unregister_stream!(conn::H2Connection, stream_id::UInt32)
    lock(conn.state_lock)
    try
        pop!(conn.streams, stream_id, nothing)
        pop!(conn.stream_send_window, stream_id, nothing)
        notify(conn.stream_condition; all=true)
    finally
        unlock(conn.state_lock)
    end
    return nothing
end

function _close_h2_transports!(conn::H2Connection)
    if conn.secure
        if conn.tls !== nothing
            @try_ignore TLS.close(conn.tls::TLS.Conn)
        end
    end
    @try_ignore TCP.close(conn.tcp)
    return nothing
end

function _fail_h2_connection!(conn::H2Connection, err::ProtocolError)
    stream_states = H2StreamState[]
    lock(conn.state_lock)
    try
        conn.conn_error === nothing && (conn.conn_error = err)
        @atomic :release conn.closed = true
        notify(conn.window_condition; all=true)
        notify(conn.stream_condition; all=true)
        append!(stream_states, values(conn.streams))
    finally
        unlock(conn.state_lock)
    end
    for state in stream_states
        _set_stream_conn_errored!(state)
    end
    _close_h2_transports!(conn)
    return nothing
end

function _read_settings_until_ready!(conn::H2Connection)
    frame = read_frame!(conn.reader)
    frame isa SettingsFrame || throw(ProtocolError("HTTP/2 peer must send SETTINGS before other frames"))
    settings = frame::SettingsFrame
    settings.ack && throw(ProtocolError("initial HTTP/2 SETTINGS frame must not be ACK"))
    _apply_peer_settings!(conn, settings.settings)
    _write_frame_h2_threadsafe!(conn, SettingsFrame(true, Pair{UInt16,UInt32}[]))
    return nothing
end

function _handle_stream_header_fragment!(
    conn::H2Connection,
    state::H2StreamState,
    fragment::Vector{UInt8},
    end_headers::Bool,
    end_stream::Bool,
)
    lock(state.lock)
    try
        remaining = conn.max_header_block_bytes - length(state.header_block)
        remaining >= 0 && length(fragment) <= remaining || throw(ProtocolError("HTTP/2 response header block exceeded maximum size"))
        append!(state.header_block, fragment)
        if end_headers
            decoded = decode_header_block(conn.decoder, state.header_block)
            empty!(state.header_block)
            if !state.headers_complete
                state.decoded_headers = decoded
                state.headers_complete = true
            else
                end_stream || throw(ProtocolError("HTTP/2 response trailers must end the stream"))
                trailers = _decode_h2_trailer_headers(decoded)
                for key in header_keys(trailers)
                    values = headers(trailers, key)
                    for value in values
                        appendheader(state.pending_trailers, key, value)
                    end
                end
            end
        end
        if end_stream
            state.stream_done = true
        end
        notify(state.condition)
    finally
        unlock(state.lock)
    end
    return nothing
end

function _handle_stream_data!(state::H2StreamState, frame::DataFrame)
    lock(state.lock)
    try
        while ((length(state.body) - state.body_read_index) + 1) >= state.max_buffered_bytes && !_stream_failed(state) && !state.stream_done
            wait(state.condition)
        end
        _stream_failed(state) && return nothing
        append!(state.body, frame.data)
        if frame.end_stream
            state.stream_done = true
            notify(state.condition)
        else
            notify(state.condition)
        end
    finally
        unlock(state.lock)
    end
    return nothing
end

function _send_window_updates!(conn::H2Connection, stream_id::UInt32, nbytes::Int)
    nbytes <= 0 && return nothing
    increment = UInt32(nbytes)
    try
        _write_frame_h2_threadsafe!(conn, WindowUpdateFrame(UInt32(0), increment))
        _write_frame_h2_threadsafe!(conn, WindowUpdateFrame(stream_id, increment))
    catch err
        if err isa EOFError || err isa IOPoll.NetClosingError || err isa SystemError
            return nothing
        end
        rethrow(err)
    end
    return nothing
end

function _process_incoming_frame!(conn::H2Connection, frame::AbstractFrame)
    # Frame-local validation already happened in `read_frame!`; this function is
    # responsible for connection- and stream-level state transitions.
    if frame isa SettingsFrame
        settings = frame::SettingsFrame
        if !settings.ack
            _apply_peer_settings!(conn, settings.settings)
            _write_frame_h2_threadsafe!(conn, SettingsFrame(true, Pair{UInt16,UInt32}[]))
        end
        return nothing
    elseif frame isa PingFrame
        ping = frame::PingFrame
        ping.ack || _write_frame_h2_threadsafe!(conn, PingFrame(true, ping.opaque_data))
        return nothing
    elseif frame isa GoAwayFrame
        goaway = frame::GoAwayFrame
        goaway.error_code == UInt32(0) || throw(ProtocolError("HTTP/2 peer sent GOAWAY"))
        to_fail = Pair{UInt32,H2StreamState}[]
        lock(conn.state_lock)
        try
            conn.accepting_new_streams = false
            conn.peer_goaway_last_stream_id = min(conn.peer_goaway_last_stream_id, goaway.last_stream_id)
            for (stream_id, state) in conn.streams
                if stream_id > conn.peer_goaway_last_stream_id
                    push!(to_fail, stream_id => state)
                end
            end
            for failed in to_fail
                pop!(conn.streams, failed.first, nothing)
                pop!(conn.stream_send_window, failed.first, nothing)
            end
            notify(conn.stream_condition; all=true)
            notify(conn.window_condition; all=true)
        finally
            unlock(conn.state_lock)
        end
        for failed in to_fail
            _set_stream_error!(failed.second, H2GoAwayError("HTTP/2 stream rejected by GOAWAY", goaway.last_stream_id))
        end
        return nothing
    elseif frame isa RSTStreamFrame
        rst = frame::RSTStreamFrame
        state = _stream_state(conn, rst.stream_id)
        state === nothing && return nothing
        _set_stream_error!(state::H2StreamState, ProtocolError("HTTP/2 stream reset by peer"))
        return nothing
    elseif frame isa WindowUpdateFrame
        update = frame::WindowUpdateFrame
        increment = Int64(update.window_size_increment)
        lock(conn.state_lock)
        try
            if update.stream_id == UInt32(0)
                conn.conn_send_window += increment
            else
                current = get(() -> conn.initial_stream_send_window, conn.stream_send_window, update.stream_id)
                conn.stream_send_window[update.stream_id] = current + increment
            end
            notify(conn.window_condition; all=true)
        finally
            unlock(conn.state_lock)
        end
        return nothing
    elseif frame isa HeadersFrame
        headers = frame::HeadersFrame
        state = _stream_state(conn, headers.stream_id)
        state === nothing && return nothing
        _handle_stream_header_fragment!(conn, state::H2StreamState, headers.header_block_fragment, headers.end_headers, headers.end_stream)
        return nothing
    elseif frame isa PushPromiseFrame
        throw(ProtocolError("HTTP/2 server push is unsupported"))
    elseif frame isa ContinuationFrame
        cont = frame::ContinuationFrame
        state = _stream_state(conn, cont.stream_id)
        state === nothing && return nothing
        _handle_stream_header_fragment!(conn, state::H2StreamState, cont.header_block_fragment, cont.end_headers, false)
        return nothing
    elseif frame isa DataFrame
        data = frame::DataFrame
        state = _stream_state(conn, data.stream_id)
        state === nothing && return nothing
        _handle_stream_data!(state::H2StreamState, data)
        return nothing
    end
    return nothing
end

function _run_h2_read_loop!(conn::H2Connection)
    try
        while true
            (@atomic :acquire conn.closed) && return nothing
            frame = read_frame!(conn.reader)
            _process_incoming_frame!(conn, frame)
        end
    catch err
        (@atomic :acquire conn.closed) && return nothing
        if _all_streams_done(conn)
            @atomic :release conn.closed = true
            _close_h2_transports!(conn)
            return nothing
        end
        _fail_h2_connection!(conn, ProtocolError("HTTP/2 read loop failed", err::Exception))
        return nothing
    finally
        lock(conn.state_lock)
        try
            conn.read_task = nothing
            notify(conn.read_loop_condition; all=true)
        finally
            unlock(conn.state_lock)
        end
    end
end

function _start_h2_read_loop!(conn::H2Connection)
    lock(conn.state_lock)
    try
        conn.read_task !== nothing && return nothing
        conn.read_task = Threads.@spawn _run_h2_read_loop!(conn)
    finally
        unlock(conn.state_lock)
    end
    return nothing
end

function _wait_h2_read_loop_exit!(conn::H2Connection, read_task::Task)
    lock(conn.state_lock)
    try
        while conn.read_task !== nothing && (conn.read_task::Task) === read_task
            wait(conn.read_loop_condition)
        end
    finally
        unlock(conn.state_lock)
    end
    return nothing
end

function _verify_h2_alpn!(conn::H2Connection)
    conn.secure || return nothing
    tls_conn = conn.tls
    tls_conn === nothing && throw(ProtocolError("HTTP/2 connection missing TLS stream"))
    state = TLS.connection_state(tls_conn::TLS.Conn)
    proto = state.alpn_protocol
    if proto != "h2"
        got = proto === nothing ? "<none>" : proto::String
        throw(H2NegotiationError("http2: unexpected ALPN protocol $got; want h2"))
    end
    return nothing
end

function _make_tls_config_for_h2(
    config::Union{Nothing,TLS.Config},
    address::String,
    server_name::Union{Nothing,String}=nothing,
    handshake_timeout_ns::Int64=Int64(0),
)::TLS.Config
    host, _ = HostResolvers.split_host_port(address)
    effective_server_name = server_name === nothing ? host : server_name
    if config === nothing
        return _tls_config_from_parts(
            effective_server_name,
            true,
            true,
            TLS.ClientAuthMode.NoClientCert,
            nothing,
            nothing,
            nothing,
            nothing,
            ["h2"],
            UInt16[],
            handshake_timeout_ns,
            TLS.TLS1_2_VERSION,
            nothing,
            false,
            64,
        )
    end
    protocols = isempty(config.alpn_protocols) ? ["h2"] : copy(config.alpn_protocols)
    in("h2", protocols) || push!(protocols, "h2")
    effective_handshake_timeout_ns = _min_nonzero_ns(config.handshake_timeout_ns, handshake_timeout_ns)
    return _tls_config_from_parts(
        server_name === nothing ? (config.server_name === nothing ? host : config.server_name) : server_name,
        config.verify_peer,
        config.verify_hostname,
        config.client_auth,
        config.cert_file,
        config.key_file,
        config.ca_file,
        config.client_ca_file,
        protocols,
        copy(config.curve_preferences),
        effective_handshake_timeout_ns,
        config.min_version,
        config.max_version,
        config.session_tickets_disabled,
        64,
    )
end

"""
    _connect_h2_from_tcp!(tcp, address, secure=false, tls_config=nothing, connect_deadline_ns=0) -> H2Connection

Open and initialize an HTTP/2 client connection on an existing TCP socket,
including client preface, SETTINGS exchange, optional TLS handshake, and ALPN
verification.

Returns a ready-to-use `H2Connection`. Throws `H2NegotiationError` for ALPN
failures, `ProtocolError` for invalid peer behavior during setup, and any TCP,
TLS, or I/O exceptions from the underlying transport.
"""
function _connect_h2_from_tcp!(
    tcp::TCP.Conn,
    address::String,
    secure::Bool=false,
    tls_config::Union{Nothing,TLS.Config}=nothing,
    connect_deadline_ns::Int64=Int64(0),
)::H2Connection
    tls_conn = nothing
    try
        stream_reader = nothing
        connect_deadline_ns == 0 || TCP.set_deadline!(tcp, connect_deadline_ns)
        if secure
            cfg = _make_tls_config_for_h2(tls_config, address)
            tls_conn = TLS.client(tcp, cfg)
            connect_deadline_ns == 0 || TLS.set_deadline!(tls_conn, connect_deadline_ns)
            TLS.handshake!(tls_conn)
            stream_reader = _ConnReader(tls_conn::TLS.Conn)
        else
            stream_reader = _ConnReader(tcp)
        end
        state_lock = ReentrantLock()
        conn = H2Connection(
            address,
            secure,
            tcp,
            tls_conn,
            stream_reader,
            16_384,
            Encoder(),
            Decoder(
                max_string_length=_H2_DEFAULT_MAX_HEADER_LIST_SIZE,
                max_header_list_size=_H2_DEFAULT_MAX_HEADER_LIST_SIZE,
            ),
            UInt32(1),
            state_lock,
            ReentrantLock(),
            Dict{UInt32,H2StreamState}(),
            Threads.Condition(state_lock),
            nothing,
            Threads.Condition(state_lock),
            nothing,
            Threads.Condition(state_lock),
            Int64(65_535),
            Int64(65_535),
            Dict{UInt32,Int64}(),
            typemax(Int),
            0,
            typemax(UInt32),
            true,
            _H2_DEFAULT_MAX_HEADER_BLOCK_BYTES,
            false,
        )
        _verify_h2_alpn!(conn)
        _write_all_h2!(conn, _H2_PREFACE)
        _write_frame_h2_threadsafe!(conn, SettingsFrame(false, Pair{UInt16,UInt32}[]))
        _read_settings_until_ready!(conn)
        if tls_conn !== nothing
            TLS.set_deadline!(tls_conn::TLS.Conn, Int64(0))
        else
            TCP.set_deadline!(tcp, Int64(0))
        end
        _start_h2_read_loop!(conn)
        return conn
    catch
        if tls_conn !== nothing
            @try_ignore TLS.close(tls_conn::TLS.Conn)
        end
        @try_ignore TCP.close(tcp)
        rethrow()
    end
end

"""
    connect_h2!(tcp, address; secure=false, tls_config=nothing) -> H2Connection
    connect_h2!(address; secure=false, host_resolver=HostResolver(), tls_config=nothing) -> H2Connection

Establish an explicit HTTP/2 client connection.

This bypasses the higher-level `Client`/`Transport` pool and returns a reusable
`H2Connection` for applications that need direct session ownership.
"""
function connect_h2!(
    tcp::TCP.Conn,
    address::AbstractString;
    secure::Bool=false,
    tls_config::Union{Nothing,TLS.Config}=nothing,
    connect_deadline_ns::Int64=Int64(0),
)::H2Connection
    return _connect_h2_from_tcp!(tcp, String(address), secure, tls_config, connect_deadline_ns)
end

function connect_h2!(
    address::AbstractString;
    secure::Bool=false,
    host_resolver::HostResolvers.HostResolver=HostResolvers.HostResolver(),
    tls_config::Union{Nothing,TLS.Config}=nothing,
    connect_deadline_ns::Int64=Int64(0),
)::H2Connection
    tcp = TCP.connect(host_resolver, "tcp", address)
    return _connect_h2_from_tcp!(tcp, String(address), secure, tls_config, connect_deadline_ns)
end

"""
    close(conn::H2Connection)

Close the HTTP/2 connection and underlying transport.

All active streams are failed, buffered readers are awakened, and the
background read loop is given a chance to exit. The function is idempotent and
returns `nothing`.
"""
function Base.close(conn::H2Connection)
    stream_states = H2StreamState[]
    read_task = nothing
    lock(conn.state_lock)
    try
        if @atomic :acquire conn.closed
            return nothing
        end
        @atomic :release conn.closed = true
        notify(conn.stream_condition; all=true)
        notify(conn.window_condition; all=true)
        conn.conn_error === nothing && (conn.conn_error = ProtocolError("HTTP/2 connection is closed"))
        append!(stream_states, values(conn.streams))
        read_task = conn.read_task
    finally
        unlock(conn.state_lock)
    end
    for state in stream_states
        _set_stream_conn_errored!(state)
    end
    _close_h2_transports!(conn)
    if read_task !== nothing && (read_task::Task) !== current_task()
        _wait_h2_read_loop_exit!(conn, read_task::Task)
    end
    return nothing
end

function _write_request_body_h2!(conn::H2Connection, stream_id::UInt32, request::Request)
    request.body isa EmptyBody && return nothing
    buf = Vector{UInt8}(undef, 16 * 1024)
    pending = UInt8[]
    have_pending = false
    try
        while true
            n = body_read!(request.body, buf)
            if n == 0
                if have_pending
                    _write_data_frames_h2!(conn, stream_id, request, pending, true)
                else
                    _write_frame_h2_threadsafe!(conn, DataFrame(stream_id, true, UInt8[]), _request_write_deadline_ns(request))
                end
                return nothing
            end
            current = Vector{UInt8}(undef, n)
            copyto!(current, 1, buf, 1, n)
            if have_pending
                _write_data_frames_h2!(conn, stream_id, request, pending, false)
            end
            pending = current
            have_pending = true
        end
    finally
        @try_ignore body_close!(request.body)
    end
end

@inline function _is_h2_connection_specific_header(name::String)::Bool
    return name == "connection" || name == "proxy-connection" || name == "keep-alive" || name == "upgrade"
end

@inline function _strict_h2_outgoing_header_value(name::AbstractString, value::AbstractString)::String
    normalized = _normalize_strict_header_field_value(value)
    normalized === nothing && throw(ProtocolError("invalid HTTP/2 header field value for $(repr(name))"))
    return normalized
end

function _request_headers_for_h2(address::String, request::Request, secure::Bool)::Vector{HeaderField}
    method = request.method
    _valid_header_field_name(method) || throw(ProtocolError("invalid HTTP/2 :method pseudo-header"))
    authority = _strict_h2_outgoing_header_value(":authority", request.host === nothing ? address : (request.host::String))
    normal_connect = request.method == "CONNECT" && !startswith(request.target, "/")
    fields = HeaderField[HeaderField(":method", method, false)]
    push!(fields, HeaderField(":authority", authority, false))
    if !normal_connect
        push!(fields, HeaderField(":scheme", secure ? "https" : "http", false))
        push!(fields, HeaderField(":path", _strict_h2_outgoing_header_value(":path", request.target), false))
    end
    for key in header_keys(request.headers)
        startswith(key, ":") && throw(ProtocolError("HTTP/2 request headers must not include pseudo-header $(repr(key))"))
        _valid_header_field_name(key) || throw(ProtocolError("invalid HTTP/2 header field name: $(repr(key))"))
        lowered = lowercase(key)
        if lowered == "host" || _is_h2_connection_specific_header(lowered) || lowered == "transfer-encoding"
            continue
        end
        values = headers(request.headers, key)
        for value in values
            normalized = _strict_h2_outgoing_header_value(key, value)
            if lowered == "te"
                lowercase(_trim_http_ows(normalized)) == "trailers" || continue
                push!(fields, HeaderField("te", "trailers", false))
                continue
            end
            if lowered == "cookie"
                for item in split(normalized, ';')
                    cookie_value = _trim_http_ows(item)
                    isempty(cookie_value) && continue
                    push!(fields, HeaderField("cookie", String(cookie_value), false))
                end
                continue
            end
            push!(fields, HeaderField(lowered, normalized, false))
        end
    end
    return fields
end

function _decode_response_headers(headers::Vector{HeaderField})::Tuple{Int,Headers}
    status = nothing
    saw_regular = false
    out = Headers()
    for header in headers
        name = header.name
        value = header.value
        name == lowercase(name) || throw(ProtocolError("HTTP/2 header field names must be lowercase"))
        normalized = _normalize_strict_header_field_value(value)
        normalized === nothing && throw(ProtocolError("invalid HTTP/2 header field value for $(repr(name))"))
        if startswith(name, ':')
            saw_regular && throw(ProtocolError("HTTP/2 pseudo-headers must precede regular headers"))
            if name == ":status"
                status === nothing || throw(ProtocolError("duplicate HTTP/2 :status pseudo-header"))
                parsed_status = try
                    parse(Int, normalized)
                catch
                    throw(ProtocolError("malformed HTTP/2 :status pseudo-header"))
                end
                status = parsed_status
            else
                throw(ProtocolError("unsupported HTTP/2 response pseudo-header $(repr(name))"))
            end
            continue
        end
        saw_regular = true
        if _is_h2_connection_specific_header(name) || name == "transfer-encoding" || name == "te"
            throw(ProtocolError("forbidden HTTP/2 response header $(repr(name))"))
        end
        appendheader(out, name, normalized)
    end
    status === nothing && throw(ProtocolError("missing HTTP/2 :status pseudo-header"))
    return status::Int, out
end

function _decode_h2_trailer_headers(headers::Vector{HeaderField})::Headers
    out = Headers()
    for header in headers
        name = header.name
        value = header.value
        name == lowercase(name) || throw(ProtocolError("HTTP/2 trailer field names must be lowercase"))
        startswith(name, ':') && throw(ProtocolError("HTTP/2 trailers must not include pseudo-headers"))
        _valid_trailer_header_name(name) || throw(ProtocolError("invalid HTTP/2 trailer header $(repr(name))"))
        normalized = _normalize_strict_header_field_value(value)
        normalized === nothing && throw(ProtocolError("invalid HTTP/2 trailer field value for $(repr(name))"))
        appendheader(out, name, normalized)
    end
    return out
end

function _publish_h2_response_trailers!(state::H2StreamState)
    state.trailers_published && return nothing
    target = state.response_trailers
    target === nothing && return nothing
    for key in header_keys(state.pending_trailers)
        values = headers(state.pending_trailers, key)
        for value in values
            appendheader(target::Headers, key, value)
        end
    end
    state.trailers_published = true
    return nothing
end

function _write_h2_header_block_locked!(
    conn::H2Connection,
    stream_id::UInt32,
    header_block::Vector{UInt8},
    end_stream::Bool,
    write_deadline_ns::Int64=Int64(0),
)::Nothing
    _header_block_frames(stream_id, end_stream, header_block, conn.peer_max_send_frame_size) do frame
        _write_frame_h2!(conn, frame, write_deadline_ns)
    end
    return nothing
end

"""
    _stream_available_bytes(state) -> Int

Return the number of unread response-body bytes currently buffered in `state`.
"""
@inline function _stream_available_bytes(state::H2StreamState)::Int
    available = (length(state.body) - state.body_read_index) + 1
    return available > 0 ? available : 0
end

function _compact_stream_body_buffer!(state::H2StreamState)
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

function body_closed(body::H2Body)::Bool
    return @atomic :acquire body.closed
end

function _wait_h2_body_progress!(state::H2StreamState, deadline_ns::Int64)::Nothing
    while true
        remaining_ns = deadline_ns - Int64(time_ns())
        remaining_ns <= 0 && throw(IOPoll.DeadlineExceededError())
        status = IOPoll.timedwait(() -> begin
            lock(state.lock)
            try
                (_stream_failed(state) || state.stream_done) && return true
                return _stream_available_bytes(state) > 0
            finally
                unlock(state.lock)
            end
        end, remaining_ns / 1.0e9; pollint=0.001)
        status == :timed_out && throw(IOPoll.DeadlineExceededError())
        return nothing
    end
end

function body_read!(body::H2Body, dst::Vector{UInt8})::Int
    isempty(dst) && return 0
    body_closed(body) && return 0
    while true
        nread = 0
        done = false
        too_many = false
        wait_deadline_ns = Int64(0)
        lock(body.state.lock)
        try
            available = _stream_available_bytes(body.state)
            if available > 0
                body.state.conn_errored && !body.state.stream_done && _throw_stream_error(body.conn, body.state)
                nread = min(length(dst), available)
                expected = body.expected_content_length
                if expected >= 0 && body.bytes_read + Int64(nread) > expected
                    too_many = true
                    body.state.stream_error = ProtocolError("HTTP/2 response body exceeded Content-Length")
                    body.state.stream_done = true
                    notify(body.state.condition)
                else
                    copyto!(dst, 1, body.state.body, body.state.body_read_index, nread)
                    body.state.body_read_index += nread
                    _compact_stream_body_buffer!(body.state)
                    notify(body.state.condition)
                end
            elseif body.state.stream_done
                _publish_h2_response_trailers!(body.state)
                done = true
            else
                _throw_stream_error(body.conn, body.state)
                deadline_ns = _request_read_deadline_ns(body.request)
                if deadline_ns == 0
                    wait(body.state.condition)
                else
                    wait_deadline_ns = deadline_ns
                end
            end
        finally
            unlock(body.state.lock)
        end
        wait_deadline_ns == 0 || (_wait_h2_body_progress!(body.state, wait_deadline_ns); continue)
        if too_many
            @atomic :release body.closed = true
            @try_ignore _write_frame_h2_threadsafe!(body.conn, RSTStreamFrame(body.stream_id, UInt32(0x1)))
            _unregister_stream!(body.conn, body.stream_id)
            throw(ProtocolError("HTTP/2 response body exceeded Content-Length"))
        end
        if nread > 0
            body.bytes_read += Int64(nread)
            _send_window_updates!(body.conn, body.stream_id, nread)
            return nread
        end
        if done
            if body.expected_content_length >= 0 && body.bytes_read != body.expected_content_length
                @atomic :release body.closed = true
                _unregister_stream!(body.conn, body.stream_id)
                throw(ProtocolError("HTTP/2 response body ended before Content-Length bytes were received"))
            end
            @atomic :release body.closed = true
            _unregister_stream!(body.conn, body.stream_id)
            return 0
        end
    end
end

function body_close!(body::H2Body)
    was_closed = body_closed(body)
    was_closed && return nothing
    @atomic :release body.closed = true
    should_reset = false
    lock(body.state.lock)
    try
        if !body.state.stream_done
            should_reset = true
            body.state.stream_error === nothing && (body.state.stream_error = ProtocolError("HTTP/2 response body closed"))
            body.state.stream_done = true
            notify(body.state.condition)
        end
    finally
        unlock(body.state.lock)
    end
    if should_reset
        @try_ignore _write_frame_h2_threadsafe!(body.conn, RSTStreamFrame(body.stream_id, UInt32(0x8)))
    end
    _unregister_stream!(body.conn, body.stream_id)
    return nothing
end

function _wait_stream_headers!(conn::H2Connection, state::H2StreamState, deadline_ns::Int64)
    if deadline_ns == 0
        lock(state.lock)
        try
            while !state.headers_complete && !state.stream_done && !_stream_failed(state)
                wait(state.condition)
            end
        finally
            unlock(state.lock)
        end
        return nothing
    end
    while true
        lock(state.lock)
        try
            (state.headers_complete || state.stream_done || _stream_failed(state)) && return nothing
        finally
            unlock(state.lock)
        end
        remaining_ns = deadline_ns - Int64(time_ns())
        remaining_ns <= 0 && throw(IOPoll.DeadlineExceededError())
        status = IOPoll.timedwait(() -> begin
            lock(state.lock)
            try
                return state.headers_complete || state.stream_done || _stream_failed(state)
            finally
                unlock(state.lock)
            end
        end, remaining_ns / 1.0e9; pollint=0.001)
        status == :timed_out && throw(IOPoll.DeadlineExceededError())
    end
end

function _h2_roundtrip_incoming!(conn::H2Connection, request::Request)::_IncomingResponse
    stream_state = _register_stream!(conn)
    cleanup_on_exit = true
    try
        headers = _request_headers_for_h2(conn.address, request, conn.secure)
        if conn.peer_max_header_list_size > 0 && _header_list_size(headers) > conn.peer_max_header_list_size
            throw(ProtocolError("HTTP/2 request headers exceed peer SETTINGS_MAX_HEADER_LIST_SIZE"))
        end
        try
            end_stream = request.body isa EmptyBody
            lock(conn.write_lock)
            try
                (@atomic :acquire conn.closed) && throw(ProtocolError("HTTP/2 connection is closed"))
                conn.conn_error === nothing || throw(conn.conn_error::ProtocolError)
                header_block = encode_header_block(conn.encoder, headers)
                _write_h2_header_block_locked!(
                    conn,
                    stream_state.stream_id,
                    header_block,
                    end_stream,
                    _request_write_deadline_ns(request),
                )
            finally
                unlock(conn.write_lock)
            end
            end_stream || _write_request_body_h2!(conn, stream_state.stream_id, request)
        catch err
            _fail_h2_connection!(conn, ProtocolError("HTTP/2 write failed", err::Exception))
            rethrow()
        end
        _wait_stream_headers!(conn, stream_state, _request_response_header_deadline_ns(request))
        lock(stream_state.lock)
        try
            _throw_stream_error(conn, stream_state)
            stream_state.headers_complete || throw(ProtocolError("HTTP/2 response ended without END_HEADERS"))
            stream_state.decoded_headers === nothing && throw(ProtocolError("HTTP/2 response missing decoded headers"))
            decoded_headers = stream_state.decoded_headers::Vector{HeaderField}
            status, response_headers = _decode_response_headers(decoded_headers)
            response_content_length = _parse_content_length(response_headers)
            response_trailers = Headers()
            stream_state.response_trailers = response_trailers
            if stream_state.stream_done && _stream_available_bytes(stream_state) == 0
                if response_content_length > 0 && _body_allowed_for_status(status) && request.method != "HEAD"
                    throw(ProtocolError("HTTP/2 response body ended before Content-Length bytes were received"))
                end
                _publish_h2_response_trailers!(stream_state)
                cleanup_on_exit = false
                _unregister_stream!(conn, stream_state.stream_id)
                return _IncomingResponse(
                    _IncomingResponseHead(
                        status,
                        "",
                        response_headers,
                        response_trailers,
                        response_content_length >= 0 ? response_content_length : Int64(0),
                        UInt8(2),
                        UInt8(0),
                        false,
                        request,
                        nothing,
                        nothing,
                        0,
                    ),
                    EmptyBody(),
                )
            end
            body = H2Body(conn, stream_state.stream_id, stream_state, request, response_trailers, response_content_length, Int64(0), false)
            cleanup_on_exit = false
            return _IncomingResponse(
                _IncomingResponseHead(
                    status,
                    "",
                    response_headers,
                    response_trailers,
                    response_content_length,
                    UInt8(2),
                    UInt8(0),
                    false,
                    request,
                    nothing,
                    nothing,
                    0,
                ),
                body,
            )
        finally
            unlock(stream_state.lock)
        end
    finally
        cleanup_on_exit && _unregister_stream!(conn, stream_state.stream_id)
    end
end

"""
    h2_roundtrip!(conn, request) -> Response

Send `request` over an existing `H2Connection` and return the streaming
`Response`.
"""
function h2_roundtrip!(conn::H2Connection, request::Request)::Response
    return _streaming_response(_h2_roundtrip_incoming!(conn, request))
end
