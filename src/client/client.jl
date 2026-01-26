const DEFAULT_CONNECT_TIMEOUT = 3000
const DEFAULT_MAX_RETRIES = 4

const on_statistics_observer = Ref{Ptr{Cvoid}}(C_NULL)

mutable struct StatisticsObserver
    cb::Function
end

function _decode_statistics(stats_list_ptr::Ptr{aws_array_list})
    stats_list_ptr == C_NULL && return Any[]
    stats_list = unsafe_load(stats_list_ptr)
    len = Int(stats_list.length)
    len == 0 && return Any[]
    item_size = Int(stats_list.item_size)
    data_ptr = Ptr{UInt8}(stats_list.data)
    data_ptr == C_NULL && return Any[]
    stats = Vector{Any}(undef, len)
    for i in 1:len
        item_ptr = data_ptr + (i - 1) * item_size
        category = unsafe_load(Ptr{UInt32}(item_ptr))
        if category == UInt32(AWSCRT_STAT_CAT_HTTP1_CHANNEL)
            entry = unsafe_load(Ptr{aws_crt_statistics_http1_channel}(item_ptr))
            stats[i] = (
                category = :http1_channel,
                pending_outgoing_stream_ms = entry.pending_outgoing_stream_ms,
                pending_incoming_stream_ms = entry.pending_incoming_stream_ms,
                current_outgoing_stream_id = entry.current_outgoing_stream_id,
                current_incoming_stream_id = entry.current_incoming_stream_id,
            )
        elseif category == UInt32(AWSCRT_STAT_CAT_HTTP2_CHANNEL)
            entry = unsafe_load(Ptr{aws_crt_statistics_http2_channel}(item_ptr))
            stats[i] = (
                category = :http2_channel,
                pending_outgoing_stream_ms = entry.pending_outgoing_stream_ms,
                pending_incoming_stream_ms = entry.pending_incoming_stream_ms,
                was_inactive = entry.was_inactive,
            )
        else
            raw = Vector{UInt8}(undef, item_size)
            GC.@preserve raw unsafe_copyto!(pointer(raw), item_ptr, item_size)
            stats[i] = (category = :unknown, raw = raw)
        end
    end
    return stats
end

_decode_statistics(stats_list::Ref{aws_array_list}) =
    _decode_statistics(Base.unsafe_convert(Ptr{aws_array_list}, stats_list))

function c_on_statistics_observer(connection_nonce::Csize_t, stats_list::Ptr{aws_array_list}, observer_ptr::Ptr{Cvoid})
    observer = unsafe_pointer_to_objref(observer_ptr)::StatisticsObserver
    stats = _decode_statistics(stats_list)
    try
        Base.invokelatest(observer.cb, connection_nonce, stats)
    catch e
        @error "statistics observer error" exception=(e, catch_backtrace())
    end
    return
end

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
    proxy_auth::Union{Nothing, Symbol} = nothing
    proxy_username::Union{Nothing, String} = nothing
    proxy_password::Union{Nothing, String} = nothing
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
    monitoring_minimum_throughput_bytes_per_second::UInt64 = 0
    monitoring_allowable_throughput_failure_interval_seconds::UInt32 = 0
    monitoring_statistics_observer::Union{Nothing, Function} = nothing
    http2_prior_knowledge::Bool = false
    http2_stream_manager::Bool = false
    http2_close_connection_on_server_error::Bool = false
    http2_connection_manual_window_management::Bool = false
    http2_connection_ping_period_ms::Int = 0
    http2_connection_ping_timeout_ms::Int = 0
    http2_ideal_concurrent_streams_per_connection::Int = 0
    http2_max_concurrent_streams_per_connection::Int = 0
    http2_max_closed_streams::Int = 0
    http2_initial_window_size::Int = HTTP2_DEFAULT_WINDOW_SIZE
    http2_initial_settings::Union{Nothing, AbstractVector} = nothing
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
    kw...) = begin
    http2_initial_settings = Base.get(() -> nothing, kw, :http2_initial_settings)
    if http2_initial_settings !== nothing && !(http2_initial_settings isa AbstractVector)
        throw(ArgumentError("http2_initial_settings must be a vector of pairs or aws_http2_setting"))
    end
    if haskey(kw, :http2_initial_settings)
        kw = Base.structdiff((; kw...), (; http2_initial_settings=nothing))
    end
    ClientSettings(;
        scheme=String(scheme),
        host=String(host),
        port=port,
        connect_timeout_ms=(connect_timeout !== nothing ? connect_timeout * 1000 : connect_timeout_ms),
        max_retries=(retry ? (retries != DEFAULT_MAX_RETRIES ? retries : max_retries) : 0),
        ssl_insecure=(!require_ssl_verification || ssl_insecure),
        http2_initial_settings=http2_initial_settings,
        kw...)
end

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
    proxy_strategy::Ptr{aws_http_proxy_strategy}
    monitoring_options::Union{Nothing, aws_http_connection_monitoring_options}
    monitoring_observer::Union{Nothing, Any}
    retry_options::aws_standard_retry_options
    retry_strategy::Ptr{aws_retry_strategy}
    conn_manager_opts::aws_http_connection_manager_options
    connection_manager::Ptr{aws_http_connection_manager}
    http2_stream_manager_opts::Union{Nothing, aws_http2_stream_manager_options}
    http2_stream_manager::Ptr{aws_http2_stream_manager}
    http2_initial_settings::Union{Nothing, Vector{aws_http2_setting}}

    Client() = new()
end

Client(scheme::AbstractString, host::AbstractString, port::Integer; kw...) = Client(ClientSettings(scheme, host, port % UInt32; kw...))

function Client(cs::ClientSettings)
    client = Client()
    client.settings = cs
    if cs.http2_initial_window_size < 0 || cs.http2_initial_window_size > HTTP2_MAX_WINDOW_SIZE
        throw(ArgumentError("http2_initial_window_size must be between 0 and $(HTTP2_MAX_WINDOW_SIZE)"))
    end
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
    client.proxy_options = nothing
    client.proxy_env_settings = nothing
    client.proxy_strategy = C_NULL
    proxy_connection_type = cs.proxy_connection_type == :forward ? AWS_HPCT_HTTP_FORWARD : AWS_HPCT_HTTP_TUNNEL
    if cs.proxy_host !== nothing && cs.proxy_port !== nothing
        proxy_auth = cs.proxy_auth
        if proxy_auth === nothing && (cs.proxy_username !== nothing || cs.proxy_password !== nothing)
            proxy_auth = :basic
        end
        if proxy_auth !== nothing
            proxy_auth == :basic || throw(ArgumentError("unsupported proxy_auth: $proxy_auth"))
            cs.proxy_username === nothing && throw(ArgumentError("proxy_username required for basic proxy auth"))
            cs.proxy_password === nothing && throw(ArgumentError("proxy_password required for basic proxy auth"))
            auth_opts = aws_http_proxy_strategy_basic_auth_options(
                proxy_connection_type,
                aws_byte_cursor_from_c_str(cs.proxy_username),
                aws_byte_cursor_from_c_str(cs.proxy_password),
            )
            GC.@preserve cs begin
                client.proxy_strategy = aws_http_proxy_strategy_new_basic_auth(cs.allocator, Ref(auth_opts))
            end
            client.proxy_strategy == C_NULL && aws_throw_error()
        end
        client.proxy_options = aws_http_proxy_options(
            proxy_connection_type,
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
            client.proxy_strategy, # proxy_strategy::Ptr{aws_http_proxy_strategy}
            AWS_HPAT_NONE, # auth_type::aws_http_proxy_authentication_type
            aws_byte_cursor_from_c_str(""), # auth_username::aws_byte_cursor
            aws_byte_cursor_from_c_str(""), # auth_password::aws_byte_cursor
        )
    elseif cs.proxy_allow_env_var
        if cs.proxy_auth !== nothing || cs.proxy_username !== nothing || cs.proxy_password !== nothing
            throw(ArgumentError("proxy auth requires explicit proxy_host/proxy_port"))
        end
        client.proxy_env_settings = proxy_env_var_settings(
            AWS_HPEV_ENABLE,
            proxy_connection_type,
            cs.proxy_ssl_cert === nothing ? C_NULL : LibAwsIO.tlsoptions(cs.proxy_host;
                cs.proxy_ssl_cert,
                cs.proxy_ssl_key,
                cs.proxy_ssl_capath,
                cs.proxy_ssl_cacert,
                cs.proxy_ssl_insecure,
                cs.proxy_ssl_alpn_list
            )
        )
    end
    # connection monitoring options
    monitoring_ptr = C_NULL
    if cs.monitoring_statistics_observer !== nothing ||
       cs.monitoring_minimum_throughput_bytes_per_second != 0 ||
       cs.monitoring_allowable_throughput_failure_interval_seconds != 0
        observer = cs.monitoring_statistics_observer === nothing ? nothing : StatisticsObserver(cs.monitoring_statistics_observer)
        client.monitoring_observer = observer
        client.monitoring_options = aws_http_connection_monitoring_options(
            UInt64(cs.monitoring_minimum_throughput_bytes_per_second),
            UInt32(cs.monitoring_allowable_throughput_failure_interval_seconds),
            observer === nothing ? C_NULL : on_statistics_observer[],
            observer === nothing ? C_NULL : pointer_from_objref(observer)
        )
        monitoring_ptr = pointer(FieldRef(client, :monitoring_options))
    else
        client.monitoring_options = nothing
        client.monitoring_observer = nothing
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
    settings_input = cs.http2_initial_settings
    if settings_input === nothing
        client.http2_initial_settings = nothing
    elseif settings_input isa AbstractVector{aws_http2_setting}
        client.http2_initial_settings = collect(settings_input)
    elseif settings_input isa AbstractVector{<:Pair}
        client.http2_initial_settings = _settings_from_pairs(settings_input)
    else
        throw(ArgumentError("http2_initial_settings must be a vector of pairs or aws_http2_setting"))
    end
    settings_ptr = client.http2_initial_settings === nothing ? C_NULL : pointer(client.http2_initial_settings)
    settings_len = client.http2_initial_settings === nothing ? 0 : length(client.http2_initial_settings)

    client.conn_manager_opts = aws_http_connection_manager_options(
        cs.bootstrap,
        cs.http2_initial_window_size, # initial_window_size::Csize_t
        pointer(FieldRef(client, :socket_options)),
        cs.response_first_byte_timeout_ms,
        (cs.scheme == "https" || cs.scheme == "wss") ? pointer(FieldRef(client, :tls_options)) : C_NULL,
        cs.http2_prior_knowledge,
        monitoring_ptr, # monitoring_options::Ptr{aws_http_connection_monitoring_options}
        aws_byte_cursor_from_c_str(cs.host),
        cs.port % UInt32,
        settings_ptr, # initial_settings_array::Ptr{aws_http2_setting}
        settings_len, # num_initial_settings::Csize_t
        cs.http2_max_closed_streams, # max_closed_streams::Csize_t
        cs.http2_connection_manual_window_management, # http2_conn_manual_window_management::Bool
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
    client.http2_stream_manager_opts = nothing
    client.http2_stream_manager = C_NULL
    if cs.http2_stream_manager
        opts = aws_http2_stream_manager_options(
            cs.bootstrap,
            pointer(FieldRef(client, :socket_options)),
            (cs.scheme == "https" || cs.scheme == "wss") ? pointer(FieldRef(client, :tls_options)) : C_NULL,
            cs.http2_prior_knowledge,
            aws_byte_cursor_from_c_str(cs.host),
            cs.port % UInt32,
            settings_ptr, # initial_settings_array
            settings_len, # num_initial_settings
            cs.http2_max_closed_streams, # max_closed_streams
            cs.http2_connection_manual_window_management, # conn_manual_window_management
            cs.enable_read_back_pressure,
            cs.http2_initial_window_size, # initial_window_size
            monitoring_ptr, # monitoring_options
            client.proxy_options === nothing ? C_NULL : pointer(FieldRef(client, :proxy_options)),
            client.proxy_env_settings === nothing ? C_NULL : pointer(FieldRef(client, :proxy_env_settings)),
            C_NULL, # shutdown_complete_user_data
            C_NULL, # shutdown_complete_callback
            cs.http2_close_connection_on_server_error, # close_connection_on_server_error
            cs.http2_connection_ping_period_ms, # connection_ping_period_ms
            cs.http2_connection_ping_timeout_ms, # connection_ping_timeout_ms
            cs.http2_ideal_concurrent_streams_per_connection, # ideal_concurrent_streams_per_connection
            cs.http2_max_concurrent_streams_per_connection, # max_concurrent_streams_per_connection
            cs.max_connections,
        )
        client.http2_stream_manager_opts = opts
        client.http2_stream_manager = aws_http2_stream_manager_new(cs.allocator, Ref(opts))
        client.http2_stream_manager == C_NULL && aws_throw_error()
    end

    finalizer(client) do x
        if x.connection_manager != C_NULL
            aws_http_connection_manager_release(x.connection_manager)
            x.connection_manager = C_NULL
        end
        if x.http2_stream_manager != C_NULL
            aws_http2_stream_manager_release(x.http2_stream_manager)
            x.http2_stream_manager = C_NULL
        end
        if x.proxy_strategy != C_NULL
            aws_http_proxy_strategy_release(x.proxy_strategy)
            x.proxy_strategy = C_NULL
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

struct Pool
    clients::Clients
    max_connections::Union{Nothing, Int}
end

Pool(max_connections::Union{Int, Nothing}=nothing) = Pool(Clients(), max_connections)

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

function manager_metrics(client::Client)
    metrics = Ref{aws_http_manager_metrics}()
    if client.http2_stream_manager != C_NULL
        aws_http2_stream_manager_fetch_metrics(client.http2_stream_manager, metrics)
    else
        aws_http_connection_manager_fetch_metrics(client.connection_manager, metrics)
    end
    return metrics[]
end

getclient(key::ClientSettings, pool::Pool) = getclient(key, pool.clients)

function close_all_clients!(clients::Clients=CLIENTS)
    Base.@lock clients.lock begin
        for client in values(clients.clients)
            finalize(client)
        end
        empty!(clients.clients)
    end
end

close_all_clients!(pool::Pool) = close_all_clients!(pool.clients)
