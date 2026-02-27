# HTTP Proxy support - Strategy pattern, negotiation, no-proxy matching
# Port of aws-c-http/proxy.h, proxy_connection.c, proxy_strategy.c, no_proxy.c

# ─── Proxy enums ───

@enumx HttpProxyConnectionType::UInt8 begin
    HTTP_LEGACY = 0
    HTTP_FORWARD = 1
    HTTP_TUNNEL = 2
end

@enumx HttpProxyAuthenticationType::UInt8 begin
    NONE = 0
    BASIC = 1
end

@enumx HttpProxyEnvVarType::UInt8 begin
    DISABLE = 0
    ENABLE = 1
end

@enumx HttpProxyNegotiationRetryDirective::UInt8 begin
    STOP = 0
    NEW_CONNECTION = 1
    CURRENT_CONNECTION = 2
end

# ─── Proxy negotiator vtables ───

struct HttpProxyNegotiatorForwardingVtable{FRT}
    forward_request_transform::FRT  # (negotiator, message) -> Int
end

struct HttpProxyNegotiatorTunnellingVtable{FCRT, FIH, FS, FIB, FRD}
    connect_request_transform::FCRT # (negotiator, message, on_done, on_forward, user_data) -> Nothing
    on_incoming_headers::FIH        # (negotiator, header_block, headers) -> Int
    on_status::FS                   # (negotiator, status_code) -> Int
    on_incoming_body::FIB           # (negotiator, data) -> Int
    get_retry_directive::FRD        # (negotiator) -> HttpProxyNegotiationRetryDirective.T
end

# ─── Proxy negotiator ───

mutable struct HttpProxyNegotiator{Impl, FV <: Union{HttpProxyNegotiatorForwardingVtable, Nothing}, TV <: Union{HttpProxyNegotiatorTunnellingVtable, Nothing}}
    impl::Impl
    is_tunnelling::Bool
    forwarding_vtable::FV
    tunnelling_vtable::TV
end

function http_proxy_negotiator_get_retry_directive(n::HttpProxyNegotiator)::HttpProxyNegotiationRetryDirective.T
    if n.is_tunnelling && n.tunnelling_vtable !== nothing && n.tunnelling_vtable.get_retry_directive !== nothing
        return n.tunnelling_vtable.get_retry_directive(n)
    end
    return HttpProxyNegotiationRetryDirective.STOP
end

# ─── Proxy strategy ───

struct HttpProxyStrategyVtable{FCN}
    create_negotiator::FCN  # (strategy) -> HttpProxyNegotiator
end

mutable struct HttpProxyStrategy{VT <: HttpProxyStrategyVtable, Impl}
    vtable::VT
    impl::Impl
    proxy_connection_type::HttpProxyConnectionType.T
end

function http_proxy_strategy_create_negotiator(strategy::HttpProxyStrategy)::Union{HttpProxyNegotiator, Nothing}
    if strategy.vtable.create_negotiator !== nothing
        return strategy.vtable.create_negotiator(strategy)
    end
    return nothing
end

# ─── Proxy options ───

struct HttpProxyOptions{PS <: Union{HttpProxyStrategy, Nothing}}
    connection_type::HttpProxyConnectionType.T
    host::String
    port::UInt32
    proxy_strategy::PS
    auth_type::HttpProxyAuthenticationType.T  # deprecated
    auth_username::String  # deprecated
    auth_password::String  # deprecated
    no_proxy_hosts::String
end

function HttpProxyOptions(;
    connection_type::HttpProxyConnectionType.T=HttpProxyConnectionType.HTTP_LEGACY,
    host::String="",
    port::UInt32=UInt32(0),
    proxy_strategy::Union{HttpProxyStrategy, Nothing}=nothing,
    auth_type::HttpProxyAuthenticationType.T=HttpProxyAuthenticationType.NONE,
    auth_username::String="",
    auth_password::String="",
    no_proxy_hosts::String="",
)
    return HttpProxyOptions(
        connection_type, host, port,
        proxy_strategy,
        auth_type, auth_username, auth_password,
        no_proxy_hosts,
    )
end

# ─── Proxy config (persistent) ───

mutable struct HttpProxyConfig{PS <: Union{HttpProxyStrategy, Nothing}}
    connection_type::HttpProxyConnectionType.T
    host::String
    port::UInt32
    proxy_strategy::PS
    no_proxy_hosts::String
end

function http_proxy_config_new_from_proxy_options(options::HttpProxyOptions)::HttpProxyConfig
    return HttpProxyConfig(
        options.connection_type,
        options.host,
        options.port,
        options.proxy_strategy,
        options.no_proxy_hosts,
    )
end

function http_proxy_config_new_clone(config::HttpProxyConfig)::HttpProxyConfig
    return HttpProxyConfig(
        config.connection_type,
        config.host,
        config.port,
        config.proxy_strategy,
        config.no_proxy_hosts,
    )
end

function http_proxy_options_init_from_config(config::HttpProxyConfig)::HttpProxyOptions
    return HttpProxyOptions(
        connection_type=config.connection_type,
        host=config.host,
        port=config.port,
        proxy_strategy=config.proxy_strategy,
        no_proxy_hosts=config.no_proxy_hosts,
    )
end

# ─── Environment variable proxy settings ───

struct ProxyEnvVarSettings
    env_var_type::HttpProxyEnvVarType.T
    connection_type::HttpProxyConnectionType.T
end

function ProxyEnvVarSettings(;
    env_var_type::HttpProxyEnvVarType.T=HttpProxyEnvVarType.DISABLE,
    connection_type::HttpProxyConnectionType.T=HttpProxyConnectionType.HTTP_LEGACY,
)
    return ProxyEnvVarSettings(env_var_type, connection_type)
end

# ─── Built-in strategies ───

## Basic auth strategy

struct BasicAuthImpl
    user_name::String
    password::String
    proxy_connection_type::HttpProxyConnectionType.T
end

function _basic_auth_create_negotiator(strategy::HttpProxyStrategy)::HttpProxyNegotiator
    impl = strategy.impl::BasicAuthImpl
    encoded = Base64.base64encode(string(impl.user_name, ":", impl.password))

    if impl.proxy_connection_type == HttpProxyConnectionType.HTTP_FORWARD
        vtable = HttpProxyNegotiatorForwardingVtable(
            (negotiator, message) -> begin
                hdrs = http_message_get_headers(message)
                http_headers_add(hdrs, "Proxy-Authorization", "Basic $encoded")
                return OP_SUCCESS
            end,
        )
        return HttpProxyNegotiator(impl, false, vtable, nothing)
    else
        # Tunnelling: add auth to CONNECT request
        vtable = HttpProxyNegotiatorTunnellingVtable(
            (negotiator, message, on_done, on_forward, ud) -> begin
                hdrs = http_message_get_headers(message)
                http_headers_add(hdrs, "Proxy-Authorization", "Basic $encoded")
                if on_forward !== nothing
                    on_forward(message, ud)
                end
            end,
            nothing, nothing, nothing,
            (_) -> HttpProxyNegotiationRetryDirective.STOP,
        )
        return HttpProxyNegotiator(impl, true, nothing, vtable)
    end
end

struct HttpProxyStrategyBasicAuthOptions
    proxy_connection_type::HttpProxyConnectionType.T
    user_name::String
    password::String
end

function http_proxy_strategy_new_basic_auth(options::HttpProxyStrategyBasicAuthOptions)::HttpProxyStrategy
    impl = BasicAuthImpl(options.user_name, options.password, options.proxy_connection_type)
    vtable = HttpProxyStrategyVtable(_basic_auth_create_negotiator)
    return HttpProxyStrategy(vtable, impl, options.proxy_connection_type)
end

## Identity strategy (forwarding)

function _forwarding_identity_create_negotiator(strategy::HttpProxyStrategy)::HttpProxyNegotiator
    vtable = HttpProxyNegotiatorForwardingVtable(
        (negotiator, message) -> OP_SUCCESS,
    )
    return HttpProxyNegotiator(nothing, false, vtable, nothing)
end

function http_proxy_strategy_new_forwarding_identity()::HttpProxyStrategy
    vtable = HttpProxyStrategyVtable(_forwarding_identity_create_negotiator)
    return HttpProxyStrategy(vtable, nothing, HttpProxyConnectionType.HTTP_FORWARD)
end

## Identity strategy (tunnelling, one-time)

function _tunneling_identity_create_negotiator(strategy::HttpProxyStrategy)::HttpProxyNegotiator
    vtable = HttpProxyNegotiatorTunnellingVtable(
        (negotiator, message, on_done, on_forward, ud) -> begin
            if on_forward !== nothing
                on_forward(message, ud)
            end
        end,
        nothing, nothing, nothing,
        (_) -> HttpProxyNegotiationRetryDirective.STOP,
    )
    return HttpProxyNegotiator(nothing, true, nothing, vtable)
end

function http_proxy_strategy_new_tunneling_one_time_identity()::HttpProxyStrategy
    vtable = HttpProxyStrategyVtable(_tunneling_identity_create_negotiator)
    return HttpProxyStrategy(vtable, nothing, HttpProxyConnectionType.HTTP_TUNNEL)
end

## Sequence strategy (tunnelling)

struct SequenceImpl
    strategies::Vector{HttpProxyStrategy}
end

function _sequence_create_negotiator(strategy::HttpProxyStrategy)::HttpProxyNegotiator
    impl = strategy.impl::SequenceImpl
    # Create negotiators for all sub-strategies
    sub_negotiators = HttpProxyNegotiator[]
    for sub in impl.strategies
        neg = http_proxy_strategy_create_negotiator(sub)
        neg !== nothing && push!(sub_negotiators, neg)
    end

    current_idx = Ref(1)

    vtable = HttpProxyNegotiatorTunnellingVtable(
        (negotiator, message, on_done, on_forward, ud) -> begin
            if current_idx[] <= length(sub_negotiators)
                sub = sub_negotiators[current_idx[]]
                if sub.is_tunnelling && sub.tunnelling_vtable !== nothing &&
                   sub.tunnelling_vtable.connect_request_transform !== nothing
                    sub.tunnelling_vtable.connect_request_transform(sub, message, on_done, on_forward, ud)
                elseif on_forward !== nothing
                    on_forward(message, ud)
                end
            elseif on_forward !== nothing
                on_forward(message, ud)
            end
        end,
        nothing, nothing, nothing,
        (negotiator) -> begin
            if current_idx[] < length(sub_negotiators)
                current_idx[] += 1
                return HttpProxyNegotiationRetryDirective.NEW_CONNECTION
            end
            return HttpProxyNegotiationRetryDirective.STOP
        end,
    )
    return HttpProxyNegotiator((sub_negotiators, current_idx), true, nothing, vtable)
end

function http_proxy_strategy_new_tunneling_sequence(strategies::AbstractVector{<:HttpProxyStrategy})::HttpProxyStrategy
    vtable = HttpProxyStrategyVtable(_sequence_create_negotiator)
    return HttpProxyStrategy(vtable, SequenceImpl(HttpProxyStrategy[strategies...]), HttpProxyConnectionType.HTTP_TUNNEL)
end

# ─── No-proxy matching ───

"""
    http_host_matches_no_proxy(host, no_proxy) -> Bool

Check if a host matches any pattern in a comma-separated no-proxy list.
Supports domain suffix matching, IP address matching, and wildcard ("*").
"""
function http_host_matches_no_proxy(host::AbstractString, no_proxy::AbstractString)::Bool
    isempty(no_proxy) && return false
    isempty(host) && return false

    host_lower = lowercase(strip(host))

    for entry in eachsplit(no_proxy, ',')
        pattern = lowercase(strip(String(entry)))
        isempty(pattern) && continue

        # Wildcard matches everything
        if pattern == "*"
            return true
        end

        # Strip leading dot for suffix matching
        suffix = startswith(pattern, '.') ? pattern : string('.', pattern)

        # Exact match
        if host_lower == pattern
            return true
        end

        # Domain suffix match: host "foo.example.com" matches ".example.com" or "example.com"
        if endswith(host_lower, suffix)
            return true
        end
    end

    return false
end

# ─── Rewrite URI for forward proxy ───

"""
    http_rewrite_uri_for_proxy_request(request, host, port) -> Int

Rewrite the request path to an absolute URI for forward proxy.
"""
function http_rewrite_uri_for_proxy_request(request::HttpMessage, host::AbstractString, port::UInt32)::Int
    path = http_message_get_request_path(request)
    path === nothing && return raise_error(ERROR_INVALID_STATE)

    # Build absolute URI
    scheme = "http"
    abs_uri = if port == UInt32(80) || port == UInt32(0)
        string(scheme, "://", host, path)
    else
        string(scheme, "://", host, ":", port, path)
    end

    return http_message_set_request_path(request, abs_uri)
end
