# HTTP Server - Listener and connection factory
# Port of aws-c-http/include/aws/http/server.h, connection.c (server portions)

# ─── HTTP Server ───

const _ServerConnection = Union{H1Connection, H2Connection}

mutable struct HttpServer
    prior_knowledge_http2::Bool
    initial_window_size::Csize_t
    manual_window_management::Bool
    tls_connection_options::Union{Sockets.TlsConnectionOptions, Nothing}
    read_buffer_capacity::Csize_t
    connections::Vector{_ServerConnection}
    channel_map::IdDict{Sockets.Channel, _ServerConnection}
    lock::ReentrantLock
    is_open::Bool
    is_shutting_down::Bool
    listener_host::String
    listener_port::UInt32
    bootstrap::Union{Sockets.ServerBootstrap, Nothing}
    event_loop_group::EventLoops.EventLoopGroup
    owns_event_loop_group::Bool
    destroyed_event::Threads.Event
end

function _server_register_connection!(server::HttpServer, channel, connection::_ServerConnection)
    Base.@lock server.lock begin
        push!(server.connections, connection)
        server.channel_map[channel] = connection
    end
    return nothing
end

function _server_unregister_connection!(server::HttpServer, channel)::Union{_ServerConnection, Nothing}
    conn = nothing
    Base.@lock server.lock begin
        if haskey(server.channel_map, channel)
            conn = server.channel_map[channel]
            delete!(server.channel_map, channel)
            idx = findfirst(==(conn), server.connections)
            idx !== nothing && deleteat!(server.connections, idx)
        end
    end
    return conn
end

function _server_update_listener_endpoint!(server::HttpServer)
    if server.bootstrap === nothing
        return nothing
    end
    listener = server.bootstrap.listener_socket
    listener === nothing && return nothing
    local endpoint
    try
        endpoint = Sockets.socket_get_bound_address(listener)
    catch
        return nothing
    end
    server.listener_host = Sockets.get_address(endpoint)
    server.listener_port = endpoint.port
    return nothing
end

function _server_on_channel_setup(server::HttpServer, on_incoming_connection, error_code::Int, channel)
    if error_code != Reseau.OP_SUCCESS || channel === nothing
        if on_incoming_connection !== nothing
            on_incoming_connection(server, nothing, error_code)
        end
        return nothing
    end

    server.is_shutting_down && return Sockets.channel_shutdown!(channel, ERROR_HTTP_SERVER_CLOSED)

    conn = get(server.channel_map, channel, nothing)
    if conn === nothing
        slot = Sockets.channel_slot_new!(channel)
        Sockets.channel_slot_insert_end!(channel, slot)
        local version
        try
            version = _http_select_version(
                server.tls_connection_options !== nothing,
                server.prior_knowledge_http2,
                nothing,
                Sockets.negotiated_protocol(channel),
            )
        catch e
            err = e isa Reseau.ReseauError ? e.code : Reseau.ERROR_UNKNOWN
            Sockets.channel_shutdown!(channel, err)
            return nothing
        end
        if version == HttpVersion.UNKNOWN
            Sockets.channel_shutdown!(channel, ERROR_HTTP_UNSUPPORTED_PROTOCOL)
            return nothing
        end
        handler = http_connection_new_channel_handler(
            is_server=true,
            version=version,
            manual_window_management=server.manual_window_management,
            initial_window_size=server.initial_window_size,
            read_buffer_capacity=server.read_buffer_capacity,
        )
        handler === nothing && return Sockets.channel_shutdown!(channel, ERROR_HTTP_UNSUPPORTED_PROTOCOL)
        Sockets.channel_slot_set_handler!(slot, handler)
        _server_register_connection!(server, channel, handler)
        conn = handler
    end

    sock = channel.socket
    if sock !== nothing
        addr = Sockets.get_address(sock.remote_endpoint)
        conn.remote_endpoint = "$(addr):$(sock.remote_endpoint.port)"
    end

    if on_incoming_connection !== nothing
        try
            on_incoming_connection(server, conn, Reseau.OP_SUCCESS)
        catch e
            @error "on_incoming_connection callback error" exception=(e, catch_backtrace())
        end
    end

    if !conn.server_configured
        Sockets.channel_shutdown!(channel, ERROR_HTTP_REACTION_REQUIRED)
        return nothing
    end

    return nothing
end

function _server_on_channel_shutdown(server::HttpServer, error_code::Int, channel)
    conn = _server_unregister_connection!(server, channel)
    if conn !== nothing && conn.on_shutdown !== nothing
        try
            conn.on_shutdown(conn, error_code)
        catch e
            @error "on_shutdown callback error" exception=(e, catch_backtrace())
        end
    end
    return nothing
end

function _server_on_listener_destroy(server::HttpServer, on_destroy_complete)
    server.is_open = false
    if on_destroy_complete !== nothing
        try
            on_destroy_complete()
        catch e
            @error "server destroy callback error" exception=(e, catch_backtrace())
        end
    end
    server.destroyed_event !== nothing && notify(server.destroyed_event)
    if server.owns_event_loop_group && server.event_loop_group !== nothing
        close(server.event_loop_group)
    end
    return nothing
end

"""
    http_server_new(; kwargs...) -> HttpServer

Create a new HTTP server with the given options.
"""
function http_server_new(;
    endpoint_host::String="0.0.0.0",
    endpoint_port::UInt32=UInt32(0),
    prior_knowledge_http2::Bool=false,
    initial_window_size::Csize_t=typemax(Csize_t),
    manual_window_management::Bool=false,
    event_loop_group::Union{EventLoops.EventLoopGroup, Nothing}=nothing,
    socket_options::Sockets.SocketOptions=Sockets.SocketOptions(),
    tls_connection_options::Union{Sockets.TlsConnectionOptions, Nothing}=nothing,
    read_buffer_capacity::Csize_t=Csize_t(0),
    on_incoming_connection=nothing,
    on_destroy_complete=nothing,
)
    if on_incoming_connection === nothing
        raise_error(ERROR_INVALID_ARGUMENT)
        error("on_incoming_connection is required")
    end
    if prior_knowledge_http2 && tls_connection_options !== nothing
        raise_error(ERROR_INVALID_ARGUMENT)
        error("HTTP/2 prior knowledge only works with cleartext TCP")
    end

    elg = event_loop_group
    owns_elg = false
    if elg === nothing
        elg = EventLoops.EventLoopGroup()
        owns_elg = true
    end

    server = HttpServer(
        prior_knowledge_http2,
        initial_window_size,
        manual_window_management,
        tls_connection_options,
        read_buffer_capacity,
        _ServerConnection[],
        IdDict{Sockets.Channel, _ServerConnection}(),
        ReentrantLock(),
        true,
        false,
        endpoint_host,
        endpoint_port,
        nothing,
        elg,
        owns_elg,
        Threads.Event(),
    )

    listener_ready = Threads.Event()
    bootstrap = Sockets.ServerBootstrap(;
        event_loop_group = elg,
        socket_options = socket_options,
        host = endpoint_host,
        port = endpoint_port,
        tls_connection_options = tls_connection_options,
        on_listener_setup = err -> begin
            _server_update_listener_endpoint!(server)
            notify(listener_ready)
        end,
        on_incoming_channel_setup = (err, channel) -> _server_on_channel_setup(server, on_incoming_connection, err, channel),
        on_incoming_channel_shutdown = (err, channel) -> _server_on_channel_shutdown(server, err, channel),
        on_listener_destroy = _ -> _server_on_listener_destroy(server, on_destroy_complete),
        enable_read_back_pressure = manual_window_management,
    )

    server.bootstrap = bootstrap
    wait(listener_ready)
    return server
end

"""
    http_server_release(server::HttpServer) -> Nothing

Release the server: close all connections and invoke destroy callback.
"""
function http_server_release(server::HttpServer)::Nothing
    if !server.is_open
        return nothing
    end
    server.is_open = false
    server.is_shutting_down = true

    Base.@lock server.lock begin
        for (ch, _) in server.channel_map
            Sockets.channel_shutdown!(ch, ERROR_HTTP_CONNECTION_CLOSED)
        end
    end

    if server.bootstrap !== nothing
        Sockets.server_bootstrap_shutdown!(server.bootstrap)
    else
        _server_on_listener_destroy(server)
    end

    return nothing
end

"""
    http_connection_configure_server(connection; on_incoming_request=nothing, on_h2c_upgrade=nothing, on_shutdown=nothing) -> Int

Configure a server connection with handler callbacks. Must be called from
the on_incoming_connection callback.
"""
function http_connection_configure_server(
    connection;
    on_incoming_request=nothing,
    on_h2c_upgrade=nothing,
    on_shutdown=nothing,
)::Int
    if http_connection_is_client(connection)
        return raise_error(ERROR_INVALID_STATE)
    end

    if connection isa H1Connection
        connection.on_incoming_request = _connection_incoming_request_callback(on_incoming_request)
        connection.on_h2c_upgrade = _connection_h2c_upgrade_callback(on_h2c_upgrade)
        connection.h2c_enabled = on_h2c_upgrade !== nothing
        connection.server_configured = true
        connection.on_shutdown = _connection_shutdown_callback(on_shutdown)
        return OP_SUCCESS
    elseif connection isa H2Connection
        connection.on_incoming_request = _connection_incoming_request_callback(on_incoming_request)
        connection.server_configured = true
        connection.on_shutdown = _connection_shutdown_callback(on_shutdown)
        return OP_SUCCESS
    end

    return raise_error(ERROR_INVALID_ARGUMENT)
end

"""
    http_connection_is_server(connection) -> Bool

Check if a connection is server-side.
"""
function http_connection_is_server(connection)::Bool
    if applicable(http_connection_is_client, connection)
        return !http_connection_is_client(connection)
    end
    return false
end

"""
    http_server_get_listener_endpoint(server) -> Tuple{String, UInt32}

Get the bound host and port of the server's listener.
"""
function http_server_get_listener_endpoint(server::HttpServer)::Tuple{String, UInt32}
    return (server.listener_host, server.listener_port)
end
