const DEFAULT_CONNECT_TIMEOUT = 3000
const DEFAULT_MAX_RETRIES = 0
const default_connection_limit = Ref{Int}(max(16, Threads.nthreads() * 4))

# ─── Shared infrastructure ───
# Uses Reseau/AwsHTTP scoped defaults for event loops, DNS resolver, and bootstrap.
_ensure_resources!() = nothing

function _task_sleep_s(seconds::Real)::Nothing
    seconds <= 0 && return nothing
    local el
    try
        el = Reseau.EventLoops.get_next_event_loop()
    catch
        Reseau.thread_sleep_s(seconds)
        return nothing
    end
    Reseau.EventLoops.task_sleep_s(el, seconds)
    return nothing
end

# ─── TLS helper ───

function _make_tls_options(host::String; ssl_cert, ssl_key, ssl_capath, ssl_cacert, ssl_insecure, ssl_alpn_list)
    alpn_list = _normalize_alpn_list(ssl_alpn_list)
    if ssl_cert !== nothing && ssl_key !== nothing
        # Mutual TLS: client certificate + key (file paths)
        opts = Reseau.Sockets.tls_ctx_options_init_client_mtls_from_path(ssl_cert, ssl_key)
        Reseau.Sockets.tls_ctx_options_set_verify_peer!(opts, !ssl_insecure)
        if alpn_list !== nothing && !isempty(alpn_list)
            Reseau.Sockets.tls_ctx_options_set_alpn_list!(opts, alpn_list)
        end
        if ssl_cacert !== nothing || ssl_capath !== nothing
            Reseau.Sockets.tls_ctx_options_override_default_trust_store_from_path!(opts;
                ca_path=ssl_capath, ca_file=ssl_cacert)
        end
        ctx = Reseau.Sockets.tls_context_new(opts)
    else
        # Standard client TLS (no client cert)
        ctx = Reseau.Sockets.tls_context_new_client(;
            verify_peer=!ssl_insecure,
            ca_file=ssl_cacert,
            ca_path=ssl_capath,
            alpn_list=alpn_list,
        )
    end
    return Reseau.Sockets.TlsConnectionOptions(ctx; server_name=host)
end

# ─── Settings ───

Base.@kwdef struct ClientSettings
    scheme::String
    host::String
    port::UInt32
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
    jitter_mode::Symbol = :default
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
    kw_nt = (; kw...)
    connection_limit = Base.get(() -> nothing, kw_nt, :connection_limit)
    if connection_limit !== nothing
        connection_limit_warning(connection_limit)
        kw_nt = Base.structdiff(kw_nt, (; connection_limit=nothing))
    end
    max_connections = Base.get(() -> default_connection_limit[], kw_nt, :max_connections)
    if haskey(kw_nt, :max_connections)
        kw_nt = Base.structdiff(kw_nt, (; max_connections=nothing))
    end
    http2_initial_settings = Base.get(() -> nothing, kw_nt, :http2_initial_settings)
    if http2_initial_settings !== nothing && !(http2_initial_settings isa AbstractVector)
        throw(ArgumentError("http2_initial_settings must be a vector of pairs or AwsHTTP.Http2Setting"))
    end
    if haskey(kw_nt, :http2_initial_settings)
        kw_nt = Base.structdiff(kw_nt, (; http2_initial_settings=nothing))
    end
    ClientSettings(;
        scheme=String(scheme),
        host=String(host),
        port=port,
        connect_timeout_ms=(connect_timeout !== nothing ? connect_timeout * 1000 : connect_timeout_ms),
        max_retries=(retry ? (retries != DEFAULT_MAX_RETRIES ? retries : max_retries) : 0),
        max_connections=max_connections,
        ssl_insecure=(!require_ssl_verification || ssl_insecure),
        http2_initial_settings=http2_initial_settings,
        kw_nt...)
end

# make a new ClientSettings object from an existing one w/ just different url values
@generated function ClientSettings(cs::ClientSettings, scheme::AbstractString, host::AbstractString, port::Integer)
    ex = :(ClientSettings(String(scheme), String(host), port % UInt32))
    for i = 4:fieldcount(ClientSettings)
        push!(ex.args, :(getfield(cs, $(Meta.quot(fieldname(ClientSettings, i))))))
    end
    return ex
end

# ─── Compat option mirrors for tests ───

struct ConnManagerOptsCompat
    http2_conn_manual_window_management::Bool
    max_closed_streams::Csize_t
    initial_window_size::Csize_t
    num_initial_settings::Csize_t
    initial_settings_array::Ptr{AwsHTTP.Http2Setting}
    _initial_settings_storage::Vector{AwsHTTP.Http2Setting}
end

struct Http2StreamManagerOptsCompat
    close_connection_on_server_error::Bool
    conn_manual_window_management::Bool
    connection_ping_period_ms::Csize_t
    connection_ping_timeout_ms::Csize_t
    ideal_concurrent_streams_per_connection::Csize_t
    max_concurrent_streams_per_connection::Csize_t
    initial_window_size::Csize_t
    max_closed_streams::Csize_t
    num_initial_settings::Csize_t
    initial_settings_array::Ptr{AwsHTTP.Http2Setting}
    _initial_settings_storage::Vector{AwsHTTP.Http2Setting}
end

# ─── Client ───

mutable struct Client
    settings::ClientSettings
    socket_options::Reseau.Sockets.SocketOptions
    tls_options::Union{Nothing, Reseau.Sockets.TlsConnectionOptions}
    # only 1 of proxy_options or proxy_env_settings is set
    proxy_options::Union{Nothing, AwsHTTP.HttpProxyOptions}
    proxy_env_settings::Union{Nothing, AwsHTTP.ProxyEnvVarSettings}
    proxy_strategy::Union{Nothing, AwsHTTP.HttpProxyStrategy}
    monitoring_options::Union{Nothing, AwsHTTP.HttpConnectionMonitoringOptions}
    monitoring_observer::Union{Nothing, Function}
    retry_strategy::Reseau.StandardRetryStrategy
    connection_manager::AwsHTTP.HttpConnectionManager
    http2_stream_manager::Union{Nothing, AwsHTTP.Http2StreamManager}
    http2_initial_settings::Union{Nothing, Vector{AwsHTTP.Http2Setting}}
    conn_manager_opts::ConnManagerOptsCompat
    http2_stream_manager_opts::Union{Nothing, Http2StreamManagerOptsCompat}

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
    client.socket_options = Reseau.Sockets.SocketOptions(;
        type=Reseau.Sockets.SocketType.STREAM,
        domain=cs.socket_domain == :ipv4 ? Reseau.Sockets.SocketDomain.IPV4 : Reseau.Sockets.SocketDomain.IPV6,
        connect_timeout_ms=cs.connect_timeout_ms,
        keepalive=cs.keepalive,
        keep_alive_interval_sec=cs.keep_alive_interval_sec,
        keep_alive_timeout_sec=cs.keep_alive_timeout_sec,
        keep_alive_max_failed_probes=cs.keep_alive_max_failed_probes,
    )
    # tls options
    if cs.scheme == "https" || cs.scheme == "wss"
        client.tls_options = _make_tls_options(cs.host;
            cs.ssl_cert, cs.ssl_key, cs.ssl_capath, cs.ssl_cacert,
            cs.ssl_insecure, cs.ssl_alpn_list)
    else
        client.tls_options = nothing
    end
    # proxy options
    client.proxy_options = nothing
    client.proxy_env_settings = nothing
    client.proxy_strategy = nothing
    proxy_connection_type = cs.proxy_connection_type == :forward ?
        AwsHTTP.HttpProxyConnectionType.HTTP_FORWARD :
        AwsHTTP.HttpProxyConnectionType.HTTP_TUNNEL
    if cs.proxy_host !== nothing && cs.proxy_port !== nothing
        proxy_auth = cs.proxy_auth
        if proxy_auth === nothing && (cs.proxy_username !== nothing || cs.proxy_password !== nothing)
            proxy_auth = :basic
        end
        if proxy_auth !== nothing
            proxy_auth == :basic || throw(ArgumentError("unsupported proxy_auth: $proxy_auth"))
            cs.proxy_username === nothing && throw(ArgumentError("proxy_username required for basic proxy auth"))
            cs.proxy_password === nothing && throw(ArgumentError("proxy_password required for basic proxy auth"))
            client.proxy_strategy = AwsHTTP.http_proxy_strategy_new_basic_auth(
                AwsHTTP.HttpProxyStrategyBasicAuthOptions(
                    proxy_connection_type,
                    cs.proxy_username,
                    cs.proxy_password,
                )
            )
        end
        client.proxy_options = AwsHTTP.HttpProxyOptions(;
            connection_type=proxy_connection_type,
            host=cs.proxy_host,
            port=cs.proxy_port % UInt32,
            proxy_strategy=client.proxy_strategy,
        )
    elseif cs.proxy_allow_env_var
        if cs.proxy_auth !== nothing || cs.proxy_username !== nothing || cs.proxy_password !== nothing
            throw(ArgumentError("proxy auth requires explicit proxy_host/proxy_port"))
        end
        client.proxy_env_settings = AwsHTTP.ProxyEnvVarSettings(;
            env_var_type=AwsHTTP.HttpProxyEnvVarType.ENABLE,
            connection_type=proxy_connection_type,
        )
    end
    # connection monitoring options
    if cs.monitoring_minimum_throughput_bytes_per_second != 0 ||
       cs.monitoring_allowable_throughput_failure_interval_seconds != 0
        client.monitoring_options = AwsHTTP.HttpConnectionMonitoringOptions(
            UInt64(cs.monitoring_minimum_throughput_bytes_per_second),
            UInt32(cs.monitoring_allowable_throughput_failure_interval_seconds),
        )
    else
        client.monitoring_options = nothing
    end
    client.monitoring_observer = cs.monitoring_statistics_observer
    # retry strategy
    strategy = Reseau.StandardRetryStrategy(
        Reseau.EventLoops.get_event_loop_group();
        initial_bucket_capacity=cs.initial_bucket_capacity,
        backoff_scale_factor_ms=cs.backoff_scale_factor_ms,
        max_backoff_secs=cs.max_backoff_secs,
        max_retries=cs.max_retries,
        jitter_mode=cs.jitter_mode,
    )
    client.retry_strategy = strategy
    # http2 initial settings
    settings_input = cs.http2_initial_settings
    if settings_input === nothing
        client.http2_initial_settings = nothing
    elseif settings_input isa AbstractVector{AwsHTTP.Http2Setting}
        client.http2_initial_settings = collect(settings_input)
    elseif settings_input isa AbstractVector{<:Pair}
        client.http2_initial_settings = _settings_from_pairs(settings_input)
    else
        throw(ArgumentError("http2_initial_settings must be a vector of pairs or AwsHTTP.Http2Setting"))
    end
    settings_storage = client.http2_initial_settings === nothing ? AwsHTTP.Http2Setting[] : client.http2_initial_settings
    settings_ptr = isempty(settings_storage) ? Ptr{AwsHTTP.Http2Setting}(C_NULL) : pointer(settings_storage)
    settings_count = Csize_t(length(settings_storage))
    # connection factory: creates connections for the pool managers.
    # Calls AwsHTTP.http_client_connect (async) and blocks until setup completes.
    conn_factory = let socket_opts=client.socket_options, tls_opts=client.tls_options,
                       host=cs.host, port=cs.port,
                       prior_knowledge=cs.http2_prior_knowledge,
                       manual_wm=cs.http2_connection_manual_window_management,
                       initial_ws=cs.http2_initial_window_size,
                       rfbt_ms=cs.response_first_byte_timeout_ms
        function(_manager_opts)
            result_ch = Base.Channel{Any}(1)
            AwsHTTP.http_client_connect(AwsHTTP.HttpClientConnectionOptions(
                host_name=host,
                port=port,
                socket_options=socket_opts,
                tls_connection_options=tls_opts,
                prior_knowledge_http2=prior_knowledge,
                manual_window_management=manual_wm,
                initial_window_size=Csize_t(initial_ws),
                response_first_byte_timeout_ms=UInt64(rfbt_ms),
                on_setup=(conn, err, ud) -> put!(result_ch, err == Reseau.OP_SUCCESS ? conn : nothing),
            ))
            return take!(result_ch)
        end
    end
    # connection manager
    client.connection_manager = AwsHTTP.http_connection_manager_new(
        AwsHTTP.HttpConnectionManagerOptions(;
            host=cs.host,
            port=cs.port,
            max_connections=cs.max_connections,
            initial_window_size=Csize_t(cs.http2_initial_window_size),
            manual_window_management=cs.http2_connection_manual_window_management,
            http2_prior_knowledge=cs.http2_prior_knowledge,
            enable_read_back_pressure=cs.enable_read_back_pressure,
            max_connection_idle_in_milliseconds=UInt64(cs.max_connection_idle_in_milliseconds),
            connection_acquisition_timeout_ms=UInt64(cs.connection_acquisition_timeout_ms),
            max_pending_connection_acquisitions=cs.max_pending_connection_acquisitions,
            response_first_byte_timeout_ms=UInt64(cs.response_first_byte_timeout_ms),
            max_closed_streams=cs.http2_max_closed_streams,
            http2_conn_manual_window_management=cs.http2_connection_manual_window_management,
            on_connection_setup=conn_factory,
        )
    )
    client.conn_manager_opts = ConnManagerOptsCompat(
        cs.http2_connection_manual_window_management,
        Csize_t(cs.http2_max_closed_streams),
        Csize_t(cs.http2_initial_window_size),
        settings_count,
        settings_ptr,
        settings_storage,
    )
    # http2 stream manager (optional)
    client.http2_stream_manager = nothing
    client.http2_stream_manager_opts = nothing
    if cs.http2_stream_manager
        client.http2_stream_manager = AwsHTTP.http2_stream_manager_new(
            AwsHTTP.Http2StreamManagerOptions(;
                host=cs.host,
                port=cs.port,
                max_connections=cs.max_connections,
                ideal_concurrent_streams_per_connection=cs.http2_ideal_concurrent_streams_per_connection,
                max_concurrent_streams_per_connection=cs.http2_max_concurrent_streams_per_connection,
                close_connection_on_server_error=cs.http2_close_connection_on_server_error,
                connection_ping_period_ms=UInt64(cs.http2_connection_ping_period_ms),
                connection_ping_timeout_ms=UInt64(cs.http2_connection_ping_timeout_ms),
                initial_window_size=Csize_t(cs.http2_initial_window_size),
                manual_window_management=cs.http2_connection_manual_window_management,
                http2_prior_knowledge=cs.http2_prior_knowledge,
                enable_read_back_pressure=cs.enable_read_back_pressure,
                max_closed_streams=cs.http2_max_closed_streams,
                on_connection_setup=conn_factory,
            )
        )
        client.http2_stream_manager_opts = Http2StreamManagerOptsCompat(
            cs.http2_close_connection_on_server_error,
            cs.http2_connection_manual_window_management,
            Csize_t(cs.http2_connection_ping_period_ms),
            Csize_t(cs.http2_connection_ping_timeout_ms),
            Csize_t(cs.http2_ideal_concurrent_streams_per_connection),
            Csize_t(cs.http2_max_concurrent_streams_per_connection),
            Csize_t(cs.http2_initial_window_size),
            Csize_t(cs.http2_max_closed_streams),
            settings_count,
            settings_ptr,
            settings_storage,
        )
    end
    return client
end

# ─── Client cache ───

const _CLIENT_CACHE_MAX = let val = get(ENV, "HTTP_CLIENT_CACHE_MAX", "64")
    parsed = tryparse(Int, val)
    parsed === nothing || parsed < 1 ? 64 : parsed
end

struct Clients
    lock::ReentrantLock
    clients::Dict{ClientSettings, Client}
    order::Vector{ClientSettings}
    max_clients::Int
end

Clients(max_clients::Int=_CLIENT_CACHE_MAX) =
    Clients(ReentrantLock(), Dict{ClientSettings, Client}(), ClientSettings[], max_clients)

struct Pool
    clients::Clients
    max_connections::Union{Nothing, Int}
end

Pool() = Pool(default_connection_limit[])
Pool(max_connections::Union{Int, Nothing}) = Pool(Clients(), max_connections)

function Base.getproperty(pool::Pool, name::Symbol)
    if name === :max
        return getfield(pool, :max_connections)
    end
    return getfield(pool, name)
end

const CLIENTS = Clients()

function getclient(key::ClientSettings, clients::Clients=CLIENTS)
    Base.@lock clients.lock begin
        if haskey(clients.clients, key)
            idx = findfirst(==(key), clients.order)
            idx !== nothing && deleteat!(clients.order, idx)
            push!(clients.order, key)
            return clients.clients[key]
        end
        client = Client(key)
        clients.clients[key] = client
        push!(clients.order, key)
        if length(clients.order) > clients.max_clients
            evict = popfirst!(clients.order)
            delete!(clients.clients, evict)
        end
        return client
    end
end

function manager_metrics(client::Client)
    if client.http2_stream_manager !== nothing
        return AwsHTTP.http2_stream_manager_fetch_metrics(client.http2_stream_manager)
    else
        return AwsHTTP.http_connection_manager_fetch_metrics(client.connection_manager)
    end
end

getclient(key::ClientSettings, pool::Pool) = getclient(key, pool.clients)

function close_all_clients!(clients::Clients=CLIENTS)
    Base.@lock clients.lock begin
        for client in values(clients.clients)
            close(client.connection_manager)
            if client.http2_stream_manager !== nothing
                close(client.http2_stream_manager)
            end
        end
        empty!(clients.clients)
        empty!(clients.order)
    end
end

close_all_clients!(pool::Pool) = close_all_clients!(pool.clients)

function set_default_connection_limit!(n::Integer)
    default_connection_limit[] = Int(n)
    return
end

function closeall(pool::Union{Nothing, Pool}=nothing)
    if pool === nothing
        close_all_clients!(CLIENTS)
    else
        close_all_clients!(pool.clients)
    end
    return
end

@noinline function connection_limit_warning(cl)
    cl === nothing && return
    @warn "connection_limit no longer supported as a keyword argument; use `HTTP.set_default_connection_limit!($cl)` before any requests are made or construct a shared pool via `POOL = HTTP.Pool($cl)` and pass to each request like `pool=POOL` instead."
    return
end
