socket_endpoint(host, port) = aws_socket_endpoint(
    ntuple(i -> i > sizeof(host) ? 0x00 : codeunit(host, i), Base._counttuple(fieldtype(aws_socket_endpoint, :address))),
    port % UInt32
)

mutable struct Connection{F, S}
    const f::F
    const server::S # Server
    const allocator::Ptr{aws_allocator}
    const connection::Ptr{aws_http_connection}
    request_handler_options::aws_http_request_handler_options
    current_response::Ptr{aws_http_message}
    connection_options::aws_http_server_connection_options
    current_request::Request

    Connection{F, S}(
        f::F,
        server::S,
        allocator::Ptr{aws_allocator},
        connection::Ptr{aws_http_connection},
    ) where {F, S} = new{F, S}(f, server, allocator, connection)
end

Base.hash(c::Connection, h::UInt) = hash(c.connection, h)

mutable struct Server{F}
    const f::F
    const comm::Channel{Symbol}
    const allocator::Ptr{aws_allocator}
    const endpoint::aws_socket_endpoint
    const socket_options::aws_socket_options
    const tls_options::Union{aws_tls_connection_options, Nothing}
    const connections_lock::ReentrantLock
    const connections::Set{Connection}
    const closed::Threads.Event
    @atomic state::Symbol # :initializing, :running, :closed
    server::Ptr{aws_http_server}
    server_options::aws_http_server_options

    Server{F}(
        f::F,
        comm::Channel{Symbol},
        allocator::Ptr{aws_allocator},
        endpoint::aws_socket_endpoint,
        socket_options::aws_socket_options,
        tls_options::Union{aws_tls_connection_options, Nothing},
        connections_lock::ReentrantLock,
        connections::Set{Connection},
        closed::Threads.Event,
        state::Symbol,
    ) where {F} = new{F}(f, comm, allocator, endpoint, socket_options, tls_options, connections_lock, connections, closed, state)
end

Base.wait(s::Server) = wait(s.closed)

ftype(::Server{F}) where {F} = F

function serve!(f, host="127.0.0.1", port=8080;
    allocator=default_aws_allocator(),
    bootstrap::Ptr{aws_server_bootstrap}=default_aws_server_bootstrap(),
    endpoint=nothing,
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
    server = Server{typeof(f)}(
        f, # RequestHandler
        Channel{Symbol}(1), # comm
        allocator,
        endpoint !== nothing ? endpoint : socket_endpoint(host, port),
        socket_options !== nothing ? socket_options : aws_socket_options(
            AWS_SOCKET_STREAM, # socket type
            socket_domain == :ipv4 ? AWS_SOCKET_IPV4 : AWS_SOCKET_IPV6, # socket domain
            connect_timeout_ms,
            keep_alive_interval_sec,
            keep_alive_timeout_sec,
            keep_alive_max_failed_probes,
            keepalive
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
        :initializing, # state
        C_NULL # server
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

const on_incoming_connection = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_connection(aws_server, aws_conn, error_code, server_ptr)
    server = unsafe_pointer_to_objref(server_ptr)
    if error_code != 0
        @error "incoming connection error" exception=(aws_error(), Base.backtrace())
        return
    end
    conn = Connection(
        server.f,
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
    conn.request_handler_options = aws_http_request_handler_options(
        1,
        aws_conn,
        pointer_from_objref(conn),
        on_request_headers[],
        on_request_header_block_done[],
        on_request_body[],
        on_request_done[],
        on_server_complete[],
        C_NULL # on_server_destroy[]
    )
    @lock server.connections_lock begin
        push!(server.connections, conn)
    end
    aws_http_connection_configure_server(
        aws_conn,
        FieldRef(conn, :connection_options)
    )
    return
end

const on_connection_shutdown = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_connection_shutdown(aws_conn, error_code, conn_ptr)
    conn = unsafe_pointer_to_objref(conn_ptr)
    @lock conn.server.connections_lock begin
        delete!(conn.server.connections, conn)
    end
    return
end

const on_incoming_request = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_request(aws_conn, conn_ptr)
    conn = unsafe_pointer_to_objref(conn_ptr)
    conn.current_request = Request()
    conn.current_request.headers = Headers()
    conn.current_request.context = Context()
    return aws_http_stream_new_server_request_handler(
        FieldRef(conn, :request_handler_options)
    )
end

const on_request_headers = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_request_headers(stream, header_block, header_array::Ptr{aws_http_header}, num_headers, conn_ptr)
    conn = unsafe_pointer_to_objref(conn_ptr)
    for i = 1:num_headers
        header = unsafe_load(header_array, i)
        name = unsafe_string(header.name.ptr, header.name.len)
        value = unsafe_string(header.value.ptr, header.value.len)
        push!(conn.current_request.headers, name => value)
    end
    return Cint(0)
end

const on_request_header_block_done = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_request_header_block_done(stream, header_block, conn_ptr)
    conn = unsafe_pointer_to_objref(conn_ptr)
    method_ref = Ref{aws_byte_cursor}()
    ret = aws_http_stream_get_incoming_request_method(stream, method_ref)
    conn.current_request.method = str(method_ref[])
    url_ref = Ref{aws_byte_cursor}()
    ret = aws_http_stream_get_incoming_request_uri(stream, url_ref)
    uri_ref = Ref{aws_uri}()
    aws_uri_init_parse(uri_ref, conn.allocator, url_ref)
    u = conn.current_request._uri = uri_ref[]
    conn.current_request.uri = makeuri(u)
    # prep request body
    buf = Vector{UInt8}(undef, 0)
    conn.current_request.body = writebuf(buf)
    return Cint(0)
end

const on_request_body = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_request_body(stream, data::Ptr{aws_byte_cursor}, conn_ptr)
    conn = unsafe_pointer_to_objref(conn_ptr)
    bc = unsafe_load(data)
    body = conn.current_request.body
    try
        @assert hasroom(body, bc.len) "body buffer too small"
        unsafe_write(body, bc.ptr, bc.len)
        return Cint(0)
    catch
        @error "failed to write request body" exception=(exception, Base.catch_stack())
        return Cint(-1)
    end
end

const on_request_done = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_request_done(stream, conn_ptr)
    conn = unsafe_pointer_to_objref(conn_ptr)
    conn.current_request.body = take!(conn.current_request.body)
    try
        resp = fetch(Threads.@spawn(conn.f(conn.current_request)::Response))
        aws_resp = conn.current_response = aws_http_message_new_response(conn.allocator)
        aws_http_message_set_response_status(aws_resp, resp.status % Cint)
        for (k, v) in resp.headers
            header = aws_http_header(aws_byte_cursor_from_c_str(string(k)), aws_byte_cursor_from_c_str(string(v)), AWS_HTTP_HEADER_COMPRESSION_USE_CACHE)
            aws_http_message_add_header(aws_resp, header)
        end
        #TODO: handle other response body types
        len = sizeof(resp.body)
        cbody = Ref(aws_byte_cursor(len, pointer(resp.body)))
        input_stream = aws_input_stream_new_from_cursor(conn.allocator, cbody)
        aws_http_message_set_body_stream(aws_resp, input_stream)
        aws_http_message_add_header(aws_resp, aws_http_header(aws_byte_cursor_from_c_str("content-length"), aws_byte_cursor_from_c_str(string(len)), AWS_HTTP_HEADER_COMPRESSION_USE_CACHE))
        @assert aws_http_stream_send_response(stream, aws_resp) == 0
    catch e
        @error "failed to process request" exception=(e, catch_backtrace())
        return Cint(-1)
    end
    return Cint(0)
end

const on_server_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_server_complete(stream, error_code, conn_ptr)
    conn = unsafe_pointer_to_objref(conn_ptr)
    aws_http_message_destroy(conn.current_response)
    return Cint(0)
end

const on_destroy_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_destroy_complete(server_ptr)
    server = unsafe_pointer_to_objref(server_ptr)
    put!(server.comm, :destroyed)
    return
end

function Base.close(server::Server)
    state = @atomicswap server.state = :closed
    if state == :running
        aws_http_server_release(server.server)
        @assert take!(server.comm) == :destroyed
        notify(server.closed)
    end
    return
end

Base.isopen(server::Server) = @atomic(server.state) != :closed
