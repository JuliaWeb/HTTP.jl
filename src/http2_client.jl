# HTTP/2 client connection and roundtrip implementation.
using Reseau.TCP
using Reseau.HostResolvers
using Reseau.TLS
using Reseau.IOPoll

const _H2_PREFACE = collect(codeunits("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"))
const _H2_DEFAULT_MAX_HEADER_LIST_SIZE = 10 * 1024 * 1024
const _H2_DEFAULT_MAX_HEADER_BLOCK_BYTES = 2 * _H2_DEFAULT_MAX_HEADER_LIST_SIZE

"""
    H2NegotiationError

Raised when the connection transport succeeds but cannot be used for HTTP/2,
most notably when TLS ALPN negotiates a protocol other than `h2`.
"""
struct H2NegotiationError <: Exception
    message::String
end

function Base.showerror(io::IO, err::H2NegotiationError)
    print(io, err.message)
    return nothing
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
    body::Vector{UInt8}
    body_read_index::Int
    max_buffered_bytes::Int
    headers_complete::Bool
    stream_done::Bool
    error::Union{Nothing,Exception}
end

function H2StreamState(stream_id::UInt32)
    lock = ReentrantLock()
    return H2StreamState(
        stream_id,
        lock,
        Threads.Condition(lock),
        UInt8[],
        nothing,
        UInt8[],
        1,
        256 * 1024,
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
mutable struct H2Connection{F<:Framer}
    address::String
    secure::Bool
    tcp::TCP.Conn
    tls::Union{Nothing,TLS.Conn}
    reader::F
    encoder::Encoder
    decoder::Decoder
    next_stream_id::UInt32
    state_lock::ReentrantLock
    write_lock::ReentrantLock
    streams::Dict{UInt32,H2StreamState}
    read_task::Union{Nothing,Task}
    read_loop_condition::Threads.Condition
    conn_error::Union{Nothing,Exception}
    window_condition::Threads.Condition
    conn_send_window::Int64
    initial_stream_send_window::Int64
    stream_send_window::Dict{UInt32,Int64}
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
mutable struct H2Body{C<:H2Connection} <: AbstractBody
    conn::C
    stream_id::UInt32
    state::H2StreamState
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

function _write_frame_h2!(conn::H2Connection, frame::AbstractFrame)
    io = IOBuffer()
    framer = Framer(io)
    write_frame!(framer, frame)
    _write_all_h2!(conn, take!(io))
    return nothing
end

function _write_frame_h2_threadsafe!(conn::H2Connection, frame::AbstractFrame)
    lock(conn.write_lock)
    try
        _write_frame_h2!(conn, frame)
    finally
        unlock(conn.write_lock)
    end
    return nothing
end

@inline function _h2_max_data_frame_size(conn::H2Connection)::Int
    return conn.reader.max_frame_size
end

function _reserve_send_window!(conn::H2Connection, stream_id::UInt32, wanted::Int)::Int
    wanted > 0 || throw(ArgumentError("wanted send window must be > 0"))
    lock(conn.state_lock)
    try
        while true
            (@atomic :acquire conn.closed) && throw(ProtocolError("HTTP/2 connection is closed"))
            conn.conn_error === nothing || throw(conn.conn_error::Exception)
            stream_window = get(() -> Int64(0), conn.stream_send_window, stream_id)
            if stream_window <= 0 || conn.conn_send_window <= 0
                # Both the connection-level and per-stream windows must allow
                # progress. The read loop replenishes these via WINDOW_UPDATE.
                wait(conn.window_condition)
                continue
            end
            allowed = min(Int64(wanted), conn.conn_send_window, stream_window, Int64(_h2_max_data_frame_size(conn)))
            if allowed <= 0
                wait(conn.window_condition)
                continue
            end
            conn.conn_send_window -= allowed
            conn.stream_send_window[stream_id] = stream_window - allowed
            return Int(allowed)
        end
    finally
        unlock(conn.state_lock)
    end
end

function _write_data_frames_h2!(conn::H2Connection, stream_id::UInt32, data::Vector{UInt8}; end_stream::Bool)
    isempty(data) && return nothing
    offset = 1
    total_len = length(data)
    while offset <= total_len
        remaining = total_len - offset + 1
        chunk_len = _reserve_send_window!(conn, stream_id, remaining)
        chunk = Vector{UInt8}(undef, chunk_len)
        copyto!(chunk, 1, data, offset, chunk_len)
        final_chunk = (offset + chunk_len - 1) == total_len
        _write_frame_h2_threadsafe!(conn, DataFrame(stream_id, end_stream && final_chunk, chunk))
        offset += chunk_len
    end
    return nothing
end

function _apply_peer_settings!(conn::H2Connection, settings::Vector{Pair{UInt16,UInt32}})
    lock(conn.state_lock)
    try
        for setting in settings
            if setting.first == UInt16(0x4)
                value = setting.second
                value > UInt32(0x7fff_ffff) && throw(ProtocolError("HTTP/2 SETTINGS_INITIAL_WINDOW_SIZE too large"))
                new_window = Int64(value)
                delta = new_window - conn.initial_stream_send_window
                conn.initial_stream_send_window = new_window
                for stream_id in keys(conn.stream_send_window)
                    conn.stream_send_window[stream_id] = conn.stream_send_window[stream_id] + delta
                end
                continue
            end
            if setting.first == UInt16(0x5)
                value = setting.second
                value < UInt32(16_384) && throw(ProtocolError("HTTP/2 SETTINGS_MAX_FRAME_SIZE too small"))
                value > UInt32(16_777_215) && throw(ProtocolError("HTTP/2 SETTINGS_MAX_FRAME_SIZE too large"))
                conn.reader.max_frame_size = Int(value)
            end
        end
        notify(conn.window_condition; all=true)
    finally
        unlock(conn.state_lock)
    end
    return nothing
end

function _set_stream_error!(state::H2StreamState, err::Exception)
    lock(state.lock)
    try
        state.error === nothing && (state.error = err)
        state.stream_done = true
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

function _register_stream!(conn::H2Connection)::H2StreamState
    lock(conn.state_lock)
    try
        (@atomic :acquire conn.closed) && throw(ProtocolError("HTTP/2 connection is closed"))
        conn.conn_error === nothing || throw(conn.conn_error::Exception)
        stream_id = conn.next_stream_id
        conn.next_stream_id += UInt32(2)
        state = H2StreamState(stream_id)
        conn.streams[stream_id] = state
        conn.stream_send_window[stream_id] = conn.initial_stream_send_window
        return state
    finally
        unlock(conn.state_lock)
    end
end

function _unregister_stream!(conn::H2Connection, stream_id::UInt32)
    lock(conn.state_lock)
    try
        delete!(conn.streams, stream_id)
        delete!(conn.stream_send_window, stream_id)
    finally
        unlock(conn.state_lock)
    end
    return nothing
end

function _close_h2_transports!(conn::H2Connection)
    if conn.secure
        if conn.tls !== nothing
            try
                TLS.close(conn.tls::TLS.Conn)
            catch
            end
        end
    end
    try
        TCP.close(conn.tcp)
    catch
    end
    return nothing
end

function _fail_h2_connection!(conn::H2Connection, err::Exception)
    stream_states = H2StreamState[]
    lock(conn.state_lock)
    try
        conn.conn_error === nothing && (conn.conn_error = err)
        @atomic :release conn.closed = true
        notify(conn.window_condition; all=true)
        append!(stream_states, values(conn.streams))
    finally
        unlock(conn.state_lock)
    end
    close_err = conn.conn_error === nothing ? err : (conn.conn_error::Exception)
    for state in stream_states
        lock(state.lock)
        try
            if state.stream_done && state.error === nothing
                notify(state.condition)
                continue
            end
            state.error === nothing && (state.error = close_err)
            state.stream_done = true
            notify(state.condition)
        finally
            unlock(state.lock)
        end
    end
    _close_h2_transports!(conn)
    return nothing
end

function _read_settings_until_ready!(conn::H2Connection)
    saw_peer_settings = false
    while !saw_peer_settings
        frame = read_frame!(conn.reader)
        if frame isa SettingsFrame
            settings = frame::SettingsFrame
            if settings.ack
                continue
            end
            _apply_peer_settings!(conn, settings.settings)
            _write_frame_h2_threadsafe!(conn, SettingsFrame(true, Pair{UInt16,UInt32}[]))
            saw_peer_settings = true
            continue
        end
        if frame isa PingFrame
            ping = frame::PingFrame
            ping.ack || _write_frame_h2_threadsafe!(conn, PingFrame(true, ping.opaque_data))
            continue
        end
        if frame isa GoAwayFrame
            throw(ProtocolError("HTTP/2 peer sent GOAWAY"))
        end
    end
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
            state.decoded_headers = decode_header_block(conn.decoder, state.header_block)
            state.headers_complete = true
            empty!(state.header_block)
        end
        if end_stream
            state.stream_done = true
            notify(state.condition)
        end
    finally
        unlock(state.lock)
    end
    return nothing
end

function _handle_stream_data!(state::H2StreamState, frame::DataFrame)
    lock(state.lock)
    try
        while ((length(state.body) - state.body_read_index) + 1) >= state.max_buffered_bytes && state.error === nothing && !state.stream_done
            wait(state.condition)
        end
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
    end
    if frame isa PingFrame
        ping = frame::PingFrame
        ping.ack || _write_frame_h2_threadsafe!(conn, PingFrame(true, ping.opaque_data))
        return nothing
    end
    if frame isa GoAwayFrame
        throw(ProtocolError("HTTP/2 peer sent GOAWAY"))
    end
    if frame isa RSTStreamFrame
        rst = frame::RSTStreamFrame
        state = _stream_state(conn, rst.stream_id)
        state === nothing && return nothing
        _set_stream_error!(state::H2StreamState, ProtocolError("HTTP/2 stream reset by peer"))
        return nothing
    end
    if frame isa WindowUpdateFrame
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
    end
    if frame isa HeadersFrame
        headers = frame::HeadersFrame
        state = _stream_state(conn, headers.stream_id)
        state === nothing && return nothing
        _handle_stream_header_fragment!(conn, state::H2StreamState, headers.header_block_fragment, headers.end_headers, headers.end_stream)
        return nothing
    end
    if frame isa ContinuationFrame
        cont = frame::ContinuationFrame
        state = _stream_state(conn, cont.stream_id)
        state === nothing && return nothing
        _handle_stream_header_fragment!(conn, state::H2StreamState, cont.header_block_fragment, cont.end_headers, false)
        return nothing
    end
    if frame isa DataFrame
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
        if err isa Exception
            _fail_h2_connection!(conn, err::Exception)
        else
            _fail_h2_connection!(conn, ProtocolError("HTTP/2 read loop failed"))
        end
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
        conn.read_task = errormonitor(Threads.@spawn _run_h2_read_loop!(conn))
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

function _make_tls_config_for_h2(config::Union{Nothing,TLS.Config}, address::String)::TLS.Config
    host, _ = HostResolvers.split_host_port(address)
    if config === nothing
        return TLS.Config(server_name=host, alpn_protocols=["h2"])
    end
    protocols = isempty(config.alpn_protocols) ? ["h2"] : copy(config.alpn_protocols)
    in("h2", protocols) || push!(protocols, "h2")
    return TLS.Config(
        server_name=config.server_name === nothing ? host : config.server_name,
        verify_peer=config.verify_peer,
        client_auth=config.client_auth,
        cert_file=config.cert_file,
        key_file=config.key_file,
        ca_file=config.ca_file,
        client_ca_file=config.client_ca_file,
        alpn_protocols=protocols,
        handshake_timeout_ns=config.handshake_timeout_ns,
        min_version=config.min_version,
        max_version=config.max_version,
    )
end

"""
    _connect_h2_from_tcp!(tcp, address; secure=false, tls_config=nothing) -> H2Connection

Open and initialize an HTTP/2 client connection on an existing TCP socket,
including client preface, SETTINGS exchange, optional TLS handshake, and ALPN
verification.

Keyword arguments:
- `secure`: when `true`, connect over TLS and require ALPN `h2`
- `tls_config`: optional TLS configuration, augmented as needed to advertise `h2`

Returns a ready-to-use `H2Connection`. Throws `H2NegotiationError` for ALPN
failures, `ProtocolError` for invalid peer behavior during setup, and any TCP,
TLS, or I/O exceptions from the underlying transport.
"""
function _connect_h2_from_tcp!(
    tcp::TCP.Conn,
    address::String;
    secure::Bool=false,
    tls_config::Union{Nothing,TLS.Config}=nothing,
)::H2Connection
    tls_conn = nothing
    try
        stream_reader = nothing
        if secure
            cfg = _make_tls_config_for_h2(tls_config, address)
            tls_conn = TLS.client(tcp, cfg)
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
            Framer(stream_reader),
            Encoder(),
            Decoder(
                max_string_length=_H2_DEFAULT_MAX_HEADER_LIST_SIZE,
                max_header_list_size=_H2_DEFAULT_MAX_HEADER_LIST_SIZE,
            ),
            UInt32(1),
            state_lock,
            ReentrantLock(),
            Dict{UInt32,H2StreamState}(),
            nothing,
            Threads.Condition(state_lock),
            nothing,
            Threads.Condition(state_lock),
            Int64(65_535),
            Int64(65_535),
            Dict{UInt32,Int64}(),
            _H2_DEFAULT_MAX_HEADER_BLOCK_BYTES,
            false,
        )
        _verify_h2_alpn!(conn)
        _write_all_h2!(conn, _H2_PREFACE)
        _write_frame_h2_threadsafe!(conn, SettingsFrame(false, Pair{UInt16,UInt32}[]))
        _read_settings_until_ready!(conn)
        _start_h2_read_loop!(conn)
        return conn
    catch
        if tls_conn !== nothing
            try
                TLS.close(tls_conn::TLS.Conn)
            catch
            end
        end
        try
            TCP.close(tcp)
        catch
        end
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
)::H2Connection
    return _connect_h2_from_tcp!(tcp, String(address); secure=secure, tls_config=tls_config)
end

function connect_h2!(
    address::AbstractString;
    secure::Bool=false,
    host_resolver::HostResolvers.HostResolver=HostResolvers.HostResolver(),
    tls_config::Union{Nothing,TLS.Config}=nothing,
)::H2Connection
    tcp = TCP.connect(host_resolver, "tcp", address)
    return _connect_h2_from_tcp!(tcp, String(address); secure=secure, tls_config=tls_config)
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
        notify(conn.window_condition; all=true)
        conn.conn_error === nothing && (conn.conn_error = ProtocolError("HTTP/2 connection is closed"))
        append!(stream_states, values(conn.streams))
        read_task = conn.read_task
    finally
        unlock(conn.state_lock)
    end
    close_err = conn.conn_error === nothing ? ProtocolError("HTTP/2 connection is closed") : (conn.conn_error::Exception)
    for state in stream_states
        _set_stream_error!(state, close_err)
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
                    _write_data_frames_h2!(conn, stream_id, pending; end_stream=true)
                else
                    _write_frame_h2_threadsafe!(conn, DataFrame(stream_id, true, UInt8[]))
                end
                return nothing
            end
            current = Vector{UInt8}(undef, n)
            copyto!(current, 1, buf, 1, n)
            if have_pending
                _write_data_frames_h2!(conn, stream_id, pending; end_stream=false)
            end
            pending = current
            have_pending = true
        end
    finally
        try
            body_close!(request.body)
        catch
        end
    end
end

@inline function _is_h2_connection_specific_header(name::String)::Bool
    return name == "connection" || name == "proxy-connection" || name == "keep-alive" || name == "upgrade"
end

function _request_headers_for_h2(address::String, request::Request, secure::Bool)::Vector{HeaderField}
    authority = request.host === nothing ? address : (request.host::String)
    normal_connect = request.method == "CONNECT" && !startswith(request.target, "/")
    fields = HeaderField[HeaderField(":method", request.method, false)]
    push!(fields, HeaderField(":authority", authority, false))
    if !normal_connect
        push!(fields, HeaderField(":scheme", secure ? "https" : "http", false))
        push!(fields, HeaderField(":path", request.target, false))
    end
    for key in header_keys(request.headers)
        startswith(key, ":") && continue
        lowered = lowercase(key)
        if lowered == "host" || _is_h2_connection_specific_header(lowered) || lowered == "transfer-encoding"
            continue
        end
        values = headers(request.headers, key)
        for value in values
            if lowered == "te"
                lowercase(_trim_http_ows(value)) == "trailers" || continue
                push!(fields, HeaderField("te", "trailers", false))
                continue
            end
            push!(fields, HeaderField(lowered, value, false))
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
        normalized = _normalize_header_field_value(value)
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

function _write_h2_header_block_locked!(
    conn::H2Connection,
    stream_id::UInt32,
    header_block::Vector{UInt8};
    end_stream::Bool,
)::Nothing
    for frame in _header_block_frames(stream_id, end_stream, header_block, conn.reader.max_frame_size)
        _write_frame_h2!(conn, frame)
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

function body_read!(body::H2Body, dst::Vector{UInt8})::Int
    isempty(dst) && return 0
    body_closed(body) && return 0
    while true
        nread = 0
        done = false
        lock(body.state.lock)
        try
            body.state.error === nothing || throw(body.state.error::Exception)
            available = _stream_available_bytes(body.state)
            if available > 0
                nread = min(length(dst), available)
                copyto!(dst, 1, body.state.body, body.state.body_read_index, nread)
                body.state.body_read_index += nread
                _compact_stream_body_buffer!(body.state)
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
            _send_window_updates!(body.conn, body.stream_id, nread)
            return nread
        end
        if done
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
            body.state.error === nothing && (body.state.error = ProtocolError("HTTP/2 response body closed"))
            body.state.stream_done = true
            notify(body.state.condition)
        end
    finally
        unlock(body.state.lock)
    end
    if should_reset
        try
            _write_frame_h2_threadsafe!(body.conn, RSTStreamFrame(body.stream_id, UInt32(0x8)))
        catch
        end
    end
    _unregister_stream!(body.conn, body.stream_id)
    return nothing
end

function _wait_stream_headers!(state::H2StreamState)
    lock(state.lock)
    try
        while !state.headers_complete && !state.stream_done && state.error === nothing
            wait(state.condition)
        end
    finally
        unlock(state.lock)
    end
    return nothing
end

function _h2_roundtrip_incoming!(conn::H2Connection, request::Request)::_IncomingResponse
    stream_state = _register_stream!(conn)
    cleanup_on_exit = true
    try
        headers = _request_headers_for_h2(conn.address, request, conn.secure)
        try
            end_stream = request.body isa EmptyBody
            lock(conn.write_lock)
            try
                (@atomic :acquire conn.closed) && throw(ProtocolError("HTTP/2 connection is closed"))
                conn.conn_error === nothing || throw(conn.conn_error::Exception)
                header_block = encode_header_block(conn.encoder, headers)
                _write_h2_header_block_locked!(conn, stream_state.stream_id, header_block; end_stream=end_stream)
            finally
                unlock(conn.write_lock)
            end
            end_stream || _write_request_body_h2!(conn, stream_state.stream_id, request)
        catch err
            if err isa Exception
                _fail_h2_connection!(conn, err::Exception)
            else
                _fail_h2_connection!(conn, ProtocolError("HTTP/2 write failed"))
            end
            rethrow()
        end
        _wait_stream_headers!(stream_state)
        lock(stream_state.lock)
        try
            stream_state.error === nothing || throw(stream_state.error::Exception)
            stream_state.headers_complete || throw(ProtocolError("HTTP/2 response ended without END_HEADERS"))
            stream_state.decoded_headers === nothing && throw(ProtocolError("HTTP/2 response missing decoded headers"))
            decoded_headers = stream_state.decoded_headers::Vector{HeaderField}
            status, response_headers = _decode_response_headers(decoded_headers)
            if stream_state.stream_done && _stream_available_bytes(stream_state) == 0
                cleanup_on_exit = false
                _unregister_stream!(conn, stream_state.stream_id)
                return _IncomingResponse(
                    _IncomingResponseHead(
                        status,
                        "",
                        response_headers,
                        Headers(),
                        Int64(0),
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
            body = H2Body(conn, stream_state.stream_id, stream_state, false)
            cleanup_on_exit = false
            return _IncomingResponse(
                _IncomingResponseHead(
                    status,
                    "",
                    response_headers,
                    Headers(),
                    Int64(-1),
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
