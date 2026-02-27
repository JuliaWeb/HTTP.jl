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

# ─── Proxy negotiator interface ───

abstract type HttpProxyNegotiator end

http_proxy_negotiator_is_tunnelling(::HttpProxyNegotiator)::Bool = false
http_proxy_negotiator_forward_request_transform!(::HttpProxyNegotiator, message)::Int = OP_SUCCESS

function http_proxy_negotiator_connect_request_transform!(::HttpProxyNegotiator, message, on_done, on_forward)::Nothing
    on_forward === nothing || on_forward(message)
    return nothing
end

http_proxy_negotiator_on_incoming_headers!(::HttpProxyNegotiator, header_block, headers)::Int = OP_SUCCESS
http_proxy_negotiator_on_status!(::HttpProxyNegotiator, status_code::Int)::Int = OP_SUCCESS
http_proxy_negotiator_on_incoming_body!(::HttpProxyNegotiator, data)::Int = OP_SUCCESS
http_proxy_negotiator_get_retry_directive(::HttpProxyNegotiator)::HttpProxyNegotiationRetryDirective.T = HttpProxyNegotiationRetryDirective.STOP

# ─── Proxy strategy interface ───

abstract type HttpProxyStrategy end

http_proxy_strategy_connection_type(::HttpProxyStrategy)::HttpProxyConnectionType.T = HttpProxyConnectionType.HTTP_LEGACY
http_proxy_strategy_create_negotiator(::HttpProxyStrategy)::Union{HttpProxyNegotiator, Nothing} = nothing

# ─── Proxy options ───

struct HttpProxyOptions
    connection_type::HttpProxyConnectionType.T
    host::String
    port::UInt32
    proxy_strategy::Union{HttpProxyStrategy, Nothing}
    no_proxy_hosts::String
end

function HttpProxyOptions(;
    connection_type::HttpProxyConnectionType.T=HttpProxyConnectionType.HTTP_LEGACY,
    host::String="",
    port::UInt32=UInt32(0),
    proxy_strategy::Union{HttpProxyStrategy, Nothing}=nothing,
    no_proxy_hosts::String="",
)
    return HttpProxyOptions(
        connection_type,
        host,
        port,
        proxy_strategy,
        no_proxy_hosts,
    )
end

# ─── Proxy config (persistent) ───

mutable struct HttpProxyConfig
    connection_type::HttpProxyConnectionType.T
    host::String
    port::UInt32
    proxy_strategy::Union{HttpProxyStrategy, Nothing}
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

struct BasicAuthForwardingNegotiator <: HttpProxyNegotiator
    authorization_header::String
end

function http_proxy_negotiator_forward_request_transform!(n::BasicAuthForwardingNegotiator, message)::Int
    hdrs = http_message_get_headers(message)
    http_headers_add(hdrs, "Proxy-Authorization", n.authorization_header)
    return OP_SUCCESS
end

struct BasicAuthTunnellingNegotiator <: HttpProxyNegotiator
    authorization_header::String
end

http_proxy_negotiator_is_tunnelling(::BasicAuthTunnellingNegotiator)::Bool = true

function http_proxy_negotiator_connect_request_transform!(n::BasicAuthTunnellingNegotiator, message, on_done, on_forward)::Nothing
    hdrs = http_message_get_headers(message)
    http_headers_add(hdrs, "Proxy-Authorization", n.authorization_header)
    on_forward === nothing || on_forward(message)
    return nothing
end

struct BasicAuthProxyStrategy <: HttpProxyStrategy
    connection_type::HttpProxyConnectionType.T
    user_name::String
    password::String
end

http_proxy_strategy_connection_type(strategy::BasicAuthProxyStrategy)::HttpProxyConnectionType.T = strategy.connection_type

function http_proxy_strategy_create_negotiator(strategy::BasicAuthProxyStrategy)::Union{HttpProxyNegotiator, Nothing}
    encoded = Base64.base64encode(string(strategy.user_name, ":", strategy.password))
    auth_header = "Basic $encoded"
    if strategy.connection_type == HttpProxyConnectionType.HTTP_FORWARD
        return BasicAuthForwardingNegotiator(auth_header)
    end
    return BasicAuthTunnellingNegotiator(auth_header)
end

struct HttpProxyStrategyBasicAuthOptions
    proxy_connection_type::HttpProxyConnectionType.T
    user_name::String
    password::String
end

function http_proxy_strategy_new_basic_auth(options::HttpProxyStrategyBasicAuthOptions)::HttpProxyStrategy
    return BasicAuthProxyStrategy(options.proxy_connection_type, options.user_name, options.password)
end

## Identity strategy (forwarding)

struct ForwardingIdentityNegotiator <: HttpProxyNegotiator end

struct ForwardingIdentityProxyStrategy <: HttpProxyStrategy end

http_proxy_strategy_connection_type(::ForwardingIdentityProxyStrategy)::HttpProxyConnectionType.T = HttpProxyConnectionType.HTTP_FORWARD

function http_proxy_strategy_create_negotiator(::ForwardingIdentityProxyStrategy)::Union{HttpProxyNegotiator, Nothing}
    return ForwardingIdentityNegotiator()
end

function http_proxy_strategy_new_forwarding_identity()::HttpProxyStrategy
    return ForwardingIdentityProxyStrategy()
end

## Identity strategy (tunnelling, one-time)

struct TunnelingIdentityNegotiator <: HttpProxyNegotiator end

http_proxy_negotiator_is_tunnelling(::TunnelingIdentityNegotiator)::Bool = true

struct TunnelingIdentityProxyStrategy <: HttpProxyStrategy end

http_proxy_strategy_connection_type(::TunnelingIdentityProxyStrategy)::HttpProxyConnectionType.T = HttpProxyConnectionType.HTTP_TUNNEL

function http_proxy_strategy_create_negotiator(::TunnelingIdentityProxyStrategy)::Union{HttpProxyNegotiator, Nothing}
    return TunnelingIdentityNegotiator()
end

function http_proxy_strategy_new_tunneling_one_time_identity()::HttpProxyStrategy
    return TunnelingIdentityProxyStrategy()
end

## Sequence strategy (tunnelling)

struct SequenceProxyStrategy <: HttpProxyStrategy
    strategies::Vector{HttpProxyStrategy}
end

http_proxy_strategy_connection_type(::SequenceProxyStrategy)::HttpProxyConnectionType.T = HttpProxyConnectionType.HTTP_TUNNEL

mutable struct SequenceTunnellingNegotiator <: HttpProxyNegotiator
    sub_negotiators::Vector{HttpProxyNegotiator}
    current_idx::Int
end

http_proxy_negotiator_is_tunnelling(::SequenceTunnellingNegotiator)::Bool = true

function http_proxy_negotiator_connect_request_transform!(n::SequenceTunnellingNegotiator, message, on_done, on_forward)::Nothing
    if n.current_idx <= length(n.sub_negotiators)
        sub = n.sub_negotiators[n.current_idx]
        if http_proxy_negotiator_is_tunnelling(sub)
            http_proxy_negotiator_connect_request_transform!(sub, message, on_done, on_forward)
        else
            on_forward === nothing || on_forward(message)
        end
    else
        on_forward === nothing || on_forward(message)
    end
    return nothing
end

function http_proxy_negotiator_get_retry_directive(n::SequenceTunnellingNegotiator)::HttpProxyNegotiationRetryDirective.T
    if n.current_idx < length(n.sub_negotiators)
        n.current_idx += 1
        return HttpProxyNegotiationRetryDirective.NEW_CONNECTION
    end
    return HttpProxyNegotiationRetryDirective.STOP
end

function http_proxy_strategy_create_negotiator(strategy::SequenceProxyStrategy)::Union{HttpProxyNegotiator, Nothing}
    sub_negotiators = HttpProxyNegotiator[]
    for sub_strategy in strategy.strategies
        negotiator = http_proxy_strategy_create_negotiator(sub_strategy)
        negotiator === nothing && continue
        push!(sub_negotiators, negotiator)
    end
    return SequenceTunnellingNegotiator(sub_negotiators, 1)
end

function http_proxy_strategy_new_tunneling_sequence(strategies::AbstractVector{<:HttpProxyStrategy})::HttpProxyStrategy
    return SequenceProxyStrategy(HttpProxyStrategy[strategies...])
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
