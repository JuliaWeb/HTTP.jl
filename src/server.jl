function server_tlsoptions(;
    ssl_cert=nothing,
    ssl_key=nothing,
    ssl_capath=nothing,
    ssl_cacert=nothing,
    ssl_insecure=false,
    ssl_alpn_list="h2;http/1.1",
    )
    alpn_list = _normalize_alpn_list(ssl_alpn_list)
    if ssl_cert !== nothing && ssl_key !== nothing
        ctx_opts = Reseau.Sockets.tls_ctx_options_init_default_server_from_path(ssl_cert, ssl_key; alpn_list=alpn_list)
    elseif Sys.iswindows() && ssl_cert !== nothing && ssl_key === nothing
        ctx_opts = Reseau.Sockets.tls_ctx_options_init_default_server_from_system_path(ssl_cert)
    else
        throw(ArgumentError("ssl_cert and ssl_key are required for TLS server"))
    end
    if ssl_capath !== nothing || ssl_cacert !== nothing
        Reseau.Sockets.tls_ctx_options_override_default_trust_store_from_path!(ctx_opts;
            ca_path=ssl_capath, ca_file=ssl_cacert)
    end
    if ssl_insecure
        Reseau.Sockets.tls_ctx_options_set_verify_peer!(ctx_opts, false)
    end
    ctx = Reseau.Sockets.tls_server_ctx_new(ctx_opts)
    return Reseau.Sockets.TlsConnectionOptions(ctx; alpn_list=alpn_list)
end

const _BACKLOG_DEFAULT = 511

mutable struct Connection{S}
    const server::S # Server{F, C}
    const h1conn::Any # AwsHTTP.H1Connection or AwsHTTP.H2Connection
    const channel::Any # Reseau.Channel
    const streams_lock::ReentrantLock
    const streams::Set{Stream}
    const remote_addr::String
    const remote_port_num::Int

    Connection(server::S, h1conn, channel, remote_addr::String, remote_port_num::Int) where {S} =
        new{S}(server, h1conn, channel, ReentrantLock(), Set{Stream}(), remote_addr, remote_port_num)
end

Base.hash(c::Connection, h::UInt) = hash(objectid(c), h)

remote_address(c::Connection) = c.remote_addr
remote_port(c::Connection) = c.remote_port_num
function http_version(c::Connection)
    v = AwsHTTP.http_connection_get_version(c.h1conn)
    return v == AwsHTTP.HttpVersion.HTTP_2 ? "HTTP/2" : "HTTP/1.1"
end

mutable struct Server{F, C}
    const f::F
    const on_stream_complete::C
    const on_shutdown::Any
    const fut::Future{Symbol}
    const connections_lock::ReentrantLock
    const connections::Set{Connection}
    const closed::Threads.Event
    const access_log::Union{Nothing, Function}
    const stream::Bool
    const logstate::Base.CoreLogging.LogState
    @atomic state::Symbol # :initializing, :running, :closed
    bootstrap::Any # Reseau.ServerBootstrap
    bound_port::Int

    Server{F, C}(
        f::F,
        on_stream_complete::C,
        on_shutdown::Any,
        fut::Future{Symbol},
        connections_lock::ReentrantLock,
        connections::Set{Connection},
        closed::Threads.Event,
        access_log::Union{Nothing, Function},
        stream::Bool,
        logstate::Base.CoreLogging.LogState,
        state::Symbol,
    ) where {F, C} = new{F, C}(f, on_stream_complete, on_shutdown, fut, connections_lock, connections, closed, access_log, stream, logstate, state)
end

Base.wait(s::Server) = wait(s.closed)
ftype(::Server{F}) where {F} = F
port(s::Server) = s.bound_port

shutdown(fns::Vector{<:Function}) = foreach(shutdown, fns)
shutdown(::Nothing) = nothing
function shutdown(fn::Function)
    try
        fn()
    catch e
        @error "shutdown function failed" exception=(e, catch_backtrace())
    end
    return
end

function _future_done(f::Future)
    return (@atomic f.set) != 0
end

function _should_log_stream_error(error_code::Integer)::Bool
    error_code == 0 && return false
    error_code == AwsHTTP.ERROR_HTTP_CONNECTION_CLOSED && return false
    error_code == AwsHTTP.ERROR_HTTP_STREAM_CANCELLED && return false
    error_code == AwsHTTP.ERROR_HTTP_SERVER_CLOSED && return false
    error_code == AwsHTTP.ERROR_HTTP_SWITCHED_PROTOCOLS && return false
    error_code == AwsHTTP.ERROR_HTTP_GOAWAY_RECEIVED && return false
    error_code == AwsHTTP.ERROR_HTTP_RST_STREAM_RECEIVED && return false
    error_code == Reseau.EventLoops.ERROR_IO_SOCKET_CLOSED && return false
    error_code == Reseau.EventLoops.ERROR_IO_BROKEN_PIPE && return false
    error_code == Reseau.EventLoops.ERROR_IO_OPERATION_CANCELLED && return false
    return true
end

function _should_log_channel_shutdown_error(error_code::Integer)::Bool
    error_code == 0 && return false
    error_code == AwsHTTP.ERROR_HTTP_CONNECTION_CLOSED && return false
    error_code == AwsHTTP.ERROR_HTTP_SERVER_CLOSED && return false
    error_code == Reseau.EventLoops.ERROR_IO_SOCKET_CLOSED && return false
    error_code == Reseau.EventLoops.ERROR_IO_BROKEN_PIPE && return false
    error_code == Reseau.EventLoops.ERROR_IO_OPERATION_CANCELLED && return false
    return true
end

function _create_request_handler!(conn::Connection, aws_conn; http2::Bool=false)
    server = conn.server
    http_conn = aws_conn
    stream = Stream{typeof(conn)}(nothing, http2, true)
    stream.connection = conn
    stream.request = Request("", "", nothing, nothing, http2)

    on_request_headers = (aws_stream, header_block, headers_vec, user_data) -> begin
        if header_block == AwsHTTP.HttpHeaderBlock.TRAILING
            trailers = stream.request.trailers
            if trailers === nothing
                trailers = Headers()
                stream.request.trailers = trailers
            end
            for h in headers_vec
                addheader(trailers, h.name, h.value)
            end
        else
            hdrs = stream.request.headers
            for h in headers_vec
                if stream.http2 && !isempty(h.name) && h.name[1] == ':'
                    if h.name == ":scheme" || h.name == ":authority" || h.name == ":protocol"
                        addheader(hdrs, h.name, h.value)
                        if h.name == ":authority" && !hasheader(hdrs, "host")
                            addheader(hdrs, "host", h.value)
                        end
                    end
                else
                    addheader(hdrs, h.name, h.value)
                end
            end
        end
        return AwsHTTP.OP_SUCCESS
    end

    on_request_header_block_done = (aws_stream, header_block, user_data) -> begin
        if header_block != AwsHTTP.HttpHeaderBlock.MAIN
            return AwsHTTP.OP_SUCCESS
        end
        method = AwsHTTP.http_stream_get_incoming_request_method(aws_stream)
        path = AwsHTTP.http_stream_get_incoming_request_uri(aws_stream)
        method === nothing && (method = "")
        path === nothing && (path = "")
        stream.request.method = method
        stream.request.path = path
        notify(stream.headers_ready)
        if server.stream && !stream.handler_started
            stream.handler_started = true
            stream.bufferstream === nothing && (stream.bufferstream = Base.BufferStream())
            Threads.@spawn begin
                Base.CoreLogging.with_logstate(server.logstate) do
                    try
                        Base.invokelatest(server.f, stream)
                    catch e
                        @error "Request handler error; sending 500" exception=(e, catch_backtrace())
                        if !stream.response_started
                            try setstatus(stream, 500) catch; end
                        end
                    finally
                        try closewrite(stream) catch; end
                    end
                end
            end
        end
        return AwsHTTP.OP_SUCCESS
    end

    on_request_body = (aws_stream, data, user_data) -> begin
        if server.stream
            stream.bufferstream === nothing && (stream.bufferstream = Base.BufferStream())
            write(stream.bufferstream, data)
            return AwsHTTP.OP_SUCCESS
        end
        body = stream.request.body
        if body === nothing
            stream.request.body = copy(data)
        else
            append!(body, data)
        end
        return AwsHTTP.OP_SUCCESS
    end

    on_request_done = (aws_stream, user_data) -> begin
        if server.stream
            Base.CoreLogging.with_logstate(server.logstate) do
                stream.bufferstream !== nothing && close(stream.bufferstream)
            end
            return
        end
        errormonitor(Threads.@spawn begin
            Base.CoreLogging.with_logstate(server.logstate) do
                try
                    stream.response = Base.invokelatest(server.f, stream.request)::Response
                    if stream.request.method == "HEAD"
                        _head_response!(stream.response)
                    end
                catch e
                    @error "Request handler error; sending 500" exception=(e, catch_backtrace())
                    stream.response = Response(500)
                end
                _send_response!(stream)
            end
        end)
        return
    end

    on_complete = (aws_stream, error_code, user_data) -> begin
        stream.released && return
        stream.released = true
        Base.CoreLogging.with_logstate(server.logstate) do
            if _should_log_stream_error(error_code)
                @error "server stream complete error" error_code
            end
            if server.on_stream_complete !== nothing
                try
                    Base.invokelatest(server.on_stream_complete, stream)
                catch e
                    @error "on_stream_complete error" exception=(e, catch_backtrace())
                end
            end
            if stream.on_complete !== nothing
                try
                    Base.invokelatest(stream.on_complete, stream)
                catch e
                    @error "stream on_complete error" exception=(e, catch_backtrace())
                end
                stream.on_complete = nothing
            end
            if server.access_log !== nothing
                try
                    if isdefined(stream, :request) && isdefined(stream, :response)
                        @info sprint(server.access_log, stream) _group=:access
                    end
                catch e
                    @error "access log error" exception=(e, catch_backtrace())
                end
            end
            shutdown_channel = false
            @lock conn.streams_lock begin
                delete!(conn.streams, stream)
                if @atomic(server.state) == :closing && isempty(conn.streams)
                    shutdown_channel = true
                end
            end
            if shutdown_channel
                Reseau.Sockets.channel_shutdown!(conn.channel; shutdown_immediately=true)
                @lock server.connections_lock begin
                    delete!(server.connections, conn)
                end
            end
            # HTTP pipelining: create next request handler if connection allows
            if !stream.http2 && AwsHTTP.http_connection_new_requests_allowed(http_conn)
                _create_request_handler!(conn, http_conn; http2=false)
            end
        end
        return
    end

    on_destroy = (user_data) -> nothing

    opts = AwsHTTP.HttpRequestHandlerOptions(
        http_conn,
        nothing,
        on_request_headers,
        on_request_header_block_done,
        on_request_body,
        on_request_done,
        on_complete,
        on_destroy,
    )
    if http2
        h2stream = AwsHTTP.h2_stream_new_request_handler(http_conn, opts; manual_write=server.stream)
        stream.aws_stream = h2stream
        @lock conn.streams_lock begin
            push!(conn.streams, stream)
        end
        return h2stream
    end
    h1stream = AwsHTTP.http_connection_new_request_handler(http_conn, opts)
    if h1stream === nothing
        @error "failed to create request handler stream"
        return
    end
    stream.aws_stream = h1stream
    AwsHTTP.h1_stream_activate!(h1stream)
    @lock conn.streams_lock begin
        push!(conn.streams, stream)
    end
    return
end

function _warn_unsupported_server_options(; reuseaddr::Bool, backlog::Integer)
    reuseaddr && @warn "reuseaddr is not supported by the Reseau server; ignoring"
    backlog != _BACKLOG_DEFAULT && @warn "backlog is not supported by the Reseau server; ignoring"
    return
end

function _stop_new_requests!(conn::Connection)
    AwsHTTP.http_connection_stop_new_requests(conn.h1conn)
    if AwsHTTP.http_connection_get_version(conn.h1conn) == AwsHTTP.HttpVersion.HTTP_2
        try
            AwsHTTP.h2_connection_send_goaway!(conn.h1conn; allow_more_streams=false)
        catch
        end
    end
    return
end

function serve!(f, host="127.0.0.1", port=8080;
    on_stream_complete=nothing,
    on_shutdown=nothing,
    access_log::Union{Nothing, Function}=nothing,
    stream::Bool=false,
    listenany::Bool=false,
    reuseaddr::Bool=false,
    backlog::Integer=_BACKLOG_DEFAULT,
    # socket options
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
    _ensure_resources!()
    _warn_unsupported_server_options(; reuseaddr=reuseaddr, backlog=backlog)
    host_str = string(host)
    # `listenany=true` should pick an ephemeral port (port=0), avoiding collisions
    # with any existing process bound to the default `port` (e.g. 8080).
    port_int = listenany ? 0 : Int(port)
    tls_conn_opts = if tls_options !== nothing
        tls_options
    elseif any(x -> x !== nothing, (ssl_cert, ssl_key, ssl_capath, ssl_cacert))
        server_tlsoptions(;
            ssl_cert, ssl_key, ssl_capath, ssl_cacert, ssl_insecure, ssl_alpn_list
        )
    else
        nothing
    end
    server = Server{typeof(f), typeof(on_stream_complete)}(
        f,
        on_stream_complete,
        on_shutdown,
        Future{Symbol}(),
        ReentrantLock(),
        Set{Connection}(),
        Threads.Event(),
        access_log,
        stream,
        Base.CoreLogging.current_logstate(),
        :initializing,
    )
    server.bound_port = port_int
    listener_ready = Threads.Event()
    socket_opts = Reseau.Sockets.SocketOptions(;
        domain = socket_domain == :ipv4 ? Reseau.Sockets.SocketDomain.IPV4 : Reseau.Sockets.SocketDomain.IPV6,
        connect_timeout_ms = connect_timeout_ms,
        keep_alive_interval_sec = keep_alive_interval_sec,
        keep_alive_timeout_sec = keep_alive_timeout_sec,
        keep_alive_max_failed_probes = keep_alive_max_failed_probes,
        keepalive = keepalive,
    )
    alpn_list = _tls_alpn_list(tls_conn_opts)
    initial_window = Csize_t(min(UInt64(initial_window_size), UInt64(typemax(Csize_t))))
    on_incoming_channel_setup = (bootstrap, error_code, channel, user_data) -> begin
        Base.CoreLogging.with_logstate(server.logstate) do
            if error_code != 0
                @error "incoming channel setup error" error_code
                return
            end
            st = @atomic(server.state)
            if st == :closing || st == :closed
                Reseau.Sockets.channel_shutdown!(channel; shutdown_immediately=true)
                return
            end
            slot = Reseau.Sockets.channel_slot_new!(channel)
            Reseau.Sockets.channel_slot_insert_end!(channel, slot)
            version = AwsHTTP.HttpVersion.HTTP_1_1
            if tls_conn_opts !== nothing
                tls_slot = slot.adj_left
                if tls_slot === nothing || tls_slot.handler === nothing || !(tls_slot.handler isa Reseau.Sockets.TlsChannelHandler)
                    @error "incoming channel setup error" error_code=Reseau.ERROR_INVALID_STATE
                    Reseau.Sockets.channel_shutdown!(channel, Reseau.ERROR_INVALID_STATE)
                    return
                end
                protocol = Reseau.Sockets.tls_handler_protocol(tls_slot.handler)
                if protocol.len > 0
                    protocol_str = Reseau.byte_buffer_as_string(protocol)
                    if protocol_str == "h2"
                        version = AwsHTTP.HttpVersion.HTTP_2
                    elseif protocol_str == "http/1.1"
                        version = AwsHTTP.HttpVersion.HTTP_1_1
                    end
                end
            end
            http_conn = AwsHTTP.http_connection_new_channel_handler(;
                is_server=true,
                version=version,
                initial_window_size=initial_window,
            )
            http_conn === nothing && return
            Reseau.Sockets.channel_slot_set_handler!(slot, http_conn)
            http_conn.slot = slot
            # Extract remote endpoint from the socket handler (first slot in pipeline)
            remote_addr = "0.0.0.0"
            remote_port_num = 0
            try
                socket_handler = channel.first.handler
                ep = socket_handler.socket.remote_endpoint
                remote_addr = Reseau.Sockets.get_address(ep)
                remote_port_num = Int(ep.port)
            catch
            end
            http_conn.remote_endpoint = "$remote_addr:$remote_port_num"
            conn = Connection(server, http_conn, channel, remote_addr, remote_port_num)
            @lock server.connections_lock begin
                push!(server.connections, conn)
            end
            if AwsHTTP.http_connection_get_version(http_conn) == AwsHTTP.HttpVersion.HTTP_2
                opts = AwsHTTP.HttpServerConnectionOptions(
                    connection_user_data = conn,
                    on_incoming_request = (h2conn, ud) -> begin
                        try
                            return _create_request_handler!(ud, h2conn; http2=true)
                        catch e
                            @error "failed to create HTTP/2 request handler" exception=(e, catch_backtrace())
                            return nothing
                        end
                    end,
                    on_shutdown = (h2conn, err, ud) -> nothing,
                )
                status = AwsHTTP.http_connection_configure_server(http_conn, opts)
                if status != AwsHTTP.OP_SUCCESS
                    @error "failed to configure HTTP/2 server connection" error_code=status
                    return
                end
            else
                _create_request_handler!(conn, http_conn; http2=false)
            end
            if Reseau.Sockets.channel_thread_is_callers_thread(channel)
                Reseau.Sockets.channel_trigger_read(channel)
            else
                task = Reseau.Sockets.ChannelTask(Reseau.EventCallable(status -> begin
                    Reseau.TaskStatus.T(status) == Reseau.TaskStatus.RUN_READY || return nothing
                    Reseau.Sockets.channel_trigger_read(channel)
                    return nothing
                end), "http_server_trigger_read")
                Reseau.Sockets.channel_schedule_task_now!(channel, task)
            end
        end
        return
    end
    on_incoming_channel_shutdown = (bootstrap, error_code, channel, user_data) -> begin
        Base.CoreLogging.with_logstate(server.logstate) do
            if _should_log_channel_shutdown_error(error_code)
                @error "incoming channel shutdown error" error_code
            end
            @lock server.connections_lock begin
                filter!(c -> c.channel !== channel, server.connections)
            end
        end
        return
    end
    on_listener_destroy = (bootstrap, user_data) -> begin
        notify(server.fut, :destroyed)
        return
    end
    bs = Reseau.Sockets.ServerBootstrap(;
        event_loop_group = _EVENT_LOOP_GROUP[],
        socket_options = socket_opts,
        host = host_str,
        port = UInt32(port_int),
        tls_connection_options = tls_conn_opts,
        on_protocol_negotiated = nothing,
        on_listener_setup = (bootstrap, error_code, user_data) -> begin
            if error_code == 0 && bootstrap.listener_socket !== nothing
                server.bound_port = try
                    ep = Reseau.Sockets.socket_get_bound_address(bootstrap.listener_socket)
                    Int(ep.port)
                catch
                    port_int
                end
            else
                server.bound_port = port_int
            end
            notify(listener_ready)
            return nothing
        end,
        on_incoming_channel_setup = on_incoming_channel_setup,
        on_incoming_channel_shutdown = on_incoming_channel_shutdown,
        on_listener_destroy = on_listener_destroy,
        user_data = server,
        enable_read_back_pressure = false,
    )
    server.bootstrap = bs
    # Wait until the listener is ready so `port(server)` is accurate immediately.
    wait(listener_ready)
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
    pad_length < 0 && throw(ArgumentError("pad_length must be >= 0"))
    pad_length > typemax(UInt8) && throw(ArgumentError("pad_length must be <= $(typemax(UInt8))"))
    isdefined(parent, :aws_stream) || throw(ArgumentError("HTTP stream is not initialized"))
    _push_promise_headers!(req, parent; scheme=scheme, authority=authority)
    msg = getfield(req, :msg)
    if AwsHTTP.http_message_get_protocol_version(msg) != AwsHTTP.HttpVersion.HTTP_2
        converted = AwsHTTP.http2_message_new_from_http1(msg)
        converted === nothing && throw(AWSError("Failed to convert push promise request to HTTP/2"))
        setfield!(req, :msg, converted)
        msg = converted
    end
    h2conn = parent.aws_stream.owning_connection
    h2conn === nothing && throw(ArgumentError("HTTP/2 connection is not initialized"))
    promised_id = h2conn.next_stream_id
    promised_id > AwsHTTP.H2_STREAM_ID_MAX && throw(AWSError("HTTP/2 stream IDs exhausted"))
    h2conn.next_stream_id += UInt32(2)
    h2stream = _create_request_handler!(parent.connection, h2conn; http2=true)
    h2stream === nothing && throw(AWSError("Failed to create push promise stream"))
    push_stream = nothing
    @lock parent.connection.streams_lock begin
        for s in parent.connection.streams
            if s.aws_stream === h2stream
                push_stream = s
                break
            end
        end
    end
    push_stream === nothing && throw(AWSError("Failed to locate push promise stream"))
    push_stream.request = req
    notify(push_stream.headers_ready)
    method_val = req.method
    path_val = req.path
    method_val === nothing && (method_val = "")
    path_val === nothing && (path_val = "")
    h2stream.id = promised_id
    AwsHTTP.h2_stream_init_window_sizes!(h2stream, h2conn)
    h2stream.metrics = AwsHTTP.HttpStreamMetrics(
        h2stream.metrics.send_start_timestamp_ns,
        h2stream.metrics.send_end_timestamp_ns,
        h2stream.metrics.sending_duration_ns,
        h2stream.metrics.receive_start_timestamp_ns,
        h2stream.metrics.receive_end_timestamp_ns,
        h2stream.metrics.receiving_duration_ns,
        promised_id,
    )
    h2stream.state = AwsHTTP.H2StreamState.RESERVED_LOCAL
    h2stream.request_method = AwsHTTP.http_str_to_method(String(method_val))
    h2stream.request_method_str = String(method_val)
    h2stream.request_path = String(path_val)
    h2conn.active_streams[promised_id] = h2stream
    headers = AwsHTTP.http_message_get_headers(msg)
    status = AwsHTTP.h2_stream_send_push_promise!(parent.aws_stream, h2conn, promised_id, headers;
        pad_length=UInt8(pad_length))
    if status != AwsHTTP.OP_SUCCESS
        delete!(h2conn.active_streams, promised_id)
        @lock parent.connection.streams_lock begin
            delete!(parent.connection.streams, push_stream)
        end
        throw(AWSError("Failed to send push promise"))
    end
    return push_stream
end

function push_promise(parent::Stream, method::Union{String, Symbol}, path; headers=Header[], pad_length::Integer=0, scheme=nothing, authority=nothing)
    return push_promise(parent, Request(String(method), String(path), headers, nothing, true); pad_length=pad_length, scheme=scheme, authority=authority)
end

function _forceclose!(server::Server; skip_shutdown::Bool=false)
    skip_shutdown || shutdown(server.on_shutdown)
    Reseau.Sockets.server_bootstrap_shutdown!(server.bootstrap)
    conns = Connection[]
    @lock server.connections_lock begin
        append!(conns, server.connections)
    end
    for conn in conns
        Reseau.Sockets.channel_shutdown!(conn.channel; shutdown_immediately=true)
    end
    @atomic server.state = :closed
    notify(server.closed)
    return
end

function Base.close(server::Server)
    state = @atomicswap server.state = :closing
    if state == :closed
        return
    elseif state == :closing
        wait(server.closed)
        return
    end
    shutdown(server.on_shutdown)
    Reseau.Sockets.server_bootstrap_shutdown!(server.bootstrap)
    conns = Connection[]
    @lock server.connections_lock begin
        append!(conns, server.connections)
    end
    for conn in conns
        _stop_new_requests!(conn)
        @lock conn.streams_lock begin
            if isempty(conn.streams)
                Reseau.Sockets.channel_shutdown!(conn.channel; shutdown_immediately=true)
                @lock server.connections_lock begin
                    delete!(server.connections, conn)
                end
            end
        end
    end
    deadline = time() + 0.5
    while time() < deadline
        empty = @lock server.connections_lock begin
            isempty(server.connections)
        end
        if empty
            @atomic server.state = :closed
            notify(server.closed)
            return
        end
        _task_sleep_s(0.05)
    end
    _forceclose!(server; skip_shutdown=true)
    return
end

function forceclose(server::Server)
    state = @atomicswap server.state = :closed
    state == :closed && return
    _forceclose!(server; skip_shutdown = state == :closing)
    return
end

Base.isopen(server::Server) = @atomic(server.state) == :running
