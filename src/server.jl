socket_endpoint(host, port) = aws_socket_endpoint(
    ntuple(i -> i > sizeof(host) ? 0x00 : codeunit(host, i), Base._counttuple(fieldtype(aws_socket_endpoint, :address))),
    port % UInt32
)

mutable struct Connection{S}
    const server::S # Server{F, C}
    const allocator::Ptr{aws_allocator}
    const connection::Ptr{aws_http_connection}
    const streams_lock::ReentrantLock
    const streams::Set{Stream}
    connection_options::aws_http_server_connection_options

    Connection(
        server::S,
        allocator::Ptr{aws_allocator},
        connection::Ptr{aws_http_connection},
    ) where {S} = new{S}(server, allocator, connection, ReentrantLock(), Set{Stream}())
end

Base.hash(c::Connection, h::UInt) = hash(c.connection, h)

if !@isdefined aws_http2_send_push_promise_options
    struct aws_http2_send_push_promise_options
        self_size::Csize_t
        user_data::Ptr{Cvoid}
        on_complete::Ptr{Cvoid}
        on_destroy::Ptr{Cvoid}
        pad_length::UInt8
    end
end

function aws_http2_stream_send_push_promise(
    parent_stream::Ptr{aws_http_stream},
    request::Ptr{aws_http_message},
    options::Ref{aws_http2_send_push_promise_options},
)
    return ccall((:aws_http2_stream_send_push_promise, LibAwsHTTPFork.libaws_c_http_jq),
        Ptr{aws_http_stream},
        (Ptr{aws_http_stream}, Ptr{aws_http_message}, Ptr{aws_http2_send_push_promise_options}),
        parent_stream,
        request,
        options,
    )
end

function remote_address(c::Connection)
    socket_ptr = aws_http_connection_get_remote_endpoint(c.connection)
    addr = unsafe_load(socket_ptr).address
    bytes = Vector{UInt8}(undef, length(addr))
    nul_i = 0
    for i in eachindex(bytes)
        b = addr[i]
        @inbounds bytes[i] = b
        if b == 0x00
            nul_i = i
            break
        end
    end
    resize!(bytes, nul_i == 0 ? length(addr) : nul_i - 1)
    return String(bytes)
end
remote_port(c::Connection) = Int(unsafe_load(aws_http_connection_get_remote_endpoint(c.connection)).port)
function http_version(c::Connection)
    v = aws_http_connection_get_version(c.connection)
    return v == AWS_HTTP_VERSION_2 ? "HTTP/2" : "HTTP/1.1"
end

getinet(host::String, port::Integer) = Sockets.InetAddr(parse(IPAddr, host), port)
getinet(host::IPAddr, port::Integer) = Sockets.InetAddr(host, port)

mutable struct Server{F, C}
    const f::F
    const on_stream_complete::C
    const fut::Future{Symbol}
    const allocator::Ptr{aws_allocator}
    const endpoint::aws_socket_endpoint
    const socket_options::aws_socket_options
    const tls_options::Union{aws_tls_connection_options, Nothing}
    const connections_lock::ReentrantLock
    const connections::Set{Connection}
    const closed::Threads.Event
    const access_log::Union{Nothing, Function}
    const stream::Bool
    const logstate::Base.CoreLogging.LogState
    @atomic state::Symbol # :initializing, :running, :closed
    server::Ptr{aws_http_server}
    server_options::aws_http_server_options

    Server{F, C}(
        f::F,
        on_stream_complete::C,
        fut::Future{Symbol},
        allocator::Ptr{aws_allocator},
        endpoint::aws_socket_endpoint,
        socket_options::aws_socket_options,
        tls_options::Union{aws_tls_connection_options, Nothing},
        connections_lock::ReentrantLock,
        connections::Set{Connection},
        closed::Threads.Event,
        access_log::Union{Nothing, Function},
        stream::Bool,
        logstate::Base.CoreLogging.LogState,
        state::Symbol,
    ) where {F, C} = new{F, C}(f, on_stream_complete, fut, allocator, endpoint, socket_options, tls_options, connections_lock, connections, closed, access_log, stream, logstate, state)
end

Base.wait(s::Server) = wait(s.closed)
ftype(::Server{F}) where {F} = F
port(s::Server) = Int(s.endpoint.port)

function serve!(f, host="127.0.0.1", port=8080;
    allocator=default_aws_allocator(),
    bootstrap::Ptr{aws_server_bootstrap}=default_aws_server_bootstrap(),
    endpoint=nothing,
    listenany::Bool=false,
    on_stream_complete=nothing,
    access_log::Union{Nothing, Function}=nothing,
    stream::Bool=false,
    # socket options
    socket_options=nothing,
    socket_domain=:ipv4,
    connect_timeout_ms::Integer=3000,
    keep_alive_interval_sec::Integer=0,
    keep_alive_timeout_sec::Integer=0,
    keep_alive_max_failed_probes::Integer=0,
    keepalive::Bool=false,
    # tls options
    tls_options=nothing,
    ssl_cert=nothing,
    ssl_key=nothing,
    ssl_capath=nothing,
    ssl_cacert=nothing,
    ssl_insecure=false,
    ssl_alpn_list="h2;http/1.1",
    initial_window_size=typemax(UInt64),
    )
    addr = getinet(host, port)
    if listenany
        port, sock = Sockets.listenany(addr.host, addr.port)
        close(sock)
    end
    server = Server{typeof(f), typeof(on_stream_complete)}(
        f, # RequestHandler
        on_stream_complete,
        Future{Symbol}(),
        allocator,
        endpoint !== nothing ? endpoint : socket_endpoint(host, port),
        socket_options !== nothing ? socket_options : aws_socket_options(
            AWS_SOCKET_STREAM, # socket type
            socket_domain == :ipv4 ? AWS_SOCKET_IPV4 : AWS_SOCKET_IPV6, # socket domain
            AWS_SOCKET_IMPL_PLATFORM_DEFAULT, # aws_socket_impl_type
            connect_timeout_ms,
            keep_alive_interval_sec,
            keep_alive_timeout_sec,
            keep_alive_max_failed_probes,
            keepalive,
            ntuple(x -> Cchar(0), 16) # network_interface_name
        ),
        tls_options !== nothing ? tls_options :
            any(x -> x !== nothing, (ssl_cert, ssl_key, ssl_capath, ssl_cacert)) ? LibAwsIO.tlsoptions(host;
                ssl_cert,
                ssl_key,
                ssl_capath,
                ssl_cacert,
                ssl_insecure,
                ssl_alpn_list
            ) : nothing,
        ReentrantLock(), # connections_lock
        Set{Connection}(), # connections
        Threads.Event(), # closed
        access_log,
        stream,
        Base.CoreLogging.current_logstate(),
        :initializing, # state
    )
    server.server_options = aws_http_server_options(
        1,
        allocator,
        bootstrap,
        pointer(FieldRef(server, :endpoint)),
        pointer(FieldRef(server, :socket_options)),
        server.tls_options === nothing ? C_NULL : pointer(FieldRef(server, :tls_options)),
        initial_window_size,
        pointer_from_objref(server),
        on_incoming_connection[],
        on_destroy_complete[],
        false # manual_window_management
    )
    server.server = aws_http_server_new(FieldRef(server, :server_options))
    @assert server.server != C_NULL "failed to create server"
    @atomic server.state = :running
    return server
end

function serve(f, host="127.0.0.1", port=8080; stream::Bool=false, kw...)
    server = serve!(f, host, port; stream=stream, kw...)
    wait(server)
    return server
end

listen!(f, host="127.0.0.1", port=8080; kw...) = serve!(f, host, port; stream=true, kw...)
listen(f, host="127.0.0.1", port=8080; kw...) = serve(f, host, port; stream=true, kw...)

function _push_promise_headers!(req::Request, parent::Stream; scheme=nothing, authority=nothing)
    if !hasheader(req.headers, ":scheme")
        scheme_val = scheme === nothing ? header(parent.request, ":scheme", "") : String(scheme)
        isempty(scheme_val) && throw(ArgumentError("push promise requires :scheme"))
        addheader(req.headers, ":scheme", scheme_val)
    end
    if !hasheader(req.headers, ":authority")
        authority_val = authority === nothing ? header(parent.request, ":authority", header(parent.request, "host", "")) : String(authority)
        isempty(authority_val) && throw(ArgumentError("push promise requires :authority"))
        addheader(req.headers, ":authority", authority_val)
    end
    return
end

function push_promise(parent::Stream, req::Request; pad_length::Integer=0, scheme=nothing, authority=nothing)
    parent.server_side || error("push_promise is only supported for server streams")
    parent.http2 || throw(ArgumentError("HTTP/2 stream required for push promise"))
    req.version == HTTPVersion(2, 0) || throw(ArgumentError("push promise request must be HTTP/2"))
    0 <= pad_length <= 0xff || throw(ArgumentError("pad_length must be between 0 and 255"))
    _push_promise_headers!(req, parent; scheme=scheme, authority=authority)
    push_stream = Stream{typeof(parent.connection)}(parent.allocator, false, true, true)
    push_stream.connection = parent.connection
    push_stream.request = req
    opts = aws_http2_send_push_promise_options(
        sizeof(aws_http2_send_push_promise_options),
        pointer_from_objref(push_stream),
        on_server_stream_complete[],
        on_destroy[],
        UInt8(pad_length),
    )
    stream_ptr = aws_http2_stream_send_push_promise(parent.ptr, req.ptr, Ref(opts))
    stream_ptr == C_NULL && aws_throw_error()
    push_stream.ptr = stream_ptr
    @lock parent.connection.streams_lock begin
        push!(parent.connection.streams, push_stream)
    end
    retain_stream!(push_stream)
    return push_stream
end

function push_promise(parent::Stream, method::Union{String, Symbol}, path; headers=Header[], pad_length::Integer=0, scheme=nothing, authority=nothing)
    req = Request(String(method), String(path), headers, nothing, true, parent.allocator)
    return push_promise(parent, req; pad_length=pad_length, scheme=scheme, authority=authority)
end

const on_incoming_connection = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_connection(aws_server, aws_conn, error_code, server_ptr)
    server = unsafe_pointer_to_objref(server_ptr)
    Base.CoreLogging.with_logstate(server.logstate) do
        if error_code != 0
            @error "incoming connection error" exception=(aws_error(error_code), Base.backtrace())
            return
        end
        conn = Connection(
            server,
            server.allocator,
            aws_conn,
        )
        conn.connection_options = aws_http_server_connection_options(
            1,
            pointer_from_objref(conn),
            on_incoming_request[],
            on_connection_shutdown[]
        )
        if aws_http_connection_configure_server(
            aws_conn,
            FieldRef(conn, :connection_options)
        ) != 0
            @error "failed to configure connection" exception=(aws_error(), Base.backtrace())
            return
        end
        @lock server.connections_lock begin
            push!(server.connections, conn)
        end
        return
    end
end

const on_connection_shutdown = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_connection_shutdown(aws_conn, error_code, conn_ptr)
    conn = unsafe_pointer_to_objref(conn_ptr)
    Base.CoreLogging.with_logstate(conn.server.logstate) do
        if error_code != 0
            @error "connection shutdown error" exception=(aws_error(error_code), Base.backtrace())
        end
        @lock conn.server.connections_lock begin
            delete!(conn.server.connections, conn)
        end
        return
    end
end

const on_incoming_request = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_request(aws_conn, conn_ptr)
    conn = unsafe_pointer_to_objref(conn_ptr)
    Base.CoreLogging.with_logstate(conn.server.logstate) do
        stream = Stream{typeof(conn)}(
            conn.allocator,
            false, # decompress
            aws_http_connection_get_version(aws_conn) == AWS_HTTP_VERSION_2, # http2
            true,
        )
        stream.connection = conn
        stream.request_handler_options = aws_http_request_handler_options(
            1,
            aws_conn,
            pointer_from_objref(stream),
            on_request_headers[],
            on_request_header_block_done[],
            on_request_body[],
            on_request_done[],
            on_server_stream_complete[],
            on_destroy[]
        )
        stream.request = Request("", "")
        stream.ptr = aws_http_stream_new_server_request_handler(
            FieldRef(stream, :request_handler_options)
        )
        if stream.ptr == C_NULL
            @error "failed to create stream" exception=(aws_error(), Base.backtrace())
        else
            @lock conn.streams_lock begin
                push!(conn.streams, stream)
            end
        end
        return stream.ptr
    end
end

const on_request_headers = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_request_headers(aws_stream_ptr, header_block, header_array::Ptr{aws_http_header}, num_headers, stream_ptr)
    stream = unsafe_pointer_to_objref(stream_ptr)
    if header_block == AWS_HTTP_HEADER_BLOCK_TRAILING
        trailers = stream.request.trailers
        if trailers === nothing
            trailers = Headers(stream.request.allocator)
            stream.request.trailers = trailers
        end
        addheaders(trailers, header_array, num_headers)
    else
        headers = stream.request.headers
        addheaders(headers, header_array, num_headers)
    end
    return Cint(0)
end

const on_request_header_block_done = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_request_header_block_done(aws_stream_ptr, header_block, stream_ptr)
    stream = unsafe_pointer_to_objref(stream_ptr)
    if header_block != AWS_HTTP_HEADER_BLOCK_MAIN
        return Cint(0)
    end
    ret = aws_http_stream_get_incoming_request_method(aws_stream_ptr, FieldRef(stream, :method))
    ret != 0 && return ret
    aws_http_message_set_request_method(stream.request.ptr, stream.method)
    ret = aws_http_stream_get_incoming_request_uri(aws_stream_ptr, FieldRef(stream, :path))
    ret != 0 && return ret
    aws_http_message_set_request_path(stream.request.ptr, stream.path)
    notify(stream.headers_ready)
    if stream.connection.server.stream && !stream.handler_started
        stream.handler_started = true
        stream.bufferstream === nothing && (stream.bufferstream = Base.BufferStream())
        Threads.@spawn begin
            Base.CoreLogging.with_logstate(stream.connection.server.logstate) do
                try
                    Base.invokelatest(stream.connection.server.f, stream)
                catch e
                    @error "Request handler error; sending 500" exception=(e, catch_backtrace())
                    if !stream.response_started
                        try
                            setstatus(stream, 500)
                        catch err
                            @error "failed to set 500 status" exception=(err, catch_backtrace())
                        end
                    end
                finally
                    try
                        closewrite(stream)
                    catch err
                        @error "failed to close response stream" exception=(err, catch_backtrace())
                    end
                end
            end
        end
    end
    return Cint(0)
end

const on_request_body = Ref{Ptr{Cvoid}}(C_NULL)

#TODO: how could we allow for streaming request bodies?
function c_on_request_body(aws_stream_ptr, data::Ptr{aws_byte_cursor}, stream_ptr)
    stream = unsafe_pointer_to_objref(stream_ptr)
    bc = unsafe_load(data)
    if stream.connection.server.stream
        stream.bufferstream === nothing && (stream.bufferstream = Base.BufferStream())
        unsafe_write(stream.bufferstream, bc.ptr, bc.len)
        return Cint(0)
    end
    body = stream.request.body
    if body === nothing
        body = Vector{UInt8}(undef, bc.len)
        GC.@preserve body unsafe_copyto!(pointer(body), bc.ptr, bc.len)
        stream.request.body = body
    else
        newlen = length(body) + bc.len
        resize!(body, newlen)
        GC.@preserve body unsafe_copyto!(pointer(body, length(body) - bc.len + 1), bc.ptr, bc.len)
    end
    return Cint(0)
end

const on_request_done = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_request_done(aws_stream_ptr, stream_ptr)
    stream = unsafe_pointer_to_objref(stream_ptr)
    Base.CoreLogging.with_logstate(stream.connection.server.logstate) do
        if stream.connection.server.stream
            stream.bufferstream !== nothing && close(stream.bufferstream)
            return Cint(0)
        end
        try
            stream.response = Base.invokelatest(stream.connection.server.f, stream.request)::Response
            if stream.request.method == "HEAD"
                setinputstream!(stream.response, nothing)
            end
            #TODO: is it possible to stream the response body?
            #TODO: support transfer-encoding: gzip
        catch e
            @error "Request handler error; sending 500" exception=(e, catch_backtrace())
            stream.response = Response(500)
        end
        ret = aws_http_stream_send_response(aws_stream_ptr, stream.response.ptr)
        if ret != 0
            @error "failed to send response" exception=(aws_error(ret), Base.backtrace())
            return Cint(AWS_ERROR_HTTP_UNKNOWN)
        end
        return Cint(0)
    end
end

const on_server_stream_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_server_stream_complete(aws_stream_ptr, error_code, stream_ptr)
    stream = unsafe_pointer_to_objref(stream_ptr)
    Base.CoreLogging.with_logstate(stream.connection.server.logstate) do
        if error_code != 0
            @error "server complete error" exception=(aws_error(error_code), Base.backtrace())
        end
        if stream.connection.server.on_stream_complete !== nothing
            try
                Base.invokelatest(stream.connection.server.on_stream_complete, stream)
            catch e
                @error "on_stream_complete error" exception=(e, catch_backtrace())
            end
        end
        if stream.connection.server.access_log !== nothing
            try
                @info sprint(stream.connection.server.access_log, stream) _group=:access
            catch e
                @error "access log error" exception=(e, catch_backtrace())
            end
        end
        @lock stream.connection.streams_lock begin
            delete!(stream.connection.streams, stream)
        end
        release_stream_ptr!(stream)
        return Cint(0)
    end
end

const on_destroy_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_destroy_complete(server_ptr)
    server = unsafe_pointer_to_objref(server_ptr)
    notify(server.fut, :destroyed)
    return
end

function Base.close(server::Server)
    state = @atomicswap server.state = :closed
    if state == :running
        aws_http_server_release(server.server)
        @assert wait(server.fut) == :destroyed
        notify(server.closed)
    end
    return
end

Base.isopen(server::Server) = @atomic(server.state) != :closed
