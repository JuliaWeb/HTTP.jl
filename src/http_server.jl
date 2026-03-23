# Shared HTTP server kernel for HTTP/1, TLS, and HTTP/2.
export Server
export Stream
export listen
export listen!
export serve
export serve!
export streamhandler
export forceclose
export port

using EnumX: @enumx
using Reseau.TCP
using Reseau.TLS
using Reseau.HostResolvers
using Reseau.IOPoll

@enumx _ServerState::UInt8 begin
    INITIAL = 0
    RUNNING = 1
    CLOSING = 2
    CLOSED = 3
end

@enumx _ConnState::UInt8 begin
    NEW = 0
    ACTIVE = 1
    IDLE = 2
    HIJACKED = 3
    CLOSED = 4
end

@enumx _StreamType::UInt8 begin
    CLIENT = 0
    SERVER = 1
end

@enumx _ServerStreamWriteMode::UInt8 begin
    UNDECIDED = 0
    NONE = 1
    FIXED = 2
    CHUNKED = 3
    IDENTITY = 4
end

mutable struct _ServerConn
    conn::Union{TCP.Conn,TLS.Conn}
    lock::ReentrantLock
    shutdown_hook::Union{Nothing,Function}
    @atomic state::_ConnState.T
    @atomic state_unix_sec::Int64
end

Base.hash(conn::_ServerConn, h::UInt) = hash(objectid(conn), h)
Base.:(==)(a::_ServerConn, b::_ServerConn) = a === b

"""
    Server(; network="tcp", address="127.0.0.1:0", handler, stream=false, ...)

Stateful HTTP server handle returned by [`listen!`](@ref) and [`serve!`](@ref).

The handle owns the listener, background task, active-connection set, and
timeout configuration. Keep it around for lifecycle operations such as
[`port`](@ref), `wait(server)`, `close(server)`, or [`forceclose`](@ref).
"""
mutable struct Server{F}
    network::String
    address::String
    handler::F
    stream::Bool
    read_timeout_ns::Int64
    read_header_timeout_ns::Int64
    write_timeout_ns::Int64
    idle_timeout_ns::Int64
    max_header_bytes::Int
    listenany::Bool
    reuseaddr::Bool
    backlog::Int
    lock::ReentrantLock
    listener::Union{Nothing,TCP.Listener,TLS.Listener}
    serve_task::Union{Nothing,Task}
    active_conns::Set{_ServerConn}
    bound_address::Union{Nothing,String}
    bound_port::Int
    @atomic state::_ServerState.T
end

function Server(;
    network::AbstractString="tcp",
    address::AbstractString="127.0.0.1:0",
    handler::F,
    stream::Bool=false,
    read_timeout_ns::Integer=Int64(0),
    read_header_timeout_ns::Integer=Int64(0),
    write_timeout_ns::Integer=Int64(0),
    idle_timeout_ns::Integer=Int64(0),
    max_header_bytes::Integer=1 * 1024 * 1024,
    listenany::Bool=false,
    reuseaddr::Bool=true,
    backlog::Integer=128,
) where {F}
    read_timeout_ns >= 0 || throw(ArgumentError("read_timeout_ns must be >= 0"))
    read_header_timeout_ns >= 0 || throw(ArgumentError("read_header_timeout_ns must be >= 0"))
    write_timeout_ns >= 0 || throw(ArgumentError("write_timeout_ns must be >= 0"))
    idle_timeout_ns >= 0 || throw(ArgumentError("idle_timeout_ns must be >= 0"))
    max_header_bytes > 0 || throw(ArgumentError("max_header_bytes must be > 0"))
    backlog > 0 || throw(ArgumentError("backlog must be > 0"))
    return Server{F}(
        String(network),
        String(address),
        handler,
        stream,
        Int64(read_timeout_ns),
        Int64(read_header_timeout_ns),
        Int64(write_timeout_ns),
        Int64(idle_timeout_ns),
        Int(max_header_bytes),
        listenany,
        reuseaddr,
        Int(backlog),
        ReentrantLock(),
        nothing,
        nothing,
        Set{_ServerConn}(),
        nothing,
        0,
        _ServerState.INITIAL,
    )
end

@inline function _h2_max_header_block_bytes(server::Server)::Int
    limit = server.max_header_bytes
    limit > (typemax(Int) >>> 1) && return typemax(Int)
    return limit * 2
end

mutable struct Stream <: IO
    side::_StreamType.T
    method::Union{Nothing,String}
    parsed::Union{Nothing,_URLParts}
    headers::Union{Nothing,Headers}
    client::Union{Nothing,Client}
    owns_client::Bool
    proxy_config::ProxyConfig
    cookies::Union{Bool,Vector{Cookie}}
    cookiejar::Union{Nothing,CookieJar}
    redirect::Bool
    redirect_policy::Union{Nothing,_RedirectPolicy}
    protocol::Symbol
    decompress::Union{Nothing,Bool}
    readtimeout::Float64
    retry_controller::Union{Nothing,_RetryController}
    verbose_config::Union{Nothing,_VerboseConfig}
    request_buffer::IOBuffer
    response::Union{Nothing,Response}
    reader::Union{Nothing,IO}
    producer::Union{Nothing,Task}
    server::Union{Nothing,Server}
    tracked::Union{Nothing,_ServerConn}
    request::Union{Nothing,Request}
    @atomic started::Bool
    @atomic write_closed::Bool
    @atomic read_closed::Bool
    @atomic response_started::Bool
    @atomic continue_sent::Bool
    ignore_writes::Bool
    write_mode::_ServerStreamWriteMode.T
    written_bytes::Int64
end

function Stream(server::Server, tracked::_ServerConn, request::Request)
    response = Response(
        200;
        proto_major=Int(request.proto_major),
        proto_minor=Int(request.proto_minor),
        request=request,
    )
    return Stream(
        _StreamType.SERVER,
        nothing,
        nothing,
        nothing,
        nothing,
        false,
        ProxyConfig(),
        true,
        nothing,
        false,
        nothing,
        :auto,
        nothing,
        0.0,
        nothing,
        nothing,
        IOBuffer(),
        response,
        nothing,
        nothing,
        server,
        tracked,
        request,
        false,
        false,
        false,
        false,
        false,
        false,
        _ServerStreamWriteMode.UNDECIDED,
        Int64(0),
    )
end

function Stream(request::Request)
    response = Response(
        200;
        proto_major=Int(request.proto_major),
        proto_minor=Int(request.proto_minor),
        request=request,
    )
    return Stream(
        _StreamType.SERVER,
        nothing,
        nothing,
        nothing,
        nothing,
        false,
        ProxyConfig(),
        true,
        nothing,
        false,
        nothing,
        :auto,
        nothing,
        0.0,
        nothing,
        nothing,
        IOBuffer(),
        response,
        nothing,
        nothing,
        nothing,
        nothing,
        request,
        false,
        false,
        false,
        false,
        false,
        false,
        _ServerStreamWriteMode.UNDECIDED,
        Int64(0),
    )
end

@inline function _server_state(server::Server)::_ServerState.T
    return @atomic :acquire server.state
end

@inline function _set_server_state!(server::Server, state::_ServerState.T)::Nothing
    @atomic :release server.state = state
    return nothing
end

@inline function _conn_state(conn::_ServerConn)::_ConnState.T
    return @atomic :acquire conn.state
end

@inline function _set_conn_state!(conn::_ServerConn, state::_ConnState.T)::Nothing
    @atomic :release conn.state = state
    @atomic :release conn.state_unix_sec = floor(Int64, time())
    return nothing
end

function _set_conn_shutdown_hook!(conn::_ServerConn, hook::Union{Nothing,Function})::Nothing
    lock(conn.lock)
    try
        conn.shutdown_hook = hook
    finally
        unlock(conn.lock)
    end
    return nothing
end

function _notify_conn_shutdown!(conn::_ServerConn)::Nothing
    hook = nothing
    lock(conn.lock)
    try
        hook = conn.shutdown_hook
    finally
        unlock(conn.lock)
    end
    hook === nothing && return nothing
    hook()
    return nothing
end

@inline function _server_shutting_down(server::Server)::Bool
    state = _server_state(server)
    return state == _ServerState.CLOSING || state == _ServerState.CLOSED
end

function _require_server_stream(stream::Stream)::Nothing
    stream.side == _StreamType.SERVER && return nothing
    throw(ArgumentError("operation is only valid for server-side HTTP streams"))
end

@inline function _server_stream_buffered_h2(stream::Stream)::Bool
    _require_server_stream(stream)
    request = stream.request
    return stream.server === nothing && stream.tracked === nothing && request !== nothing && (request::Request).proto_major == UInt8(2)
end

@inline function _server_stream_buffered_fixed_h1(stream::Stream)::Bool
    _require_server_stream(stream)
    return !_server_stream_buffered_h2(stream) && stream.write_mode == _ServerStreamWriteMode.FIXED
end

"""
    server_addr(server) -> String

Return the bound `host:port` address for a listening server.
"""
function server_addr(server::Server)::String
    lock(server.lock)
    try
        server.bound_address === nothing && throw(ProtocolError("server is not listening"))
        return server.bound_address::String
    finally
        unlock(server.lock)
    end
end

"""
    port(server) -> Int

Return the bound port for `server`, or the configured port if it has not started
listening yet.
"""
function port(server::Server)::Int
    lock(server.lock)
    try
        if server.bound_port != 0
            return server.bound_port
        end
        try
            _, port_text = HostResolvers.split_host_port(server.address)
            port_num = tryparse(Int, port_text)
            return port_num === nothing ? 0 : port_num
        catch
            return 0
        end
    finally
        unlock(server.lock)
    end
end

"""
    isopen(server) -> Bool

Return `true` while `server` can still accept or finish serving connections.
"""
function Base.isopen(server::Server)::Bool
    state = _server_state(server)
    state == _ServerState.CLOSED && return false
    lock(server.lock)
    try
        listener = server.listener
        listener === nothing && return state == _ServerState.INITIAL
        return state == _ServerState.RUNNING
    finally
        unlock(server.lock)
    end
end

"""
    wait(server)

Block until the server task exits.
"""
function Base.wait(server::Server)::Nothing
    task = nothing
    lock(server.lock)
    try
        task = server.serve_task
    finally
        unlock(server.lock)
    end
    task === nothing && return nothing
    wait(task::Task)
    return nothing
end

function _listener_addr(listener::Union{TCP.Listener,TLS.Listener})
    if listener isa TLS.Listener
        return TLS.addr(listener::TLS.Listener)
    end
    return TCP.addr(listener::TCP.Listener)
end

function _listener_bound_address(listener::Union{TCP.Listener,TLS.Listener})::Tuple{String,Int}
    laddr = _listener_addr(listener)
    laddr === nothing && return ("", 0)
    return (sprint(show, laddr), Int(laddr.port))
end

function _accept_server_conn!(listener::Union{TCP.Listener,TLS.Listener})
    if listener isa TLS.Listener
        return TLS.accept(listener::TLS.Listener)
    end
    return TCP.accept(listener::TCP.Listener)
end

function _close_server_transport!(conn::Union{TCP.Conn,TLS.Conn})::Nothing
    if conn isa TLS.Conn
        TLS.close(conn::TLS.Conn)
    else
        TCP.close(conn::TCP.Conn)
    end
    return nothing
end

function _close_server_write!(conn::Union{TCP.Conn,TLS.Conn})::Nothing
    if conn isa TLS.Conn
        TLS.closewrite(conn::TLS.Conn)
    else
        TCP.closewrite(conn::TCP.Conn)
    end
    return nothing
end

function _close_server_listener!(listener::Union{TCP.Listener,TLS.Listener})::Nothing
    if listener isa TLS.Listener
        TLS.close(listener::TLS.Listener)
    else
        TCP.close(listener::TCP.Listener)
    end
    return nothing
end

function _set_read_deadline!(conn::Union{TCP.Conn,TLS.Conn}, deadline_ns::Int64)::Nothing
    if conn isa TLS.Conn
        TLS.set_read_deadline!(conn::TLS.Conn, deadline_ns)
    else
        TCP.set_read_deadline!(conn::TCP.Conn, deadline_ns)
    end
    return nothing
end

function _set_write_deadline!(conn::Union{TCP.Conn,TLS.Conn}, deadline_ns::Int64)::Nothing
    if conn isa TLS.Conn
        TLS.set_write_deadline!(conn::TLS.Conn, deadline_ns)
    else
        TCP.set_write_deadline!(conn::TCP.Conn, deadline_ns)
    end
    return nothing
end

function _set_deadline!(conn::Union{TCP.Conn,TLS.Conn}, deadline_ns::Int64)::Nothing
    if conn isa TLS.Conn
        TLS.set_deadline!(conn::TLS.Conn, deadline_ns)
    else
        TCP.set_deadline!(conn::TCP.Conn, deadline_ns)
    end
    return nothing
end

function _listen_address(server::Server)::String
    !server.listenany && return server.address
    host, _ = HostResolvers.split_host_port(server.address)
    return HostResolvers.join_host_port(host, 0)
end

function _track_conn!(server::Server, tracked::_ServerConn)::Nothing
    lock(server.lock)
    try
        push!(server.active_conns, tracked)
    finally
        unlock(server.lock)
    end
    return nothing
end

function _untrack_conn!(server::Server, tracked::_ServerConn)::Nothing
    lock(server.lock)
    try
        delete!(server.active_conns, tracked)
    finally
        unlock(server.lock)
    end
    return nothing
end

function _server_conns(server::Server)::Vector{_ServerConn}
    tracked = _ServerConn[]
    lock(server.lock)
    try
        append!(tracked, server.active_conns)
    finally
        unlock(server.lock)
    end
    return tracked
end

function _request_conn_shutdowns!(server::Server)::Nothing
    for tracked in _server_conns(server)
        _notify_conn_shutdown!(tracked)
    end
    return nothing
end

function _close_server_conn!(tracked::_ServerConn)::Nothing
    _set_conn_state!(tracked, _ConnState.CLOSED)
    try
        _close_server_transport!(tracked.conn)
    catch
    end
    return nothing
end

function _close_listener!(server::Server)::Nothing
    listener = nothing
    lock(server.lock)
    try
        listener = server.listener
        server.listener = nothing
    finally
        unlock(server.lock)
    end
    listener === nothing && return nothing
    try
        _close_server_listener!(listener::Union{TCP.Listener,TLS.Listener})
    catch
    end
    return nothing
end

function _close_idle_conns!(server::Server)::Bool
    tracked_conns = _server_conns(server)
    isempty(tracked_conns) && return true
    now_sec = floor(Int64, time())
    for tracked in tracked_conns
        state = _conn_state(tracked)
        if state == _ConnState.IDLE
            _close_server_conn!(tracked)
            continue
        end
        if state == _ConnState.NEW
            state_sec = @atomic :acquire tracked.state_unix_sec
            if state_sec != 0 && state_sec < now_sec - 5
                _close_server_conn!(tracked)
            end
        end
    end
    return isempty(_server_conns(server))
end

function _begin_shutdown!(server::Server)::Bool
    lock(server.lock)
    try
        state = _server_state(server)
        if state == _ServerState.CLOSING || state == _ServerState.CLOSED
            return false
        end
        _set_server_state!(server, _ServerState.CLOSING)
        return true
    finally
        unlock(server.lock)
    end
end

"""
    forceclose(server)

Immediately stop accepting new connections and close all tracked connections.
"""
function forceclose(server::Server)::Nothing
    initiated = _begin_shutdown!(server)
    _close_listener!(server)
    for tracked in _server_conns(server)
        _close_server_conn!(tracked)
    end
    wait(server)
    _set_server_state!(server, _ServerState.CLOSED)
    return nothing
end

"""
    close(server)

Gracefully stop accepting new connections, wait for active work to quiesce, and
then close the remaining tracked connections.
"""
function Base.close(server::Server)::Nothing
    state = _server_state(server)
    state == _ServerState.CLOSED && return nothing
    initiated = _begin_shutdown!(server)
    _close_listener!(server)
    _request_conn_shutdowns!(server)
    wait(server)
    poll_s = 0.001
    while true
        _request_conn_shutdowns!(server)
        _close_idle_conns!(server) && break
        sleep(poll_s)
        poll_s < 0.5 && (poll_s = min(poll_s * 2, 0.5))
    end
    _set_server_state!(server, _ServerState.CLOSED)
    return nothing
end

function _set_read_deadline_for_header!(server::Server, conn::Union{TCP.Conn,TLS.Conn})::Nothing
    timeout = server.read_header_timeout_ns > 0 ? server.read_header_timeout_ns : server.read_timeout_ns
    timeout <= 0 && return nothing
    _set_read_deadline!(conn, Int64(time_ns()) + timeout)
    return nothing
end

function _set_read_deadline_for_body!(server::Server, conn::Union{TCP.Conn,TLS.Conn})::Nothing
    timeout = server.read_timeout_ns
    timeout <= 0 && return nothing
    _set_read_deadline!(conn, Int64(time_ns()) + timeout)
    return nothing
end

function _set_idle_deadline!(server::Server, conn::Union{TCP.Conn,TLS.Conn})::Nothing
    timeout = server.idle_timeout_ns > 0 ? server.idle_timeout_ns : server.read_timeout_ns
    timeout <= 0 && return nothing
    _set_read_deadline!(conn, Int64(time_ns()) + timeout)
    return nothing
end

function _set_write_deadline!(server::Server, conn::Union{TCP.Conn,TLS.Conn})::Nothing
    timeout = server.write_timeout_ns
    timeout <= 0 && return nothing
    _set_write_deadline!(conn, Int64(time_ns()) + timeout)
    return nothing
end

function _clear_deadlines!(conn::Union{TCP.Conn,TLS.Conn})::Nothing
    try
        _set_deadline!(conn, Int64(0))
    catch
    end
    return nothing
end

@inline function _request_wants_close(request::Request)::Bool
    request.close && return true
    return headercontains(request.headers, "Connection", "close")
end

@inline function _response_wants_close(response::Response)::Bool
    response.close && return true
    return headercontains(response.headers, "Connection", "close")
end

@inline function _request_body_fully_consumed(request::Request)::Bool
    body = request.body
    body isa EmptyBody && return true
    if body isa _H2ServerBody
        return _h2_server_body_fully_consumed(body::_H2ServerBody)
    end
    if body isa FixedLengthBody
        return (body::FixedLengthBody).remaining == 0
    end
    if body isa ChunkedBody
        return (body::ChunkedBody).done
    end
    body isa EOFBody && return false
    return false
end

function _write_all_response!(conn::Union{TCP.Conn,TLS.Conn}, response::Response)::Nothing
    io = IOBuffer()
    write_response!(io, response)
    bytes = take!(io)
    total = 0
    while total < length(bytes)
        n = write(conn, bytes[(total+1):end])
        n > 0 || throw(ProtocolError("server write made no progress"))
        total += n
    end
    return nothing
end

function _request_has_unsupported_expect(request::Request)::Bool
    values = headers(request.headers, "Expect")
    isempty(values) && return false
    saw_supported = false
    for value in values
        for token in eachsplit(value, ',')
            trimmed = lowercase(strip(token))
            isempty(trimmed) && return true
            if trimmed == "100-continue"
                saw_supported = true
                continue
            end
            return true
        end
    end
    return !saw_supported
end

@inline function _is_connection_reset_error(err::Exception)::Bool
    return err isa SystemError && occursin("Connection reset by peer", sprint(showerror, err))
end

function _server_error_status(err::Exception)::Union{Nothing,Int}
    if err isa ParseError
        return 400
    end
    if err isa ProtocolError
        message = sprint(showerror, err)
        if occursin("max_header_bytes", message) || occursin("max_line_bytes", message)
            return 431
        end
        return 400
    end
    if err isa IOPoll.DeadlineExceededError
        return 408
    end
    return nothing
end

function _try_write_server_error!(conn::Union{TCP.Conn,TLS.Conn}, request::Union{Nothing,Request}, status::Int)::Nothing
    response = Response(
        status;
        close=true,
        content_length=0,
        request=request,
    )
    try
        _write_all_response!(conn, response)
    catch
    end
    try
        _close_server_write!(conn)
    catch
    end
    return nothing
end

function _server_stream_allows_body(stream::Stream)::Bool
    _require_server_stream(stream)
    _body_allowed_for_status(stream.response.status) || return false
    stream.request.method == "HEAD" && return false
    return true
end

function _server_stream_write_mode(stream::Stream)::_ServerStreamWriteMode.T
    # Framing is chosen late so explicit response headers win, while unread
    # request bodies still force connection close independently of write mode.
    allows_body = _server_stream_allows_body(stream)
    allows_body || return _ServerStreamWriteMode.NONE
    headercontains(stream.response.headers, "Transfer-Encoding", "chunked") && return _ServerStreamWriteMode.CHUNKED
    if hasheader(stream.response.headers, "Content-Length") || stream.response.content_length >= 0
        return _ServerStreamWriteMode.FIXED
    end
    if stream.response.proto_major == UInt8(1) && stream.response.proto_minor == UInt8(0)
        stream.response.close = true
        return _ServerStreamWriteMode.IDENTITY
    end
    return _ServerStreamWriteMode.CHUNKED
end

function _write_server_stream_bytes!(stream::Stream, bytes::AbstractVector{UInt8}; buffer::Bool=true)::Nothing
    isempty(bytes) && return nothing
    data = bytes isa Vector{UInt8} ? bytes : Vector{UInt8}(bytes)
    if buffer && (_server_stream_buffered_h2(stream) || _server_stream_buffered_fixed_h1(stream))
        write(stream.request_buffer, data)
        return nothing
    end
    _set_write_deadline!(stream.server, stream.tracked.conn)
    total = 0
    while total < length(data)
        chunk = total == 0 ? data : data[(total+1):end]
        n = write(stream.tracked.conn, chunk)
        n > 0 || throw(ProtocolError("server stream write made no progress"))
        total += n
    end
    return nothing
end

function _write_server_stream_head!(stream::Stream)::Nothing
    headers = copy(stream.response.headers)
    response_close = stream.response.close || _should_close_connection(headers, stream.response.proto_major, stream.response.proto_minor)
    response_close && setheader(headers, "Connection", "close")
    mode = _server_stream_write_mode(stream)
    stream.write_mode = mode
    if mode == _ServerStreamWriteMode.NONE
        removeheader(headers, "Content-Length")
        removeheader(headers, "Transfer-Encoding")
    elseif mode == _ServerStreamWriteMode.FIXED
        if stream.response.content_length >= 0
            setheader(headers, "Content-Length", string(stream.response.content_length))
        end
    elseif mode == _ServerStreamWriteMode.CHUNKED
        removeheader(headers, "Content-Length")
        setheader(headers, "Transfer-Encoding", "chunked")
        _prepare_trailer_header!(headers, stream.response.trailers)
    else
        removeheader(headers, "Content-Length")
        removeheader(headers, "Transfer-Encoding")
    end
    io = IOBuffer()
    _write_status_line!(io, stream.response)
    _write_headers!(io, headers)
    write(io, "\r\n")
    _write_server_stream_bytes!(stream, take!(io); buffer=false)
    @atomic :release stream.response_started = true
    return nothing
end

function _server_startread(stream::Stream)::Request
    _require_server_stream(stream)
    return stream.request
end

function _maybe_write_continue!(stream::Stream)::Nothing
    _require_server_stream(stream)
    stream.request.proto_major == UInt8(2) && return nothing
    already_sent = @atomic :acquire stream.continue_sent
    already_sent && return nothing
    # We only acknowledge `Expect: 100-continue` once the handler actually tries
    # to consume the request body.
    headercontains(stream.request.headers, "Expect", "100-continue") || return nothing
    _request_body_fully_consumed(stream.request) && return nothing
    response = Response(
        100;
        proto_major=Int(stream.request.proto_major),
        proto_minor=Int(stream.request.proto_minor),
        content_length=0,
        request=stream.request,
    )
    _write_all_response!(stream.tracked.conn, response)
    @atomic :release stream.continue_sent = true
    return nothing
end

function _server_isopen(stream::Stream)::Bool
    _require_server_stream(stream)
    return !(@atomic :acquire stream.read_closed) || !(@atomic :acquire stream.write_closed)
end

function _server_eof(stream::Stream)::Bool
    _require_server_stream(stream)
    return _request_body_fully_consumed(stream.request)
end

function _server_readbytes!(stream::Stream, dest::AbstractVector{UInt8}, nb::Integer=length(dest))
    _require_server_stream(stream)
    nb >= 0 || throw(ArgumentError("nb must be >= 0"))
    nb == 0 && return 0
    nb <= length(dest) || throw(ArgumentError("nb must be <= length(dest)"))
    _maybe_write_continue!(stream)
    buf = Vector{UInt8}(undef, nb)
    n = body_read!(stream.request.body, buf)
    n == 0 && (@atomic :release stream.read_closed = true)
    n > 0 && copyto!(dest, 1, buf, 1, n)
    _request_body_fully_consumed(stream.request) && (@atomic :release stream.read_closed = true)
    return n
end

function _server_read(stream::Stream)::Vector{UInt8}
    _require_server_stream(stream)
    _maybe_write_continue!(stream)
    out = UInt8[]
    buf = Vector{UInt8}(undef, 16 * 1024)
    while true
        n = body_read!(stream.request.body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    @atomic :release stream.read_closed = true
    return out
end

function setstatus(stream::Stream, status::Integer)::Nothing
    _require_server_stream(stream)
    (@atomic :acquire stream.response_started) && throw(ArgumentError("cannot change status after response writing has started"))
    stream.response.status = Int(status)
    return nothing
end

function setheader(stream::Stream, key::AbstractString, value::AbstractString)::Nothing
    _require_server_stream(stream)
    (@atomic :acquire stream.response_started) && throw(ArgumentError("cannot change headers after response writing has started"))
    setheader(stream.response.headers, key, value)
    return nothing
end

function setheader(stream::Stream, header::Pair{<:AbstractString,<:AbstractString})::Nothing
    return setheader(stream, header.first, header.second)
end

function addtrailer(stream::Stream, trailers::Headers)::Nothing
    _require_server_stream(stream)
    for key in header_keys(trailers)
        values = headers(trailers, key)
        for value in values
            appendheader(stream.response.trailers, key, value)
        end
    end
    return nothing
end

function addtrailer(stream::Stream, header::Pair{<:AbstractString,<:AbstractString})::Nothing
    _require_server_stream(stream)
    appendheader(stream.response.trailers, header.first, header.second)
    return nothing
end

function addtrailer(stream::Stream, headers::AbstractVector{<:Pair})::Nothing
    for header in headers
        addtrailer(stream, header)
    end
    return nothing
end

function startwrite(stream::Stream)::Response
    _require_server_stream(stream)
    started = @atomic :acquire stream.response_started
    started && return stream.response
    !_request_body_fully_consumed(stream.request) && (stream.response.close = true)
    !_server_stream_allows_body(stream) && (stream.ignore_writes = true)
    if _server_stream_buffered_h2(stream)
        @atomic :release stream.response_started = true
        return stream.response
    end
    stream.write_mode = _server_stream_write_mode(stream)
    if stream.write_mode == _ServerStreamWriteMode.FIXED
        if stream.response.content_length < 0
            expected = _parse_content_length(stream.response.headers)
            expected >= 0 || throw(ProtocolError("fixed-length stream response is missing Content-Length"))
            stream.response.content_length = expected
        end
        @atomic :release stream.response_started = true
        return stream.response
    end
    _write_server_stream_head!(stream)
    return stream.response
end

function _server_write(stream::Stream, data::AbstractVector{UInt8})::Int
    _require_server_stream(stream)
    (@atomic :acquire stream.write_closed) && throw(ArgumentError("response writes are closed"))
    startwrite(stream)
    stream.ignore_writes && return length(data)
    if _server_stream_buffered_h2(stream) || stream.write_mode == _ServerStreamWriteMode.FIXED
        if stream.response.content_length >= 0 && (stream.written_bytes + length(data)) > stream.response.content_length
            throw(ProtocolError("response body bytes exceeded Content-Length"))
        end
        _write_server_stream_bytes!(stream, data)
        stream.written_bytes += length(data)
        return length(data)
    end
    if stream.write_mode == _ServerStreamWriteMode.CHUNKED
        io = IOBuffer()
        print(io, string(length(data), base=16), "\r\n")
        write(io, data)
        write(io, "\r\n")
        _write_server_stream_bytes!(stream, take!(io))
    else
        _write_server_stream_bytes!(stream, data)
    end
    stream.written_bytes += length(data)
    return length(data)
end

function _server_write(stream::Stream, data::Union{String,SubString{String}})::Int
    return _server_write(stream, Vector{UInt8}(codeunits(String(data))))
end

function _server_closewrite(stream::Stream)::Nothing
    _require_server_stream(stream)
    was_closed = @atomic :acquire stream.write_closed
    was_closed && return nothing
    startwrite(stream)
    if _server_stream_buffered_h2(stream)
        if stream.response.content_length >= 0 && stream.written_bytes != stream.response.content_length
            throw(ProtocolError("response body bytes did not match Content-Length"))
        end
        @atomic :release stream.write_closed = true
        return nothing
    end
    if stream.write_mode == _ServerStreamWriteMode.FIXED
        if stream.response.content_length >= 0 && stream.written_bytes != stream.response.content_length
            throw(ProtocolError("response body bytes did not match Content-Length"))
        end
        _write_server_stream_head!(stream)
        body_bytes = take!(stream.request_buffer)
        _write_server_stream_bytes!(stream, body_bytes; buffer=false)
    elseif stream.write_mode == _ServerStreamWriteMode.CHUNKED
        io = IOBuffer()
        write(io, "0\r\n")
        _write_headers!(io, stream.response.trailers)
        write(io, "\r\n")
        _write_server_stream_bytes!(stream, take!(io))
    end
    @atomic :release stream.write_closed = true
    return nothing
end

function _server_closeread(stream::Stream)::Response
    _require_server_stream(stream)
    already_closed = @atomic :acquire stream.read_closed
    already_closed && return stream.response
    if !_request_body_fully_consumed(stream.request)
        stream.response.close = true
        try
            body_close!(stream.request.body)
        catch
        end
    end
    @atomic :release stream.read_closed = true
    return stream.response
end

function _server_close(stream::Stream)::Nothing
    _require_server_stream(stream)
    try
        _server_closewrite(stream)
    catch
    end
    try
        _server_closeread(stream)
    catch
    end
    return nothing
end

function _write_response_body_to_stream!(stream::Stream, body)::Nothing
    body === nothing && return nothing
    if body isa EmptyBody
        return nothing
    end
    if body isa AbstractString
        write(stream, body::AbstractString)
        return nothing
    end
    if body isa AbstractVector{UInt8}
        write(stream, body::AbstractVector{UInt8})
        return nothing
    end
    if body isa AbstractBody
        buf = Vector{UInt8}(undef, 16 * 1024)
        try
            while true
                n = body_read!(body::AbstractBody, buf)
                n == 0 && break
                write(stream, @view(buf[1:n]))
            end
        finally
            try
                body_close!(body::AbstractBody)
            catch
            end
        end
        return nothing
    end
    throw(ProtocolError("unsupported stream response body type $(typeof(body))"))
end

struct _StreamHandlerAdapter{F}
    handler::F
end

function (adapter::_StreamHandlerAdapter)(stream::Stream)
    req = startread(stream)
    resp = adapter.handler(req)
    resp isa Response || throw(ProtocolError("streamhandler request handler must return HTTP.Response"))
    response = resp::Response
    response.request = req
    stream.response = response
    _write_response_body_to_stream!(stream, response.body)
    closewrite(stream)
    closeread(stream)
    return nothing
end

"""
    streamhandler(request_handler) -> stream handler

Adapter that takes a request handler and returns a stream handler.
"""
function streamhandler(handler)
    return _StreamHandlerAdapter(handler)
end

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
    headers_complete::Bool
    stream_done::Bool
    trailers_complete::Bool
    handler_started::Bool
    handler_finished::Bool
    aborted::Bool
    error::Union{Nothing,Exception}
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
        false,
        false,
        false,
        false,
        false,
        false,
        nothing,
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
    conn_error::Union{Nothing,Exception}
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
        nothing,
        false,
    )
end

mutable struct _H2ServerConnControl
    @atomic shutdown_requested::Bool
    @atomic goaway_sent::Bool
    @atomic graceful_last_stream_id::UInt32
end

function _H2ServerConnControl()
    return _H2ServerConnControl(false, false, UInt32(0))
end

mutable struct _H2ServerBody{C} <: AbstractBody
    conn::C
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

@inline function _h2_server_available_bytes(state::_H2ServerStreamState)::Int
    available = (length(state.body) - state.body_read_index) + 1
    return available > 0 ? available : 0
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

function _fail_h2_send_window_state!(send_state::_H2SendWindowState, err::Exception)::Nothing
    lock(send_state.state_lock)
    try
        send_state.conn_error === nothing && (send_state.conn_error = err)
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

function _reserve_h2_send_window!(send_state::_H2SendWindowState, stream_id::UInt32, wanted::Int)::Int
    wanted > 0 || throw(ArgumentError("wanted send window must be > 0"))
    lock(send_state.state_lock)
    try
        while true
            (@atomic :acquire send_state.closed) && throw(ProtocolError("HTTP/2 connection is closed"))
            send_state.conn_error === nothing || throw(send_state.conn_error::Exception)
            haskey(send_state.stream_send_window, stream_id) || throw(ProtocolError("HTTP/2 stream send window is closed"))
            stream_window = send_state.stream_send_window[stream_id]
            if stream_window <= 0 || send_state.conn_send_window <= 0
                wait(send_state.window_condition)
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
                wait(send_state.window_condition)
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
    nbytes::Int;
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

function _set_h2_server_stream_error!(
    state::_H2ServerStreamState,
    err::Exception;
    aborted::Bool=true,
    discard_body::Bool=true,
    finish_if_unstarted::Bool=false,
)::Nothing
    lock(state.lock)
    try
        state.error === nothing && (state.error = err)
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
    err::Exception,
)::Nothing
    snapshot = _H2ServerStreamState[]
    lock(states_lock)
    try
        append!(snapshot, values(states))
    finally
        unlock(states_lock)
    end
    for state in snapshot
        _set_h2_server_stream_error!(state, err; finish_if_unstarted=true)
        _unregister_h2_send_window!(send_state, state.stream_id)
    end
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
            body.state.error === nothing || throw(body.state.error::Exception)
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
        try
            _write_frame_h2_server_threadsafe!(body.write_lock, body.conn, RSTStreamFrame(body.stream_id, UInt32(0x8)))
        catch
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

function _append_h2_headers!(out::Vector{HeaderField}, hdrs::Headers)::Nothing
    for key in header_keys(hdrs)
        _skip_h2_header(key) && continue
        values = headers(hdrs, key)
        for value in values
            push!(out, HeaderField(lowercase(key), value, false))
        end
    end
    return nothing
end

const _H2_SERVER_MAX_DATA_FRAME_SIZE = 16_384

mutable struct _ServerPrefaceConn{C} <: IO
    prefix::Vector{UInt8}
    next::Int
    conn::C
end

function _ServerPrefaceConn(prefix::Vector{UInt8}, conn::C) where {C}
    return _ServerPrefaceConn{C}(prefix, 1, conn)
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

function _write_frame_h2_server!(conn::Union{TCP.Conn,TLS.Conn}, frame::AbstractFrame)::Nothing
    io = IOBuffer()
    framer = Framer(io)
    write_frame!(framer, frame)
    _write_all_h2_server!(conn, take!(io))
    return nothing
end

function _write_frame_h2_server_threadsafe!(write_lock::ReentrantLock, conn::Union{TCP.Conn,TLS.Conn}, frame::AbstractFrame)::Nothing
    lock(write_lock)
    try
        _write_frame_h2_server!(conn, frame)
    finally
        unlock(write_lock)
    end
    return nothing
end

function _write_data_frames_h2_server!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    data::Vector{UInt8};
    end_stream::Bool,
)::Nothing
    isempty(data) && return nothing
    offset = 1
    total_len = length(data)
    while offset <= total_len
        remaining = total_len - offset + 1
        chunk_len = _reserve_h2_send_window!(send_state, stream_id, remaining)
        chunk = Vector{UInt8}(undef, chunk_len)
        copyto!(chunk, 1, data, offset, chunk_len)
        final_chunk = (offset + chunk_len - 1) == total_len
        _write_frame_h2_server_threadsafe!(write_lock, conn, DataFrame(stream_id, end_stream && final_chunk, chunk))
        offset += chunk_len
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
    for header in headers
        name = header.name
        value = header.value
        name == lowercase(name) || throw(ProtocolError("HTTP/2 header field names must be lowercase"))
        if startswith(name, ':')
            saw_regular && throw(ProtocolError("HTTP/2 pseudo-headers must precede regular headers"))
            if name == ":method"
                method === nothing || throw(ProtocolError("duplicate HTTP/2 :method pseudo-header"))
                method = value
            elseif name == ":scheme"
                scheme === nothing || throw(ProtocolError("duplicate HTTP/2 :scheme pseudo-header"))
                scheme = value
            elseif name == ":path"
                path === nothing || throw(ProtocolError("duplicate HTTP/2 :path pseudo-header"))
                path = value
            elseif name == ":authority"
                authority === nothing || throw(ProtocolError("duplicate HTTP/2 :authority pseudo-header"))
                authority = value
            else
                throw(ProtocolError("unsupported HTTP/2 pseudo-header $(repr(name))"))
            end
            continue
        end
        saw_regular = true
        if name == "connection" || name == "proxy-connection" || name == "keep-alive" || name == "upgrade"
            throw(ProtocolError("forbidden HTTP/2 connection-specific header $(repr(name))"))
        end
        if name == "transfer-encoding"
            throw(ProtocolError("forbidden HTTP/2 transfer-encoding header"))
        end
        if name == "te"
            lowercase(_trim_http_ows(value)) == "trailers" || throw(ProtocolError("HTTP/2 TE header may only contain trailers"))
        end
        appendheader(out_headers, name, value)
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

function _decode_h2_request(headers::Vector{HeaderField}, body::AbstractBody; stream_done::Bool=false)::Request
    method, _scheme, path, authority, out_headers = _validate_h2_request_headers!(headers)
    target = method == "CONNECT" ? authority::String : (path::String)
    host = authority === nothing ? header(out_headers, "Host") : authority
    content_length = _parse_content_length(out_headers)
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
    return _decode_h2_request(headers, request_body; stream_done=true)
end

function _encode_h2_response_headers!(encoder::Encoder, response::Response; max_header_list_size::Int=0)::Vector{UInt8}
    header_fields = HeaderField[HeaderField(":status", string(response.status), false)]
    _append_h2_headers!(header_fields, response.headers)
    max_header_list_size > 0 && _header_list_size(header_fields) > max_header_list_size && throw(ProtocolError("HTTP/2 response headers exceed peer SETTINGS_MAX_HEADER_LIST_SIZE"))
    return encode_header_block(encoder, header_fields)
end

function _encode_h2_trailer_headers!(encoder::Encoder, trailers::Headers; max_header_list_size::Int=0)::Vector{UInt8}
    header_fields = HeaderField[]
    _append_h2_headers!(header_fields, trailers)
    max_header_list_size > 0 && _header_list_size(header_fields) > max_header_list_size && throw(ProtocolError("HTTP/2 response trailers exceed peer SETTINGS_MAX_HEADER_LIST_SIZE"))
    return encode_header_block(encoder, header_fields)
end

function _write_h2_header_block_locked!(
    conn::Union{TCP.Conn,TLS.Conn},
    stream_id::UInt32,
    header_block::Vector{UInt8};
    end_stream::Bool,
    max_frame_size::Int,
)::Nothing
    for frame in _header_block_frames(stream_id, end_stream, header_block, max_frame_size)
        _write_frame_h2_server!(conn, frame)
    end
    return nothing
end

function _write_h2_response_headers!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    response::Response;
    end_stream::Bool,
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
        header_block = _encode_h2_response_headers!(send_state.header_encoder, response; max_header_list_size=max_header_list_size)
        _write_h2_header_block_locked!(conn, stream_id, header_block; end_stream=end_stream, max_frame_size=max_frame_size)
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
        header_block = _encode_h2_trailer_headers!(send_state.header_encoder, trailers; max_header_list_size=max_header_list_size)
        _write_h2_header_block_locked!(conn, stream_id, header_block; end_stream=true, max_frame_size=max_frame_size)
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
    response::Response;
    end_stream::Bool=true,
)::Nothing
    response.body isa EmptyBody && return nothing
    buf = Vector{UInt8}(undef, 16 * 1024)
    pending = UInt8[]
    have_pending = false
    try
        while true
            n = body_read!(response.body, buf)
            if n == 0
                if have_pending
                    _write_data_frames_h2_server!(conn, write_lock, send_state, stream_id, pending; end_stream=end_stream)
                elseif end_stream
                    _write_frame_h2_server_threadsafe!(write_lock, conn, DataFrame(stream_id, true, UInt8[]))
                end
                return nothing
            end
            current = Vector{UInt8}(undef, n)
            copyto!(current, 1, buf, 1, n)
            if have_pending
                _write_data_frames_h2_server!(conn, write_lock, send_state, stream_id, pending; end_stream=false)
            end
            pending = current
            have_pending = true
        end
    finally
        try
            body_close!(response.body)
        catch
        end
    end
end

function _write_h2_response!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    request::Request,
    response::Response,
)::Nothing
    response.request = request
    allows_body = _h2_response_allows_body(request, response)
    has_trailers = !isempty(response.trailers)
    if !allows_body
        try
            body_close!(response.body)
        catch
        end
        _write_h2_response_headers!(conn, write_lock, send_state, stream_id, response; end_stream=!has_trailers)
        has_trailers && _write_h2_trailers!(conn, write_lock, send_state, stream_id, response.trailers)
        return nothing
    end
    body_empty = response.body isa EmptyBody
    end_stream = body_empty && !has_trailers
    _write_h2_response_headers!(conn, write_lock, send_state, stream_id, response; end_stream=end_stream)
    body_empty || _write_response_body_h2_server!(conn, write_lock, send_state, stream_id, response; end_stream=!has_trailers)
    has_trailers && _write_h2_trailers!(conn, write_lock, send_state, stream_id, response.trailers)
    return nothing
end

function _write_h2_buffered_stream_response!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state::_H2SendWindowState,
    stream_id::UInt32,
    request::Request,
    stream::Stream,
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
    _write_h2_response_headers!(conn, write_lock, send_state, stream_id, response; end_stream=end_stream)
    has_body && _write_data_frames_h2_server!(conn, write_lock, send_state, stream_id, body_bytes; end_stream=!has_trailers)
    has_trailers && _write_h2_trailers!(conn, write_lock, send_state, stream_id, response.trailers)
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
        request = _decode_h2_request(decoded_headers, request_body::AbstractBody; stream_done=stream_done)
        request.trailers = state.trailers
        lock(state.lock)
        try
            state.request = request
        finally
            unlock(state.lock)
        end
        if server.stream
            stream = Stream(request)
            try
                server.handler(stream)
                if !(@atomic :acquire stream.write_closed)
                    closewrite(stream)
                end
                closeread(stream)
            catch err
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
                closeread(stream)
            end
            _write_h2_buffered_stream_response!(conn, write_lock, send_state, stream_id, request, stream)
        else
            response = try
                server.handler(request)
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
                )
                return nothing
            end
            response isa Response || throw(ProtocolError("h2 server handler must return HTTP.Response"))
            response_obj = response::Response
            _write_h2_response!(conn, write_lock, send_state, stream_id, request, response_obj)
        end
        if request.body isa _H2ServerBody
            body = request.body::_H2ServerBody
            _request_body_fully_consumed(request) || body_close!(body)
        end
    catch err
        stream_cancelled = false
        lock(state.lock)
        try
            stream_cancelled = state.error !== nothing || state.aborted
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
    lock(state.lock)
    try
        state.handler_started && return nothing
        state.headers_complete || return nothing
        state.decoded_headers === nothing && throw(ProtocolError("HTTP/2 request missing decoded headers"))
        decoded_headers = copy(state.decoded_headers::Vector{HeaderField})
    finally
        unlock(state.lock)
    end
    _validate_h2_request_headers!(decoded_headers::Vector{HeaderField})
    lock(state.lock)
    try
        state.handler_started && return nothing
        state.handler_started = true
    finally
        unlock(state.lock)
    end
    errormonitor(Threads.@spawn _handle_h2_stream!(server, tracked, conn, write_lock, send_state, states_lock, states, state.stream_id, state, decoded_headers::Vector{HeaderField}))
    return nothing
end

function _try_write_h2_goaway!(
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    last_stream_id::UInt32,
    error_code::UInt32,
)::Nothing
    try
        _write_frame_h2_server_threadsafe!(write_lock, conn, GoAwayFrame(last_stream_id, error_code, UInt8[]))
    catch
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
    reader = Framer(_ConnReader(reader_source))
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
    close_err = nothing
    goaway_error_code = nothing
    try
        preface = _read_exact_h2_server!(reader_source, length(_H2_PREFACE))
        preface == _H2_PREFACE || throw(ProtocolError("invalid h2 client preface"))
        client_settings = read_frame!(reader)
        client_settings isa SettingsFrame || throw(ProtocolError("expected initial h2 SETTINGS frame"))
        (client_settings::SettingsFrame).ack && throw(ProtocolError("initial h2 SETTINGS frame must not be ACK"))
        _apply_h2_peer_settings!(send_state, write_lock, (client_settings::SettingsFrame).settings)
        _write_frame_h2_server_threadsafe!(write_lock, conn, SettingsFrame(false, Pair{UInt16,UInt32}[]))
        _write_frame_h2_server_threadsafe!(write_lock, conn, SettingsFrame(true, Pair{UInt16,UInt32}[]))
        _set_conn_shutdown_hook!(tracked, () -> _request_h2_conn_shutdown!(conn, write_lock, conn_control))
        _set_conn_state!(tracked, _ConnState.IDLE)
        while true
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
                    _write_frame_h2_server_threadsafe!(write_lock, conn, SettingsFrame(true, Pair{UInt16,UInt32}[]))
                end
                continue
            end
            if frame isa PingFrame
                ping = frame::PingFrame
                ping.ack || _write_frame_h2_server_threadsafe!(write_lock, conn, PingFrame(true, ping.opaque_data))
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
                _set_h2_server_stream_error!(state, ProtocolError("HTTP/2 stream reset by peer"); finish_if_unstarted=true)
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
                lock(state.lock)
                try
                    initial_headers = !state.headers_complete
                    if !initial_headers
                        state.stream_done && throw(ProtocolError("unexpected additional HTTP/2 HEADERS on request stream"))
                        state.trailers_complete && throw(ProtocolError("unexpected additional HTTP/2 HEADERS on request stream"))
                        hf.end_stream || throw(ProtocolError("HTTP/2 request trailers must end the stream"))
                    end
                    remaining = max_header_block_bytes - length(state.header_block)
                    remaining >= 0 && length(hf.header_block_fragment) <= remaining || throw(ProtocolError("HTTP/2 request header block exceeded maximum size"))
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
                    hf.end_stream && (state.stream_done = true)
                    notify(state.condition)
                finally
                    unlock(state.lock)
                end
                _update_h2_server_conn_state!(tracked, states_lock, states)
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
                    remaining >= 0 && length(cf.header_block_fragment) <= remaining || throw(ProtocolError("HTTP/2 request header block exceeded maximum size"))
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
                lock(state.lock)
                try
                    state.headers_complete || throw(ProtocolError("DATA frame received before END_HEADERS"))
                    if state.aborted
                        df.end_stream && (state.stream_done = true)
                        notify(state.condition)
                    else
                        available_after = _h2_server_available_bytes(state) + length(df.data)
                        available_after <= state.max_buffered_bytes || throw(ProtocolError("HTTP/2 request body exceeded buffered server limit"))
                        append!(state.body, df.data)
                        df.end_stream && (state.stream_done = true)
                        notify(state.condition)
                    end
                finally
                    unlock(state.lock)
                end
                if state.aborted
                    _send_h2_server_window_updates!(conn, write_lock, df.stream_id, length(df.data); stream_level=false)
                    _maybe_cleanup_h2_server_state!(tracked, states_lock, states, state, send_state)
                end
                continue
            end
        end
    catch err
        if err isa ProtocolError || err isa ParseError
            close_err = err
            goaway_error_code = UInt32(0x1)
            return nothing
        end
        if err isa EOFError || err isa IOPoll.NetClosingError || err isa TLS.TLSError
            close_err = err isa EOFError ? ProtocolError("HTTP/2 connection is closed") : err
            return nothing
        end
        close_err = err
        rethrow(err)
    finally
        fail_err = close_err === nothing ? ProtocolError("HTTP/2 connection is closed") : (close_err::Exception)
        goaway_error_code === nothing || _try_write_h2_goaway!(conn, write_lock, max_stream_id, goaway_error_code::UInt32)
        _fail_h2_send_window_state!(send_state, fail_err)
        _fail_h2_server_streams!(states_lock, states, send_state, fail_err)
        _set_conn_shutdown_hook!(tracked, nothing)
        _clear_deadlines!(conn)
        _close_server_conn!(tracked)
        _untrack_conn!(server, tracked)
    end
    return nothing
end

function _serve_conn!(server::Server, tracked::_ServerConn)::Nothing
    entered_helper = false
    try
        conn = tracked.conn
        if conn isa TLS.Conn
            _set_read_deadline_for_header!(server, conn::TLS.Conn)
            # TLS needs an explicit handshake here so ALPN can pick h2 vs h1
            # before any HTTP parser commits to a protocol.
            TLS.handshake!(conn::TLS.Conn)
            proto = TLS.connection_state(conn::TLS.Conn).alpn_protocol
            entered_helper = true
            if proto == "h2"
                return _serve_h2_conn!(server, tracked, conn::TLS.Conn)
            end
            return _serve_h1_conn!(server, tracked, conn::TLS.Conn)
        end
        use_h2, reader_source = _probe_h2_preface!(server, conn::TCP.Conn)
        entered_helper = true
        if use_h2
            return _serve_h2_conn!(server, tracked, reader_source)
        end
        return _serve_h1_conn!(server, tracked, reader_source)
    catch err
        if err isa IOPoll.DeadlineExceededError
            _try_write_server_error!(tracked.conn, nothing, 408)
            return nothing
        end
        if err isa ParseError || err isa ProtocolError || err isa EOFError || err isa IOPoll.DeadlineExceededError || err isa IOPoll.NetClosingError || err isa TLS.TLSError || err isa TLS.TLSHandshakeTimeoutError || _is_connection_reset_error(err::Exception)
            return nothing
        end
        rethrow(err)
    finally
        if !entered_helper
            _clear_deadlines!(tracked.conn)
            _close_server_conn!(tracked)
            _untrack_conn!(server, tracked)
        end
    end
end

function _serve_h1_conn!(server::Server, tracked::_ServerConn, reader_source)::Nothing
    reader = _ConnReader(reader_source)
    try
        while true
            _server_shutting_down(server) && return nothing
            _set_read_deadline_for_header!(server, tracked.conn)
            request = try
                read_request(reader; max_header_bytes=server.max_header_bytes)
            catch err
                status = _server_error_status(err::Exception)
                status === nothing || _try_write_server_error!(tracked.conn, nothing, status::Int)
                if err isa ParseError || err isa ProtocolError || err isa EOFError || err isa IOPoll.DeadlineExceededError || err isa IOPoll.NetClosingError || err isa TLS.TLSError || err isa TLS.TLSHandshakeTimeoutError || _is_connection_reset_error(err::Exception)
                    return nothing
                end
                rethrow(err)
            end
            _set_conn_state!(tracked, _ConnState.ACTIVE)
            if _request_has_unsupported_expect(request)
                _try_write_server_error!(tracked.conn, request, 417)
                return nothing
            end
            _set_read_deadline_for_body!(server, tracked.conn)
            if server.stream
                stream = Stream(server, tracked, request)
                try
                    server.handler(stream)
                    if !(@atomic :acquire stream.write_closed)
                        closewrite(stream)
                    end
                    closeread(stream)
                    _clear_deadlines!(tracked.conn)
                    _server_shutting_down(server) && return nothing
                    if _request_wants_close(request) || _response_wants_close(stream.response)
                        return nothing
                    end
                catch err
                    status = _server_error_status(err::Exception)
                    if !(@atomic :acquire stream.response_started)
                        try
                            setstatus(stream, status === nothing ? 500 : status::Int)
                            stream.response.close = true
                            startwrite(stream)
                            closewrite(stream)
                        catch
                        end
                    end
                    try
                        stream.response.close = true
                        close(stream)
                    catch
                    end
                    return nothing
                end
            else
                response = try
                    server.handler(request)
                catch err
                    status = _server_error_status(err::Exception)
                    _try_write_server_error!(tracked.conn, request, status === nothing ? 500 : status::Int)
                    return nothing
                end
                response isa Response || throw(ProtocolError("server handler must return HTTP.Response"))
                response_obj = response::Response
                response_obj.request = request
                if !_request_body_fully_consumed(request)
                    response_obj.close = true
                    try
                        body_close!(request.body)
                    catch
                    end
                end
                _set_write_deadline!(server, tracked.conn)
                _write_all_response!(tracked.conn, response_obj)
                _clear_deadlines!(tracked.conn)
                _server_shutting_down(server) && return nothing
                if _request_wants_close(request) || _response_wants_close(response_obj)
                    return nothing
                end
            end
            _set_conn_state!(tracked, _ConnState.IDLE)
            _set_idle_deadline!(server, tracked.conn)
        end
    finally
        _clear_deadlines!(tracked.conn)
        _close_server_conn!(tracked)
        _untrack_conn!(server, tracked)
    end
    return nothing
end

function _serve_listener!(server::Server, listener::Union{TCP.Listener,TLS.Listener})
    _server_shutting_down(server) && throw(ProtocolError("server is shutting down"))
    lock(server.lock)
    try
        server.listener = listener
        server.bound_address, server.bound_port = _listener_bound_address(listener)
    finally
        unlock(server.lock)
    end
    _set_server_state!(server, _ServerState.RUNNING)
    while true
        _server_shutting_down(server) && return nothing
        conn = try
            _accept_server_conn!(listener)
        catch err
            if _server_shutting_down(server)
                return nothing
            end
            if err isa IOPoll.NetClosingError || err isa EOFError
                return nothing
            end
            rethrow(err)
        end
        tracked = _ServerConn(conn, ReentrantLock(), nothing, _ConnState.NEW, floor(Int64, time()))
        _track_conn!(server, tracked)
        errormonitor(Threads.@spawn _serve_conn!(server, tracked))
    end
    return nothing
end

function _run_server!(server::Server)
    listener = TCP.listen(
        server.network, _listen_address(server); backlog=server.backlog, reuseaddr=server.reuseaddr,
    )
    try
        _serve_listener!(server, listener)
    finally
        try
            TCP.close(listener)
        catch
        end
    end
    return nothing
end

"""
    listen!(server) -> Server

Start a configured `Server` asynchronously and return it.
"""
function listen!(server::Server)::Server
    state = _server_state(server)
    state == _ServerState.CLOSED && throw(ProtocolError("closed servers cannot be restarted"))
    state == _ServerState.RUNNING && throw(ProtocolError("server is already running"))
    task = errormonitor(Threads.@spawn _run_server!(server))
    lock(server.lock)
    try
        server.serve_task = task
    finally
        unlock(server.lock)
    end
    return server
end

"""
    listen!(handler, host="127.0.0.1", port=8080;
            read_timeout_ns=0, read_header_timeout_ns=0, write_timeout_ns=0,
            idle_timeout_ns=0, max_header_bytes=1*1024*1024,
            listenany=false, reuseaddr=true, backlog=128) -> Server
    listen!(handler, port; kwargs...) -> Server
    listen!(handler, listener; kwargs...) -> Server

Start a streaming HTTP server and return the running `Server`.

`handler` is called with an `HTTP.Stream` and is responsible for reading the
request and writing the response.
"""
function listen!(
    handler::F, host::AbstractString="127.0.0.1", port_num::Integer=8080;
    read_timeout_ns::Integer=Int64(0),
    read_header_timeout_ns::Integer=Int64(0),
    write_timeout_ns::Integer=Int64(0),
    idle_timeout_ns::Integer=Int64(0),
    max_header_bytes::Integer=1 * 1024 * 1024,
    listenany::Bool=false,
    reuseaddr::Bool=true,
    backlog::Integer=128,
) where {F}
    return listen!(Server(
        network="tcp",
        address=HostResolvers.join_host_port(host, Int(port_num)),
        handler=handler,
        stream=true,
        read_timeout_ns=read_timeout_ns,
        read_header_timeout_ns=read_header_timeout_ns,
        write_timeout_ns=write_timeout_ns,
        idle_timeout_ns=idle_timeout_ns,
        max_header_bytes=max_header_bytes,
        listenany=listenany,
        reuseaddr=reuseaddr,
        backlog=backlog,
    ))
end

function listen!(
    handler::F, port_num::Integer;
    read_timeout_ns::Integer=Int64(0),
    read_header_timeout_ns::Integer=Int64(0),
    write_timeout_ns::Integer=Int64(0),
    idle_timeout_ns::Integer=Int64(0),
    max_header_bytes::Integer=1 * 1024 * 1024,
    listenany::Bool=false,
    reuseaddr::Bool=true,
    backlog::Integer=128,
) where {F}
    return listen!(
        handler,
        "127.0.0.1",
        port_num;
        read_timeout_ns=read_timeout_ns,
        read_header_timeout_ns=read_header_timeout_ns,
        write_timeout_ns=write_timeout_ns,
        idle_timeout_ns=idle_timeout_ns,
        max_header_bytes=max_header_bytes,
        listenany=listenany,
        reuseaddr=reuseaddr,
        backlog=backlog,
    )
end

function listen!(
    handler::F, listener::Union{TCP.Listener,TLS.Listener};
    read_timeout_ns::Integer=Int64(0),
    read_header_timeout_ns::Integer=Int64(0),
    write_timeout_ns::Integer=Int64(0),
    idle_timeout_ns::Integer=Int64(0),
    max_header_bytes::Integer=1 * 1024 * 1024,
    listenany::Bool=false,
    reuseaddr::Bool=true,
    backlog::Integer=128,
) where {F}
    listenany && throw(ArgumentError("listenany is not valid when passing an existing listener"))
    _ = reuseaddr
    _ = backlog
    bound_address, bound_port = _listener_bound_address(listener)
    server = Server(
        network="tcp",
        address=bound_address,
        handler=handler,
        stream=true,
        read_timeout_ns=read_timeout_ns,
        read_header_timeout_ns=read_header_timeout_ns,
        write_timeout_ns=write_timeout_ns,
        idle_timeout_ns=idle_timeout_ns,
        max_header_bytes=max_header_bytes,
        listenany=false,
        reuseaddr=reuseaddr,
        backlog=backlog,
    )
    server.bound_address = bound_address
    server.bound_port = bound_port
    task = errormonitor(Threads.@spawn _serve_listener!(server, listener))
    lock(server.lock)
    try
        server.serve_task = task
    finally
        unlock(server.lock)
    end
    return server
end

"""
    listen(handler, args...; kwargs...)

Run `listen!` in the foreground, blocking until the server is closed.
"""
function listen(handler::F, args...; kwargs...) where {F}
    server = listen!(handler, args...; kwargs...)
    try
        wait(server)
    finally
        try
            close(server)
        catch
        end
    end
    return server
end

"""
    serve!(handler, host="127.0.0.1", port=8080;
           stream=false, read_timeout_ns=0, read_header_timeout_ns=0,
           write_timeout_ns=0, idle_timeout_ns=0,
           max_header_bytes=1*1024*1024, listenany=false, reuseaddr=true,
           backlog=128) -> Server
    serve!(handler, port; kwargs...) -> Server
    serve!(handler, listener; kwargs...) -> Server

Start an HTTP server and return the running `Server`.

By default `handler` is called with an `HTTP.Request` and must return an
`HTTP.Response`. Pass `stream=true` to use the lower-level `HTTP.Stream`
handler path instead.
"""
function serve!(
    handler::F, args...;
    stream::Bool=false,
    read_timeout_ns::Integer=Int64(0),
    read_header_timeout_ns::Integer=Int64(0),
    write_timeout_ns::Integer=Int64(0),
    idle_timeout_ns::Integer=Int64(0),
    max_header_bytes::Integer=1 * 1024 * 1024,
    listenany::Bool=false,
    reuseaddr::Bool=true,
    backlog::Integer=128,
) where {F}
    if stream
        return listen!(
            handler,
            args...;
            read_timeout_ns=read_timeout_ns,
            read_header_timeout_ns=read_header_timeout_ns,
            write_timeout_ns=write_timeout_ns,
            idle_timeout_ns=idle_timeout_ns,
            max_header_bytes=max_header_bytes,
            listenany=listenany,
            reuseaddr=reuseaddr,
            backlog=backlog,
        )
    end
    if length(args) == 1 && args[1] isa Union{TCP.Listener,TLS.Listener}
        listener = args[1]::Union{TCP.Listener,TLS.Listener}
        bound_address, bound_port = _listener_bound_address(listener)
        server = Server(
            network="tcp",
            address=bound_address,
            handler=handler,
            stream=false,
            read_timeout_ns=read_timeout_ns,
            read_header_timeout_ns=read_header_timeout_ns,
            write_timeout_ns=write_timeout_ns,
            idle_timeout_ns=idle_timeout_ns,
            max_header_bytes=max_header_bytes,
            listenany=false,
            reuseaddr=reuseaddr,
            backlog=backlog,
        )
        server.bound_address = bound_address
        server.bound_port = bound_port
        task = errormonitor(Threads.@spawn _serve_listener!(server, listener))
        lock(server.lock)
        try
            server.serve_task = task
        finally
            unlock(server.lock)
        end
        return server
    end
    host, port_num = if length(args) == 1 && args[1] isa Integer
        ("127.0.0.1", Int(args[1]::Integer))
    elseif length(args) == 2 && args[1] isa AbstractString && args[2] isa Integer
        (args[1]::AbstractString, Int(args[2]::Integer))
    else
        throw(ArgumentError("serve! expects host/port, port, or existing listener"))
    end
    return listen!(Server(
        network="tcp",
        address=HostResolvers.join_host_port(host, port_num),
        handler=handler,
        stream=false,
        read_timeout_ns=read_timeout_ns,
        read_header_timeout_ns=read_header_timeout_ns,
        write_timeout_ns=write_timeout_ns,
        idle_timeout_ns=idle_timeout_ns,
        max_header_bytes=max_header_bytes,
        listenany=listenany,
        reuseaddr=reuseaddr,
        backlog=backlog,
    ))
end

"""
    serve(handler, args...; kwargs...)

Run `serve!` in the foreground, blocking until the server is closed.
"""
function serve(
    handler::F,
    args...;
    stream::Bool=false,
    read_timeout_ns::Integer=Int64(0),
    read_header_timeout_ns::Integer=Int64(0),
    write_timeout_ns::Integer=Int64(0),
    idle_timeout_ns::Integer=Int64(0),
    max_header_bytes::Integer=1 * 1024 * 1024,
    listenany::Bool=false,
    reuseaddr::Bool=true,
    backlog::Integer=128,
) where {F}
    server = serve!(
        handler,
        args...;
        stream=stream,
        read_timeout_ns=read_timeout_ns,
        read_header_timeout_ns=read_header_timeout_ns,
        write_timeout_ns=write_timeout_ns,
        idle_timeout_ns=idle_timeout_ns,
        max_header_bytes=max_header_bytes,
        listenany=listenany,
        reuseaddr=reuseaddr,
        backlog=backlog,
    )
    try
        wait(server)
    finally
        try
            close(server)
        catch
        end
    end
    return server
end
