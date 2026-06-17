# Shared HTTP server kernel for HTTP/1, TLS, and HTTP/2.

using Dates
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

Timeout fields are stored in nanoseconds. Use the convenience `listen!` and
`serve!` keywords to configure request-read, header-read, response-write, and
idle deadlines without constructing a `Server` manually.

HTTP/2 receive flow control is configurable through the `http2_settings` keyword,
an [`HTTP2Settings`](@ref) carrying the per-stream and connection-level receive
windows. It defaults to the protocol defaults so existing behavior is unchanged.
Raising the windows improves single-stream throughput on links with non-trivial
latency, where the default 64 KiB window would otherwise cap a transfer at roughly
`window / RTT`.
"""
# Default ceiling on the number of HTTP/2 streams a single connection may have
# open concurrently. RFC 9113 §6.5.2 recommends a value no smaller than 100 so
# that legitimate multiplexing keeps working; it is advertised to the peer via
# SETTINGS_MAX_CONCURRENT_STREAMS and enforced per connection in http2_server.jl.
# A value <= 0 disables the cap (legacy "unlimited" behavior).
const _H2_DEFAULT_MAX_CONCURRENT_STREAMS = 100

# Default cap for request bodies that the ordinary `serve!` path buffers before
# dispatching to a Request handler. Set `max_body_bytes=0` to opt back into the
# legacy unbounded buffering behavior, or use `listen!`/stream handlers for
# application-managed large uploads.
const _SERVER_DEFAULT_MAX_BODY_BYTES = Int64(64 * 1024 * 1024)

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
    max_body_bytes::Int64
    http2_settings::HTTP2Settings
    max_concurrent_streams::Int
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
    max_body_bytes::Integer=_SERVER_DEFAULT_MAX_BODY_BYTES,
    http2_settings::HTTP2Settings=HTTP2Settings(),
    max_concurrent_streams::Integer=_H2_DEFAULT_MAX_CONCURRENT_STREAMS,
    listenany::Bool=false,
    reuseaddr::Bool=true,
    backlog::Integer=128,
) where {F}
    read_timeout_ns >= 0 || throw(ArgumentError("read_timeout_ns must be >= 0"))
    read_header_timeout_ns >= 0 || throw(ArgumentError("read_header_timeout_ns must be >= 0"))
    write_timeout_ns >= 0 || throw(ArgumentError("write_timeout_ns must be >= 0"))
    idle_timeout_ns >= 0 || throw(ArgumentError("idle_timeout_ns must be >= 0"))
    max_header_bytes > 0 || throw(ArgumentError("max_header_bytes must be > 0"))
    max_body_bytes >= 0 || throw(ArgumentError("max_body_bytes must be >= 0"))
    # `max_concurrent_streams <= 0` disables the HTTP/2 concurrent-stream cap
    # (the legacy RFC-default "unlimited" behavior); positive values are
    # advertised via SETTINGS_MAX_CONCURRENT_STREAMS and enforced per connection.
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
        Int64(max_body_bytes),
        http2_settings,
        Int(max_concurrent_streams),
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

"""
    Stream

Bidirectional HTTP stream used by `listen!`, `serve!`, `HTTP.open`, and
stream-oriented request/response handlers.

Server-side streams expose request metadata through `startread(stream)` and let
handlers consume request bytes from the stream directly before writing a
response. Client-side streams let callers write a request body first, then
switch to reading the response head/body from the same object.
"""
mutable struct Stream{ISCLIENT,Req<:Request} <: IO
    parsed::Union{Nothing,_URLParts}
    client::Union{Nothing,Client}
    owns_client::Bool
    proxy_config::ProxyConfig
    cookies::Union{Bool,Vector{Cookie}}
    cookiejar::Union{Nothing,CookieJar}
    redirect::Bool
    redirect_policy::Union{Nothing,_RedirectPolicy}
    protocol::Symbol
    decompress::Union{Nothing,Bool}
    request_timeout_ns::Int64
    timeout_config::Union{Nothing,_RequestTimeoutConfig}
    retry_controller::Union{Nothing,_RetryController}
    request_buffer::IOBuffer
    response::Union{Nothing,Response}
    reader::Union{Nothing,IO}
    producer::Union{Nothing,Task}
    server::Union{Nothing,Server}
    tracked::Union{Nothing,_ServerConn}
    message::Req
    request_body::AbstractBody
    request_body_content_length::Int64
    h2_conn::Union{Nothing,TCP.Conn,TLS.Conn}
    h2_write_lock::Union{Nothing,ReentrantLock}
    h2_send_state::Any
    h2_stream_id::UInt32
    @atomic started::Bool
    @atomic write_closed::Bool
    @atomic read_closed::Bool
    @atomic response_started::Bool
    # `response_started` flips at `startwrite` even when the response head is
    # deferred (h1 FIXED mode); `head_committed` flips only when head bytes have
    # actually been written to the transport, so error paths can tell whether a
    # raw error response is still possible (#1303).
    @atomic head_committed::Bool
    @atomic continue_sent::Bool
    ignore_writes::Bool
    write_mode::_ServerStreamWriteMode.T
    written_bytes::Int64
end

function _stream_request_metadata(request::Request)::Request{EmptyBody}
    return Request(
        request.method,
        request.target;
        headers=request.headers,
        trailers=request.trailers,
        body=EmptyBody(),
        host=request.host,
        content_length=request.content_length,
        proto_major=Int(request.proto_major),
        proto_minor=Int(request.proto_minor),
        close=request.close,
        context=get_request_context(request),
    )
end

function Stream(server::Server, tracked::_ServerConn, request::Req) where {Req<:Request}
    message = _stream_request_metadata(request)
    response = Response(
        200;
        proto_major=Int(message.proto_major),
        proto_minor=Int(message.proto_minor),
        request=message,
    )
    response.content_length = -1
    body = request.body
    return Stream{false,typeof(message)}(
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
        Int64(0),
        nothing,
        nothing,
        IOBuffer(),
        response,
        nothing,
        nothing,
        server,
        tracked,
        message,
        body,
        request.content_length,
        nothing,
        nothing,
        nothing,
        UInt32(0),
        false,
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

function Stream(request::Req) where {Req<:Request}
    message = _stream_request_metadata(request)
    response = Response(
        200;
        proto_major=Int(message.proto_major),
        proto_minor=Int(message.proto_minor),
        request=message,
    )
    response.content_length = -1
    body = request.body
    return Stream{false,typeof(message)}(
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
        Int64(0),
        nothing,
        nothing,
        IOBuffer(),
        response,
        nothing,
        nothing,
        nothing,
        nothing,
        message,
        body,
        request.content_length,
        nothing,
        nothing,
        nothing,
        UInt32(0),
        false,
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

function Stream(
    server::Server,
    tracked::_ServerConn,
    conn::Union{TCP.Conn,TLS.Conn},
    write_lock::ReentrantLock,
    send_state,
    stream_id::UInt32,
    request::Req,
) where {Req<:Request}
    message = _stream_request_metadata(request)
    response = Response(
        200;
        proto_major=2,
        proto_minor=0,
        request=message,
    )
    response.content_length = -1
    body = request.body
    return Stream{false,typeof(message)}(
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
        Int64(0),
        nothing,
        nothing,
        IOBuffer(),
        response,
        nothing,
        nothing,
        server,
        tracked,
        message,
        body,
        request.content_length,
        conn,
        write_lock,
        send_state,
        stream_id,
        false,
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

@inline _require_server_stream(::Stream{false}) = nothing
@inline _require_server_stream(::Stream{true}) = throw(ArgumentError("operation is only valid for server-side HTTP streams"))

@inline function _server_stream_buffered_h2(stream::Stream)::Bool
    _require_server_stream(stream)
    request = stream.message
    return stream.server === nothing && stream.tracked === nothing && request.proto_major == UInt8(2)
end

@inline function _server_stream_live_h2(stream::Stream)::Bool
    _require_server_stream(stream)
    return stream.h2_conn !== nothing && stream.h2_write_lock !== nothing && stream.h2_send_state !== nothing && stream.h2_stream_id != UInt32(0)
end

@inline function _server_stream_buffered_fixed_h1(stream::Stream)::Bool
    _require_server_stream(stream)
    return !(_server_stream_buffered_h2(stream) || _server_stream_live_h2(stream)) && stream.write_mode == _ServerStreamWriteMode.FIXED
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
    if laddr isa TCP.SocketAddrV4
        addr = laddr::TCP.SocketAddrV4
        return (string(addr), Int(addr.port))
    end
    addr = laddr::TCP.SocketAddrV6
    return (string(addr), Int(addr.port))
end

function _mark_server_listening!(server::Server, listener::Union{TCP.Listener,TLS.Listener})::Nothing
    bound_address, bound_port = _listener_bound_address(listener)
    lock(server.lock)
    try
        server.listener = listener
        server.bound_address = bound_address
        server.bound_port = bound_port
    finally
        unlock(server.lock)
    end
    _set_server_state!(server, _ServerState.RUNNING)
    return nothing
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
    @try_ignore begin
        _close_server_transport!(tracked.conn)
    end
    return nothing
end

@inline function _finalize_server_conn!(server::Server, tracked::_ServerConn)::Nothing
    _clear_deadlines!(server, tracked.conn)
    _close_server_conn!(tracked)
    _untrack_conn!(server, tracked)
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
    @try_ignore begin
        _close_server_listener!(listener::Union{TCP.Listener,TLS.Listener})
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
        IOPoll.sleep(poll_s)
        poll_s < 0.5 && (poll_s = min(poll_s * 2, 0.5))
    end
    _set_server_state!(server, _ServerState.CLOSED)
    return nothing
end

@inline function _deadline_after(timeout_ns::Int64)::Int64
    timeout_ns <= 0 && return Int64(0)
    return Int64(time_ns()) + timeout_ns
end

@inline function _server_write_deadline_ns(server::Server)::Int64
    return _deadline_after(server.write_timeout_ns)
end

function _set_read_deadline_for_header!(server::Server, conn::Union{TCP.Conn,TLS.Conn})::Nothing
    timeout = server.read_header_timeout_ns > 0 ? server.read_header_timeout_ns : server.read_timeout_ns
    timeout <= 0 && return nothing
    _set_read_deadline!(conn, _deadline_after(timeout))
    return nothing
end

function _set_read_deadline_for_body!(server::Server, conn::Union{TCP.Conn,TLS.Conn})::Nothing
    timeout = server.read_timeout_ns
    timeout <= 0 && return nothing
    _set_read_deadline!(conn, _deadline_after(timeout))
    return nothing
end

function _set_idle_deadline!(server::Server, conn::Union{TCP.Conn,TLS.Conn})::Nothing
    timeout = server.idle_timeout_ns > 0 ? server.idle_timeout_ns : server.read_timeout_ns
    timeout <= 0 && return nothing
    _set_read_deadline!(conn, _deadline_after(timeout))
    return nothing
end

function _set_write_deadline!(server::Server, conn::Union{TCP.Conn,TLS.Conn})::Nothing
    server.write_timeout_ns > 0 || return nothing
    _set_write_deadline!(conn, _deadline_after(server.write_timeout_ns))
    return nothing
end

@inline function _server_has_any_timeouts(server::Server)::Bool
    return server.read_timeout_ns > 0 ||
           server.read_header_timeout_ns > 0 ||
           server.write_timeout_ns > 0 ||
           server.idle_timeout_ns > 0
end

function _clear_deadlines!(server::Server, conn::Union{TCP.Conn,TLS.Conn})::Nothing
    _server_has_any_timeouts(server) || return nothing
    @try_ignore begin
        _set_deadline!(conn, Int64(0))
    end
    return nothing
end

function _clear_deadlines!(conn::Union{TCP.Conn,TLS.Conn})::Nothing
    @try_ignore begin
        _set_deadline!(conn, Int64(0))
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

@inline function _server_body_too_large_error(max_body_bytes::Integer)::ProtocolError
    return ProtocolError("HTTP request body exceeds configured max_body_bytes=$(Int64(max_body_bytes))", _PROTOCOL_ERROR_BODY_TOO_LARGE)
end

@inline function _check_server_body_size!(received::Int64, max_body_bytes::Int64)::Nothing
    max_body_bytes > 0 && received > max_body_bytes && throw(_server_body_too_large_error(max_body_bytes))
    return nothing
end

function _read_all_server_request_body(body::AbstractBody, max_body_bytes::Integer)::Vector{UInt8}
    limit = Int64(max_body_bytes)
    limit >= 0 || throw(ArgumentError("max_body_bytes must be >= 0"))
    body isa EmptyBody && return UInt8[]
    if body isa BytesBody
        body_bytes = _remaining_bytes_body(body::BytesBody)
        _check_server_body_size!(Int64(length(body_bytes)), limit)
        return body_bytes
    end
    out = IOBuffer()
    buf = Vector{UInt8}(undef, 16 * 1024)
    received = Int64(0)
    while true
        n = body_read!(body, buf)
        n == 0 && break
        received += Int64(n)
        _check_server_body_size!(received, limit)
        write(out, @view(buf[1:n]))
    end
    return take!(out)
end

function _buffer_server_request(request::Request, max_body_bytes::Integer; close_body_on_error::Bool=true)::Request
    body = request.body
    body isa EmptyBody && return request
    limit = Int64(max_body_bytes)
    limit >= 0 || throw(ArgumentError("max_body_bytes must be >= 0"))
    body_bytes = try
        if request.content_length >= 0
            _check_server_body_size!(Int64(request.content_length), limit)
        end
        _read_all_server_request_body(body, limit)
    catch
        close_body_on_error && @try_ignore body_close!(body)
        rethrow()
    end
    @try_ignore body_close!(body)
    buffered_body = isempty(body_bytes) ? EmptyBody() : BytesBody(body_bytes)
    return Request(
        request.method,
        request.target;
        headers=request.headers,
        trailers=request.trailers,
        body=buffered_body,
        host=request.host,
        content_length=length(body_bytes),
        proto_major=Int(request.proto_major),
        proto_minor=Int(request.proto_minor),
        close=request.close,
        context=get_request_context(request),
    )
end

@inline function _request_body_fully_consumed(request::Request)::Bool
    body = request.body
    body isa EmptyBody && return true
    body isa BytesBody && return true
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

@inline function _stream_request_body_fully_consumed(stream::Stream)::Bool
    body = stream.request_body
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

@inline function _stream_request_body_read!(stream::Stream, dst::Vector{UInt8})::Int
    body = stream.request_body
    body isa EmptyBody && return 0
    if body isa _H2ServerBody
        return body_read!(body::_H2ServerBody, dst)
    end
    if body isa FixedLengthBody
        return body_read!(body::FixedLengthBody, dst)
    end
    if body isa ChunkedBody
        return body_read!(body::ChunkedBody, dst)
    end
    if body isa EOFBody
        return body_read!(body::EOFBody, dst)
    end
    throw(ProtocolError("unsupported server request body type $(typeof(body))"))
end

@inline function _stream_request_body_close!(stream::Stream)::Nothing
    body = stream.request_body
    body isa EmptyBody && return nothing
    if body isa _H2ServerBody
        body_close!(body::_H2ServerBody)
        return nothing
    end
    if body isa FixedLengthBody
        body_close!(body::FixedLengthBody)
        return nothing
    end
    if body isa ChunkedBody
        body_close!(body::ChunkedBody)
        return nothing
    end
    if body isa EOFBody
        body_close!(body::EOFBody)
        return nothing
    end
    throw(ProtocolError("unsupported server request body type $(typeof(body))"))
end

function _write_all_response!(conn::Union{TCP.Conn,TLS.Conn}, response::Response)::Nothing
    try
        write_response!(conn, response)
    finally
        if response.body isa AbstractBody
            @try_ignore body_close!(response.body::AbstractBody)
        end
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

@inline function _is_peer_close_error(err::Exception)::Bool
    err isa SystemError || return false
    errno = err.errnum
    return errno == Int(Base.Libc.ECONNRESET) ||
           errno == Int(Base.Libc.EPIPE) ||
           errno == Int(Base.Libc.ECONNABORTED)
end

@enum _ServerConnErrAction::UInt8 begin
    _SERVER_CONN_ERR_CLOSE = 0
    _SERVER_CONN_ERR_TIMEOUT = 1
    _SERVER_CONN_ERR_RETHROW = 2
end

@enum _H2ConnCloseKind::UInt8 begin
    _H2_CONN_CLOSE_CLEAN = 0
    _H2_CONN_CLOSE_PEER = 1
    _H2_CONN_CLOSE_PROTOCOL = 2
    _H2_CONN_CLOSE_INTERNAL = 3
end

@inline function _classify_server_conn_error(err::Exception)::_ServerConnErrAction
    err isa IOPoll.DeadlineExceededError && return _SERVER_CONN_ERR_TIMEOUT
    if err isa ParseError || err isa ProtocolError || err isa EOFError ||
       err isa IOPoll.NetClosingError || err isa TLS.TLSError ||
       err isa TLS.TLSHandshakeTimeoutError || _is_peer_close_error(err)
        return _SERVER_CONN_ERR_CLOSE
    end
    return _SERVER_CONN_ERR_RETHROW
end

@inline function _classify_h2_conn_close(err::Exception)::_H2ConnCloseKind
    if err isa ProtocolError || err isa ParseError
        return _H2_CONN_CLOSE_PROTOCOL
    end
    if err isa IOPoll.DeadlineExceededError
        return _H2_CONN_CLOSE_PEER
    end
    if err isa EOFError || err isa IOPoll.NetClosingError || err isa TLS.TLSError
        return _H2_CONN_CLOSE_PEER
    end
    return _H2_CONN_CLOSE_INTERNAL
end

function _server_error_status(err::Exception)::Union{Nothing,Int}
    if err isa ParseError
        return 400
    end
    if err isa ProtocolError
        code = err.code
        if code == _PROTOCOL_ERROR_LINE_TOO_LONG || code == _PROTOCOL_ERROR_HEADERS_TOO_LARGE
            return 431
        elseif code == _PROTOCOL_ERROR_BODY_TOO_LARGE
            return 413
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
    @try_ignore begin
        _write_all_response!(conn, response)
    end
    @try_ignore begin
        _close_server_write!(conn)
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
        action = _classify_server_conn_error(err::Exception)
        if action == _SERVER_CONN_ERR_TIMEOUT
            _try_write_server_error!(tracked.conn, nothing, 408)
            return nothing
        end
        if action == _SERVER_CONN_ERR_CLOSE
            return nothing
        end
        rethrow(err)
    finally
        if !entered_helper
            _finalize_server_conn!(server, tracked)
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
                action = _classify_server_conn_error(err::Exception)
                status = _server_error_status(err::Exception)
                status === nothing || _try_write_server_error!(tracked.conn, nothing, status::Int)
                if action != _SERVER_CONN_ERR_RETHROW
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
                # Expose the per-connection reader so a stream handler can hand
                # the connection off to WebSockets.upgrade (which must recover any
                # bytes buffered past the request). Server streams otherwise read
                # the request body via stream.request_body, not stream.reader.
                stream.reader = reader
                try
                    server.handler(stream)
                    if !(@atomic :acquire stream.write_closed)
                        closewrite(stream)
                    end
                    closeread(stream)
                    _clear_deadlines!(server, tracked.conn)
                    _server_shutting_down(server) && return nothing
                    if _request_wants_close(request) || _response_wants_close(stream.response)
                        return nothing
                    end
                catch err
                    status = _server_error_status(err::Exception)
                    if !(@atomic :acquire stream.response_started)
                        @try_ignore begin
                            setstatus(stream, status === nothing ? 500 : status::Int)
                            stream.response.close = true
                            startwrite(stream)
                            closewrite(stream)
                        end
                    elseif !(@atomic :acquire stream.head_committed)
                        # startwrite ran but the response head was deferred (h1
                        # FIXED mode) and never reached the wire: answer with a
                        # raw error response instead of silently dropping the
                        # connection (#1303).
                        _try_write_server_error!(tracked.conn, request, status === nothing ? 500 : status::Int)
                        return nothing
                    end
                    @try_ignore begin
                        stream.response.close = true
                        close(stream)
                    end
                    return nothing
                end
            else
                handler_request = request
                response = try
                    handler_request = _buffer_server_request(request, server.max_body_bytes)
                    server.handler(handler_request)
                catch err
                    status = _server_error_status(err::Exception)
                    _try_write_server_error!(tracked.conn, request, status === nothing ? 500 : status::Int)
                    return nothing
                end
                if !(response isa Response)
                    @error "server handler must return HTTP.Response, got $(typeof(response))"
                    _try_write_server_error!(tracked.conn, request, 500)
                    return nothing
                end
                response_obj = response::Response
                response_obj.request = handler_request
                if !_request_body_fully_consumed(handler_request)
                    response_obj.close = true
                    @try_ignore begin
                        body_close!(handler_request.body)
                    end
                end
                _set_write_deadline!(server, tracked.conn)
                _write_all_response!(tracked.conn, response_obj)
                _clear_deadlines!(server, tracked.conn)
                _server_shutting_down(server) && return nothing
                if _request_wants_close(handler_request) || _response_wants_close(response_obj)
                    return nothing
                end
            end
            _set_conn_state!(tracked, _ConnState.IDLE)
            _set_idle_deadline!(server, tracked.conn)
        end
    finally
        _finalize_server_conn!(server, tracked)
    end
    return nothing
end

function _serve_listener!(server::Server, listener::Union{TCP.Listener,TLS.Listener}, ready::Threads.Event)
    _server_shutting_down(server) && throw(ProtocolError("server is shutting down"))
    _mark_server_listening!(server, listener)
    notify(ready)
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
        Threads.@spawn _serve_conn!(server, tracked)
    end
    return nothing
end

function _run_server!(server::Server, ready::Threads.Event)
    listener = TCP.listen(
        server.network, _listen_address(server); backlog=server.backlog, reuseaddr=server.reuseaddr,
    )
    try
        _serve_listener!(server, listener, ready)
    finally
        @try_ignore begin
            TCP.close(listener)
        end
    end
    return nothing
end

function _start_server_task!(f::F, server::Server)::Server where {F}
    state = _server_state(server)
    state == _ServerState.CLOSED && throw(ProtocolError("closed servers cannot be restarted"))
    state == _ServerState.RUNNING && throw(ProtocolError("server is already running"))
    ready = Threads.Event(true)
    task = Threads.@spawn begin
        try
            f(ready)
        catch
            notify(ready)
            rethrow()
        end
    end
    lock(server.lock)
    try
        server.serve_task = task
    finally
        unlock(server.lock)
    end
    wait(ready)
    # If the spawned serve loop failed during startup, surface the failure
    # synchronously to the caller. We rely on the synchronous bind path in
    # the `serve!(handler, host, port; ...)` form to translate bind errors
    # (EADDRINUSE etc.) to `HTTP.AddressInUseError` before the task is even
    # spawned. Anything that fails inside the task itself is rethrown as
    # `TaskFailedException` here without further unwrapping; the JuliaC
    # trim verifier does not allow `current_exceptions(::Task)` and
    # `getproperty(::TaskFailedException, :task)` is also trim-unsafe in
    # the path that JuliaC compiles.
    if istaskdone(task) && istaskfailed(task)
        wait(task)
    end
    return server
end

"""
    listen!(server) -> Server

Start a configured `Server` asynchronously and return it.
"""
function listen!(server::Server)::Server
    return _start_server_task!(server) do ready
        _run_server!(server, ready)
    end
end

@inline function _resolve_server_timeout_ns(ns_name::AbstractString, ns_value::Integer, seconds_name::AbstractString, seconds_value)::Int64
    seconds_value === nothing && return Int64(ns_value)
    ns_value == 0 || throw(ArgumentError("$(seconds_name) cannot be combined with $(ns_name)"))
    return _timeout_ns_from_seconds(seconds_name, seconds_value)
end

@inline function _resolve_server_timeouts(
    read_timeout_ns::Integer,
    read_timeout,
    read_header_timeout_ns::Integer,
    read_header_timeout,
    write_timeout_ns::Integer,
    write_timeout,
    idle_timeout_ns::Integer,
    idle_timeout,
    readtimeout,
)::Tuple{Int64,Int64,Int64,Int64}
    effective_read_timeout_ns = _resolve_server_timeout_ns("read_timeout_ns", read_timeout_ns, "read_timeout", read_timeout)
    if readtimeout !== nothing
        read_timeout === nothing || throw(ArgumentError("readtimeout cannot be combined with read_timeout"))
        read_timeout_ns == 0 || throw(ArgumentError("readtimeout cannot be combined with read_timeout_ns"))
        @warn "`readtimeout` is deprecated; use `read_timeout` for server inactivity timeouts" maxlog=1
        effective_read_timeout_ns = _timeout_ns_from_seconds("readtimeout", readtimeout)
    end
    return (
        effective_read_timeout_ns,
        _resolve_server_timeout_ns("read_header_timeout_ns", read_header_timeout_ns, "read_header_timeout", read_header_timeout),
        _resolve_server_timeout_ns("write_timeout_ns", write_timeout_ns, "write_timeout", write_timeout),
        _resolve_server_timeout_ns("idle_timeout_ns", idle_timeout_ns, "idle_timeout", idle_timeout),
    )
end

@inline function _warn_server_verbose_compat(verbose)::Nothing
    verbose === nothing || verbose === false || @warn "`verbose` is accepted for compatibility on the HTTP 2.0 server but is not implemented yet" maxlog=1
    return nothing
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
request and writing the response. Timeout keywords ending in `_ns` are
nanoseconds; `read_timeout`, `read_header_timeout`, `write_timeout`, and
`idle_timeout` accept seconds. The older `readtimeout` keyword is accepted as a
seconds-valued migration alias for `read_timeout`.
"""
function listen!(
    handler::F, host::AbstractString="127.0.0.1", port_num::Integer=8080;
    read_timeout_ns::Integer=Int64(0),
    read_header_timeout_ns::Integer=Int64(0),
    write_timeout_ns::Integer=Int64(0),
    idle_timeout_ns::Integer=Int64(0),
    read_timeout=nothing,
    read_header_timeout=nothing,
    write_timeout=nothing,
    idle_timeout=nothing,
    readtimeout=nothing,
    verbose=nothing,
    max_header_bytes::Integer=1 * 1024 * 1024,
    http2_settings::HTTP2Settings=HTTP2Settings(),
    max_concurrent_streams::Integer=_H2_DEFAULT_MAX_CONCURRENT_STREAMS,
    listenany::Bool=false,
    reuseaddr::Bool=true,
    backlog::Integer=128,
) where {F}
    effective_read_timeout_ns, effective_read_header_timeout_ns, effective_write_timeout_ns, effective_idle_timeout_ns =
        _resolve_server_timeouts(read_timeout_ns, read_timeout, read_header_timeout_ns, read_header_timeout, write_timeout_ns, write_timeout, idle_timeout_ns, idle_timeout, readtimeout)
    _warn_server_verbose_compat(verbose)
    return listen!(Server(
        network="tcp",
        address=HostResolvers.join_host_port(host, Int(port_num)),
        handler=handler,
        stream=true,
        read_timeout_ns=effective_read_timeout_ns,
        read_header_timeout_ns=effective_read_header_timeout_ns,
        write_timeout_ns=effective_write_timeout_ns,
        idle_timeout_ns=effective_idle_timeout_ns,
        max_header_bytes=max_header_bytes,
        http2_settings=http2_settings,
        max_concurrent_streams=max_concurrent_streams,
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
    read_timeout=nothing,
    read_header_timeout=nothing,
    write_timeout=nothing,
    idle_timeout=nothing,
    readtimeout=nothing,
    verbose=nothing,
    max_header_bytes::Integer=1 * 1024 * 1024,
    http2_settings::HTTP2Settings=HTTP2Settings(),
    max_concurrent_streams::Integer=_H2_DEFAULT_MAX_CONCURRENT_STREAMS,
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
        read_timeout=read_timeout,
        read_header_timeout=read_header_timeout,
        write_timeout=write_timeout,
        idle_timeout=idle_timeout,
        readtimeout=readtimeout,
        verbose=verbose,
        max_header_bytes=max_header_bytes,
        http2_settings=http2_settings,
        max_concurrent_streams=max_concurrent_streams,
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
    read_timeout=nothing,
    read_header_timeout=nothing,
    write_timeout=nothing,
    idle_timeout=nothing,
    readtimeout=nothing,
    verbose=nothing,
    max_header_bytes::Integer=1 * 1024 * 1024,
    http2_settings::HTTP2Settings=HTTP2Settings(),
    max_concurrent_streams::Integer=_H2_DEFAULT_MAX_CONCURRENT_STREAMS,
    listenany::Bool=false,
    reuseaddr::Bool=true,
    backlog::Integer=128,
    ) where {F}
    effective_read_timeout_ns, effective_read_header_timeout_ns, effective_write_timeout_ns, effective_idle_timeout_ns =
        _resolve_server_timeouts(read_timeout_ns, read_timeout, read_header_timeout_ns, read_header_timeout, write_timeout_ns, write_timeout, idle_timeout_ns, idle_timeout, readtimeout)
    _warn_server_verbose_compat(verbose)
    listenany && throw(ArgumentError("listenany is not valid when passing an existing listener"))
    _ = reuseaddr
    _ = backlog
    bound_address, _ = _listener_bound_address(listener)
    server = Server(
        network="tcp",
        address=bound_address,
        handler=handler,
        stream=true,
        read_timeout_ns=effective_read_timeout_ns,
        read_header_timeout_ns=effective_read_header_timeout_ns,
        write_timeout_ns=effective_write_timeout_ns,
        idle_timeout_ns=effective_idle_timeout_ns,
        max_header_bytes=max_header_bytes,
        http2_settings=http2_settings,
        max_concurrent_streams=max_concurrent_streams,
        listenany=false,
        reuseaddr=reuseaddr,
        backlog=backlog,
    )
    return _start_server_task!(server) do ready
        _serve_listener!(server, listener, ready)
    end
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
        @try_ignore begin
            close(server)
        end
    end
    return server
end

"""
    serve!(handler, host="127.0.0.1", port=8080;
           read_timeout_ns=0, read_header_timeout_ns=0,
           write_timeout_ns=0, idle_timeout_ns=0,
           max_header_bytes=1*1024*1024, max_body_bytes=64*1024*1024,
           listenany=false, reuseaddr=true, backlog=128) -> Server
    serve!(handler, port; kwargs...) -> Server
    serve!(handler, listener; kwargs...) -> Server

Start an HTTP server and return the running `Server`.

`handler` is called with an `HTTP.Request` and must return an `HTTP.Response`.
Use `listen!` for the lower-level `HTTP.Stream` handler path.
Timeout keywords ending in `_ns` are nanoseconds; the older `readtimeout`
keyword is accepted as a seconds-valued migration alias for `read_timeout`.
Ordinary request handlers buffer request bodies before dispatch; `max_body_bytes`
caps that buffering, and `0` restores the legacy unbounded behavior.
"""
function serve!(
    handler::F,
    listener::Union{TCP.Listener,TLS.Listener};
    read_timeout_ns::Integer=Int64(0),
    read_header_timeout_ns::Integer=Int64(0),
    write_timeout_ns::Integer=Int64(0),
    idle_timeout_ns::Integer=Int64(0),
    read_timeout=nothing,
    read_header_timeout=nothing,
    write_timeout=nothing,
    idle_timeout=nothing,
    readtimeout=nothing,
    verbose=nothing,
    max_header_bytes::Integer=1 * 1024 * 1024,
    max_body_bytes::Integer=_SERVER_DEFAULT_MAX_BODY_BYTES,
    http2_settings::HTTP2Settings=HTTP2Settings(),
    max_concurrent_streams::Integer=_H2_DEFAULT_MAX_CONCURRENT_STREAMS,
    listenany::Bool=false,
    reuseaddr::Bool=true,
    backlog::Integer=128,
) where {F}
    effective_read_timeout_ns, effective_read_header_timeout_ns, effective_write_timeout_ns, effective_idle_timeout_ns =
        _resolve_server_timeouts(read_timeout_ns, read_timeout, read_header_timeout_ns, read_header_timeout, write_timeout_ns, write_timeout, idle_timeout_ns, idle_timeout, readtimeout)
    _warn_server_verbose_compat(verbose)
    listenany && throw(ArgumentError("listenany is not valid when passing an existing listener"))
    _ = reuseaddr
    _ = backlog
    bound_address, _ = _listener_bound_address(listener)
    server = Server(
        network="tcp",
        address=bound_address,
        handler=handler,
        stream=false,
        read_timeout_ns=effective_read_timeout_ns,
        read_header_timeout_ns=effective_read_header_timeout_ns,
        write_timeout_ns=effective_write_timeout_ns,
        idle_timeout_ns=effective_idle_timeout_ns,
        max_header_bytes=max_header_bytes,
        max_body_bytes=max_body_bytes,
        http2_settings=http2_settings,
        max_concurrent_streams=max_concurrent_streams,
        listenany=false,
        reuseaddr=reuseaddr,
        backlog=backlog,
    )
    return _start_server_task!(server) do ready
        _serve_listener!(server, listener, ready)
    end
end

function serve!(
    handler::F,
    host::AbstractString="127.0.0.1",
    port_num::Integer=8080;
    read_timeout_ns::Integer=Int64(0),
    read_header_timeout_ns::Integer=Int64(0),
    write_timeout_ns::Integer=Int64(0),
    idle_timeout_ns::Integer=Int64(0),
    read_timeout=nothing,
    read_header_timeout=nothing,
    write_timeout=nothing,
    idle_timeout=nothing,
    readtimeout=nothing,
    verbose=nothing,
    max_header_bytes::Integer=1 * 1024 * 1024,
    max_body_bytes::Integer=_SERVER_DEFAULT_MAX_BODY_BYTES,
    http2_settings::HTTP2Settings=HTTP2Settings(),
    max_concurrent_streams::Integer=_H2_DEFAULT_MAX_CONCURRENT_STREAMS,
    listenany::Bool=false,
    reuseaddr::Bool=true,
    backlog::Integer=128,
) where {F}
    bind_address = HostResolvers.join_host_port(host, listenany ? 0 : Int(port_num))
    listener = try
        TCP.listen("tcp", bind_address; backlog=backlog, reuseaddr=reuseaddr)
    catch err
        wrapped = _wrap_server_listen_error(err, bind_address)
        wrapped === err ? rethrow() : throw(wrapped)
    end
    try
        return serve!(
            handler,
            listener;
            read_timeout_ns=read_timeout_ns,
            read_header_timeout_ns=read_header_timeout_ns,
            write_timeout_ns=write_timeout_ns,
            idle_timeout_ns=idle_timeout_ns,
            read_timeout=read_timeout,
            read_header_timeout=read_header_timeout,
            write_timeout=write_timeout,
            idle_timeout=idle_timeout,
            readtimeout=readtimeout,
            verbose=verbose,
            max_header_bytes=max_header_bytes,
            max_body_bytes=max_body_bytes,
            http2_settings=http2_settings,
            max_concurrent_streams=max_concurrent_streams,
            reuseaddr=reuseaddr,
            backlog=backlog,
        )
    catch
        @try_ignore begin
            TCP.close(listener)
        end
        rethrow()
    end
end

function serve!(
    handler::F,
    port_num::Integer;
    read_timeout_ns::Integer=Int64(0),
    read_header_timeout_ns::Integer=Int64(0),
    write_timeout_ns::Integer=Int64(0),
    idle_timeout_ns::Integer=Int64(0),
    read_timeout=nothing,
    read_header_timeout=nothing,
    write_timeout=nothing,
    idle_timeout=nothing,
    readtimeout=nothing,
    verbose=nothing,
    max_header_bytes::Integer=1 * 1024 * 1024,
    max_body_bytes::Integer=_SERVER_DEFAULT_MAX_BODY_BYTES,
    http2_settings::HTTP2Settings=HTTP2Settings(),
    max_concurrent_streams::Integer=_H2_DEFAULT_MAX_CONCURRENT_STREAMS,
    listenany::Bool=false,
    reuseaddr::Bool=true,
    backlog::Integer=128,
) where {F}
    return serve!(
        handler,
        "127.0.0.1",
        port_num;
        read_timeout_ns=read_timeout_ns,
        read_header_timeout_ns=read_header_timeout_ns,
        write_timeout_ns=write_timeout_ns,
        idle_timeout_ns=idle_timeout_ns,
        read_timeout=read_timeout,
        read_header_timeout=read_header_timeout,
        write_timeout=write_timeout,
        idle_timeout=idle_timeout,
        readtimeout=readtimeout,
        verbose=verbose,
        max_header_bytes=max_header_bytes,
        max_body_bytes=max_body_bytes,
        http2_settings=http2_settings,
        max_concurrent_streams=max_concurrent_streams,
        listenany=listenany,
        reuseaddr=reuseaddr,
        backlog=backlog,
    )
end

"""
    serve(handler, args...; kwargs...)

Run `serve!` in the foreground, blocking until the server is closed.
"""
function serve(
    handler::F,
    args...;
    read_timeout_ns::Integer=Int64(0),
    read_header_timeout_ns::Integer=Int64(0),
    write_timeout_ns::Integer=Int64(0),
    idle_timeout_ns::Integer=Int64(0),
    read_timeout=nothing,
    read_header_timeout=nothing,
    write_timeout=nothing,
    idle_timeout=nothing,
    readtimeout=nothing,
    verbose=nothing,
    max_header_bytes::Integer=1 * 1024 * 1024,
    max_body_bytes::Integer=_SERVER_DEFAULT_MAX_BODY_BYTES,
    http2_settings::HTTP2Settings=HTTP2Settings(),
    max_concurrent_streams::Integer=_H2_DEFAULT_MAX_CONCURRENT_STREAMS,
    listenany::Bool=false,
    reuseaddr::Bool=true,
    backlog::Integer=128,
) where {F}
    server = serve!(
        handler,
        args...;
        read_timeout_ns=read_timeout_ns,
        read_header_timeout_ns=read_header_timeout_ns,
        write_timeout_ns=write_timeout_ns,
        idle_timeout_ns=idle_timeout_ns,
        read_timeout=read_timeout,
        read_header_timeout=read_header_timeout,
        write_timeout=write_timeout,
        idle_timeout=idle_timeout,
        readtimeout=readtimeout,
        verbose=verbose,
        max_header_bytes=max_header_bytes,
        max_body_bytes=max_body_bytes,
        http2_settings=http2_settings,
        max_concurrent_streams=max_concurrent_streams,
        listenany=listenany,
        reuseaddr=reuseaddr,
        backlog=backlog,
    )
    try
        wait(server)
    finally
        @try_ignore begin
            close(server)
        end
    end
    return server
end
