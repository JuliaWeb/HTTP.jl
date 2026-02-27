# HTTP Client Bootstrap - Connection setup and ALPN-based handler creation
# Port of aws-c-http/source/connection.c (client connect flow)

# ─── http_connection_get_channel dispatches ───

http_connection_get_channel(conn::H1Connection) = conn.slot !== nothing ? conn.slot.channel : nothing
http_connection_get_channel(conn::H2Connection) = conn.slot !== nothing ? conn.slot.channel : nothing

# ─── Connection channel handler creation ───

"""
    http_connection_new_channel_handler(; is_server, version, ...) -> Union{H1Connection, H2Connection, Nothing}

Create the appropriate HTTP connection handler (H1 or H2) based on the negotiated version.
This is the factory function called during ALPN negotiation or direct connection setup.
"""
function http_connection_new_channel_handler(;
    is_server::Bool,
    version::HttpVersion.T,
    manual_window_management::Bool = false,
    initial_window_size::Csize_t = Csize_t(typemax(Csize_t)),
    on_shutdown = nothing,
    response_first_byte_timeout_ms::UInt64 = UInt64(0),
    read_buffer_capacity::Csize_t = Csize_t(0),
    h2c_upgrade::Bool = false,
)
    if version == HttpVersion.HTTP_1_1
        if is_server
            return h1_connection_new_server(;
                manual_window_management,
                initial_window_size,
                read_buffer_capacity,
                on_shutdown,
            )
        else
            return h1_connection_new_client(;
                manual_window_management,
                initial_window_size,
                read_buffer_capacity,
                on_shutdown,
                response_first_byte_timeout_ms,
                h2c_upgrade,
            )
        end
    elseif version == HttpVersion.HTTP_2
        return h2_connection_new(;
            is_client = !is_server,
            manual_window_management,
            initial_window_size = UInt32(min(initial_window_size, typemax(UInt32))),
            on_shutdown,
        )
    else
        return nothing
    end
end

# ─── Client connection bootstrap ───

"""
    http_client_connect(options::HttpClientConnectionOptions) -> Nothing

Initiate an asynchronous HTTP client connection. When the connection is established,
`on_setup` is called with the connection object. On failure, `on_setup`
is called with `nothing` and an error code.

The ALPN protocol negotiated during TLS determines whether an HTTP/1.1 or HTTP/2
connection handler is created. If `prior_knowledge_http2` is set, HTTP/2 is used
without ALPN negotiation.
"""
function http_client_connect(options::HttpClientConnectionOptions; on_setup=nothing, on_shutdown=nothing)
    event_loop_group = options.event_loop_group === nothing ? EventLoops.get_event_loop_group() : options.event_loop_group
    if !(event_loop_group isa EventLoops.EventLoopGroup)
        event_loop_group = EventLoops.get_event_loop_group()
    end

    # Build the ALPN map
    alpn_map = if options.alpn_string_map !== nothing
        http_alpn_map_init_copy(options.alpn_string_map)
    else
        http_alpn_map_init()
    end

    connection_ref = Ref{Union{HttpConnection, Nothing}}(nothing)

    setup_cb = on_setup
    shutdown_cb = on_shutdown

    # on_channel_setup: fires when the channel is fully set up (after TLS + ALPN).
    on_channel_setup = (error_code, channel) -> begin
        Reseau.logf(Reseau.LogLevel.DEBUG, LS_HTTP_CONNECTION, "http_client_connect on_setup wrapper invoked err=$(error_code)")
        if error_code != Reseau.OP_SUCCESS
            if setup_cb !== nothing
                _invoke_user_callback(setup_cb, nothing, error_code; label = "on_setup")
            end
            return nothing
        end

        if connection_ref[] === nothing
            negotiated_protocol = Sockets.negotiated_protocol(channel)
            slot = Sockets.channel_slot_new!(channel)
            Sockets.channel_slot_insert_end!(channel, slot)
            local version
            try
                version = _http_select_version(
                    options.tls_connection_options !== nothing,
                    options.prior_knowledge_http2,
                    alpn_map,
                    negotiated_protocol,
                )
            catch e
                err = e isa Reseau.ReseauError ? e.code : Reseau.ERROR_UNKNOWN
                Sockets.channel_shutdown!(channel, err)
                if setup_cb !== nothing
                    _invoke_user_callback(setup_cb, nothing, err; label = "on_setup")
                end
                return nothing
            end
            if version == HttpVersion.UNKNOWN
                err = ERROR_HTTP_UNSUPPORTED_PROTOCOL
                Sockets.channel_shutdown!(channel, err)
                if setup_cb !== nothing
                    _invoke_user_callback(setup_cb, nothing, err; label = "on_setup")
                end
                return nothing
            end
            handler = http_connection_new_channel_handler(;
                is_server = false,
                version,
                manual_window_management = options.manual_window_management,
                initial_window_size = options.initial_window_size,
                on_shutdown = shutdown_cb !== nothing ?
                    (conn, err) -> _invoke_user_callback(shutdown_cb, conn, err; label = "on_shutdown") : nothing,
                response_first_byte_timeout_ms = options.response_first_byte_timeout_ms,
                read_buffer_capacity = options.read_buffer_capacity,
                h2c_upgrade = options.h2c_upgrade,
            )
            if handler === nothing
                err = ERROR_HTTP_UNSUPPORTED_PROTOCOL
                Sockets.channel_shutdown!(channel, err)
                if setup_cb !== nothing
                    _invoke_user_callback(setup_cb, nothing, err; label = "on_setup")
                end
                return nothing
            end
            connection_ref[] = handler
            Sockets.channel_slot_set_handler!(slot, handler)
        end

        conn = connection_ref[]
        if conn !== nothing && hasproperty(conn, :remote_endpoint)
            conn.remote_endpoint = "$(options.host_name):$(options.port)"
        end
        if channel !== nothing
            if Sockets.channel_thread_is_callers_thread(channel)
                Sockets.channel_trigger_read(channel)
            else
                task = Sockets.ChannelTask(Reseau.EventCallable(status -> begin
                    Reseau.TaskStatus.T(status) == Reseau.TaskStatus.RUN_READY || return nothing
                    Sockets.channel_trigger_read(channel)
                    return nothing
                end), "http_client_trigger_read")
                Sockets.channel_schedule_task_now!(channel, task)
            end
        end

        if setup_cb !== nothing
            Reseau.logf(Reseau.LogLevel.DEBUG, LS_HTTP_CONNECTION, "http_client_connect invoking user on_setup")
            _invoke_user_callback(setup_cb, conn, Reseau.OP_SUCCESS; label = "on_setup")
        else
            Reseau.logf(Reseau.LogLevel.DEBUG, LS_HTTP_CONNECTION, "http_client_connect user on_setup is nothing")
        end
        return nothing
    end

    try
        return Sockets.client_bootstrap_connect!(
            on_channel_setup,
            options.host_name,
            options.port;
            socket_options = options.socket_options !== nothing ? options.socket_options : Sockets.SocketOptions(),
            tls_connection_options = options.tls_connection_options,
            enable_read_back_pressure = false,
            requested_event_loop = options.requested_event_loop,
            event_loop_group = event_loop_group,
        )
    catch err
        error_code = err isa Reseau.ReseauError ? err.code : Reseau.ERROR_UNKNOWN
        on_channel_setup(error_code, nothing)
        return nothing
    end
end
