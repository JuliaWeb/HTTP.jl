const DEFAULT_CONNECT_TIMEOUT = 3000
const DEFAULT_MAX_RETRIES = 10

Base.@kwdef struct ClientSettings
    scheme::String
    host::String
    port::UInt32
    allocator::Ptr{aws_allocator} = default_aws_allocator()
    bootstrap::Ptr{aws_client_bootstrap} = default_aws_client_bootstrap()
    event_loop_group::Ptr{aws_event_loop_group} = default_aws_event_loop_group()
    socket_domain::Symbol = :ipv4
    connect_timeout_ms::Int = DEFAULT_CONNECT_TIMEOUT
    keep_alive_interval_sec::Int = 0
    keep_alive_timeout_sec::Int = 0
    keep_alive_max_failed_probes::Int = 0
    keepalive::Bool = false
    response_first_byte_timeout_ms::Int = 0
    ssl_cert::Union{Nothing, String} = nothing
    ssl_key::Union{Nothing, String} = nothing
    ssl_capath::Union{Nothing, String} = nothing
    ssl_cacert::Union{Nothing, String} = nothing
    ssl_insecure::Bool = false
    ssl_alpn_list::String = "h2;http/1.1"
    proxy_allow_env_var::Bool = true
    proxy_connection_type::Union{Nothing, Symbol} = nothing
    proxy_host::Union{Nothing, String} = nothing
    proxy_port::Union{Nothing, UInt32} = nothing
    proxy_ssl_cert::Union{Nothing, String} = nothing
    proxy_ssl_key::Union{Nothing, String} = nothing
    proxy_ssl_capath::Union{Nothing, String} = nothing
    proxy_ssl_cacert::Union{Nothing, String} = nothing
    proxy_ssl_insecure::Bool = false
    proxy_ssl_alpn_list::String = "h2;http/1.1"
    retry_partition::Union{Nothing, String} = nothing
    max_retries::Int = DEFAULT_MAX_RETRIES
    backoff_scale_factor_ms::Int = 25
    max_backoff_secs::Int = 20
    jitter_mode::aws_exponential_backoff_jitter_mode = AWS_EXPONENTIAL_BACKOFF_JITTER_DEFAULT
    retry_timeout_ms::Int = 60000
    initial_bucket_capacity::Int = 500
    max_connections::Int = 512
    max_connection_idle_in_milliseconds::Int = 60000
    connection_acquisition_timeout_ms::Int = 0
    max_pending_connection_acquisitions::Int = 0
    enable_read_back_pressure::Bool = false
    http2_prior_knowledge::Bool = false
end

ClientSettings(
    scheme::AbstractString,
    host::AbstractString,
    port::UInt32;
    # HTTP.jl 1.0 compat keywords
    connect_timeout=nothing,
    connect_timeout_ms::Int=DEFAULT_CONNECT_TIMEOUT,
    retry::Bool=true,
    retries::Integer=DEFAULT_MAX_RETRIES,
    max_retries::Integer=DEFAULT_MAX_RETRIES,
    require_ssl_verification::Bool=true,
    ssl_insecure::Bool=false,
    kw...) =
    ClientSettings(;
        scheme=String(scheme),
        host=String(host),
        port=port,
        connect_timeout_ms=(connect_timeout !== nothing ? connect_timeout * 1000 : connect_timeout_ms),
        max_retries=(retry ? (retries != DEFAULT_MAX_RETRIES ? retries : max_retries) : 0),
        ssl_insecure=(!require_ssl_verification || ssl_insecure),
        kw...)

# make a new ClientSettings object from an existing one w/ just different url values
@generated function ClientSettings(cs::ClientSettings, scheme::AbstractString, host::AbstractString, port::Integer)
    ex = :(ClientSettings(String(scheme), String(host), port % UInt32))
    for i = 4:fieldcount(ClientSettings)
        push!(ex.args, :(getfield(cs, $(Meta.quot(fieldname(ClientSettings, i))))))
    end
    return ex
end

mutable struct Client
    settings::ClientSettings
    socket_options::aws_socket_options
    tls_options::Union{Nothing, aws_tls_connection_options}
    # only 1 of proxy_options or proxy_env_settings is set
    proxy_options::Union{Nothing, aws_http_proxy_options}
    proxy_env_settings::Union{Nothing, proxy_env_var_settings}
    retry_options::aws_standard_retry_options
    retry_strategy::Ptr{aws_retry_strategy}
    conn_manager_opts::aws_http_connection_manager_options
    connection_manager::Ptr{aws_http_connection_manager}

    Client() = new()
end

Client(scheme::AbstractString, host::AbstractString, port::Integer; kw...) = Client(ClientSettings(scheme, host, port % UInt32; kw...))

function Client(cs::ClientSettings)
    client = Client()
    client.settings = cs
    # socket options
    client.socket_options = aws_socket_options(
        AWS_SOCKET_STREAM, # socket type
        cs.socket_domain == :ipv4 ? AWS_SOCKET_IPV4 : AWS_SOCKET_IPV6, # socket domain
        AWS_SOCKET_IMPL_PLATFORM_DEFAULT, # aws_socket_impl_type
        cs.connect_timeout_ms,
        cs.keep_alive_interval_sec,
        cs.keep_alive_timeout_sec,
        cs.keep_alive_max_failed_probes,
        cs.keepalive,
        ntuple(x -> Cchar(0), 16) # network_interface_name
    )
    # tls options
    if cs.scheme == "https" || cs.scheme == "wss"
        client.tls_options = LibAwsIO.tlsoptions(cs.host;
            cs.ssl_cert,
            cs.ssl_key,
            cs.ssl_capath,
            cs.ssl_cacert,
            cs.ssl_insecure,
            cs.ssl_alpn_list
        )
    else
        client.tls_options = nothing
    end
    # proxy options
    if cs.proxy_host !== nothing && cs.proxy_port !== nothing
        client.proxy_options = aws_http_proxy_options(
            cs.proxy_connection_type == :forward ? AWS_HPCT_HTTP_FORWARD : AWS_HPCT_HTTP_TUNNEL,
            aws_byte_cursor_from_c_str(cs.proxy_host),
            cs.proxy_port % UInt32,
            cs.proxy_ssl_cert === nothing ? C_NULL : LibAwsIO.tlsoptions(cs.proxy_host;
                cs.proxy_ssl_cert,
                cs.proxy_ssl_key,
                cs.proxy_ssl_capath,
                cs.proxy_ssl_cacert,
                cs.proxy_ssl_insecure,
                cs.proxy_ssl_alpn_list
            ),
            #TODO: support proxy_strategy
            C_NULL, # proxy_strategy::Ptr{aws_http_proxy_strategy}
            0, # auth_type::aws_http_proxy_authentication_type
            aws_byte_cursor_from_c_str(""), # auth_username::aws_byte_cursor
            aws_byte_cursor_from_c_str(""), # auth_password::aws_byte_cursor
        )
    elseif cs.proxy_allow_env_var
        client.proxy_env_settings = proxy_env_var_settings(
            AWS_HPEV_ENABLE,
            cs.proxy_connection_type == :forward ? AWS_HPCT_HTTP_FORWARD : AWS_HPCT_HTTP_TUNNEL,
            cs.proxy_ssl_cert === nothing ? C_NULL : LibAwsIO.tlsoptions(cs.proxy_host;
                cs.proxy_ssl_cert,
                cs.proxy_ssl_key,
                cs.proxy_ssl_capath,
                cs.proxy_ssl_cacert,
                cs.proxy_ssl_insecure,
                cs.proxy_ssl_alpn_list
            )
        )
    else
        client.proxy_options = nothing
    end
    # retry strategy
    exp_back_opts = aws_exponential_backoff_retry_options(
        cs.event_loop_group,
        cs.max_retries,
        cs.backoff_scale_factor_ms,
        cs.max_backoff_secs,
        cs.jitter_mode,
        C_NULL, # generate_random
        C_NULL, # generate_random_impl
        C_NULL, # generate_random_user_data
        C_NULL, # shutdown_options::Ptr{aws_shutdown_callback_options}
    )
    client.retry_options = aws_standard_retry_options(
        exp_back_opts,
        cs.initial_bucket_capacity
    )
    client.retry_strategy = aws_retry_strategy_new_standard(cs.allocator, FieldRef(client, :retry_options))
    client.retry_strategy == C_NULL && aws_throw_error()
    client.conn_manager_opts = aws_http_connection_manager_options(
        cs.bootstrap,
        typemax(Csize_t), # initial_window_size::Csize_t
        pointer(FieldRef(client, :socket_options)),
        cs.response_first_byte_timeout_ms,
        (cs.scheme == "https" || cs.scheme == "wss") ? pointer(FieldRef(client, :tls_options)) : C_NULL,
        cs.http2_prior_knowledge,
        C_NULL, # monitoring_options::Ptr{aws_http_connection_monitoring_options}
        aws_byte_cursor_from_c_str(cs.host),
        cs.port % UInt32,
        C_NULL, # initial_settings_array::Ptr{aws_http2_setting}
        0, # num_initial_settings::Csize_t
        0, # max_closed_streams::Csize_t
        false, # http2_conn_manual_window_management::Bool
        client.proxy_options === nothing ? C_NULL : pointer(FieldRef(client, :proxy_options)), # proxy_options::Ptr{aws_http_proxy_options}
        client.proxy_env_settings === nothing ? C_NULL : pointer(FieldRef(client, :proxy_env_settings)), # proxy_env_settings::Ptr{proxy_env_var_settings}
        cs.max_connections, # max_connections::Csize_t, 512
        C_NULL, # shutdown_complete_user_data::Ptr{Cvoid}
        C_NULL, # shutdown_complete_callback::Ptr{aws_http_connection_manager_shutdown_complete_fn}
        cs.enable_read_back_pressure, # enable_read_back_pressure::Bool
        cs.max_connection_idle_in_milliseconds,
        cs.connection_acquisition_timeout_ms,
        cs.max_pending_connection_acquisitions,
        C_NULL, # network_interface_names_array
        0, # num_network_interface_names
    )
    client.connection_manager = aws_http_connection_manager_new(cs.allocator, FieldRef(client, :conn_manager_opts))
    client.connection_manager == C_NULL && aws_throw_error()

    finalizer(client) do x
        if x.connection_manager != C_NULL
            aws_http_connection_manager_release(x.connection_manager)
            x.connection_manager = C_NULL
        end
        if x.retry_strategy != C_NULL
            aws_retry_strategy_release(x.retry_strategy)
            x.retry_strategy = C_NULL
        end
    end
    return client
end

#TODO: this should probably be a LRU cache to not grow indefinitely
struct Clients
    lock::ReentrantLock
    clients::Dict{ClientSettings, Client}
end

Clients() = Clients(ReentrantLock(), Dict{ClientSettings, Client}())

const CLIENTS = Clients()

function getclient(key::ClientSettings, clients::Clients=CLIENTS)
    Base.@lock clients.lock begin
        if haskey(clients.clients, key)
            return clients.clients[key]
        else
            client = Client(key)
            clients.clients[key] = client
            return client
        end
    end
end

function close_all_clients!(clients::Clients=CLIENTS)
    Base.@lock clients.lock begin
        for client in values(clients.clients)
            finalize(client)
        end
        empty!(clients.clients)
    end
end
