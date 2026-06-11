# HTTP client proxy planning, env parsing, and no_proxy matching helpers.

using EnumX
using Reseau.HostResolvers

struct _NoProxyIPRule{N}
    ip::NTuple{N,UInt8}
    port::Int32
end

struct _NoProxyCIDRRule{N}
    network::NTuple{N,UInt8}
    prefix_len::UInt8
end

struct _NoProxyDomainRule
    domain::String
    subdomains_only::Bool
    port::Int32
end

"""
    NoProxy(spec)
    NoProxy()

Matcher for `NO_PROXY`-style bypass rules.

`spec` may be a comma-separated string or vector-like collection containing
hostnames, domain suffixes, IP literals, CIDR ranges, or `host:port` entries.
"""
mutable struct NoProxy
    matches_all::Bool
    ipv4::Vector{_NoProxyIPRule{4}}
    ipv6::Vector{_NoProxyIPRule{16}}
    ipv4_cidrs::Vector{_NoProxyCIDRRule{4}}
    ipv6_cidrs::Vector{_NoProxyCIDRRule{16}}
    domains::Vector{_NoProxyDomainRule}
end

struct _ProxyTarget
    url::String
    scheme::String
    secure::Bool
    address::String
    authorization::Union{Nothing,String}
    username::Union{Nothing,String}
    password::Union{Nothing,String}
end

"""
    ProxyConfig(url; no_proxy=nothing)
    ProxyConfig(; http=nothing, https=nothing, all=nothing, no_proxy=nothing, env=false)

HTTP client proxy configuration.

Use this to route plain HTTP, HTTPS, or all traffic through explicit proxy
targets, optionally with `NoProxy` exclusions or environment-driven defaults.
Proxy URLs support `http://`, `https://` parsing for future compatibility
(`https://` proxy transport is not implemented yet), and SOCKS5 proxy
transport with `socks5://` or `socks5h://`. As in Go's `net/http`
transport, `socks5://` and `socks5h://` both send domain targets to the SOCKS
proxy instead of resolving them locally.
"""
struct ProxyConfig
    http::Union{Nothing,_ProxyTarget}
    https::Union{Nothing,_ProxyTarget}
    all::Union{Nothing,_ProxyTarget}
    no_proxy::Union{Nothing,NoProxy}
    refuse_http_proxy_in_cgi::Bool
end

ProxyConfig(
    http::Union{Nothing,_ProxyTarget},
    https::Union{Nothing,_ProxyTarget},
    all::Union{Nothing,_ProxyTarget},
    no_proxy::Union{Nothing,NoProxy},
) = ProxyConfig(http, https, all, no_proxy, false)

@enumx _ProxyPlanMode::UInt8 begin
    DIRECT = 0
    HTTP_FORWARD = 1
    HTTP_TUNNEL = 2
    SOCKS5 = 3
    SOCKS5H = 4
end

struct _ProxyPlan
    mode::_ProxyPlanMode.T
    proxy::Union{Nothing,_ProxyTarget}
    first_hop_address::String
    pool_key::String
end

NoProxy() = NoProxy(false, _NoProxyIPRule{4}[], _NoProxyIPRule{16}[], _NoProxyCIDRRule{4}[], _NoProxyCIDRRule{16}[], _NoProxyDomainRule[])

_parse_ipv4_literal(host::AbstractString)::Union{Nothing,NTuple{4,UInt8}} =
    HostResolvers._parse_ipv4_literal(host)

_parse_ipv6_literal(host::AbstractString)::Union{Nothing,NTuple{16,UInt8}} =
    HostResolvers._parse_ipv6_literal(host)

function _normalize_proxy_host(host::AbstractString)::String
    normalized = lowercase(String(host))
    while !isempty(normalized) && last(normalized) == '.'
        normalized = normalized[1:prevind(normalized, lastindex(normalized))]
    end
    return normalized
end

function _split_host_port_optional(value::AbstractString)::Tuple{String,Int32}
    text = strip(String(value))
    isempty(text) && return "", Int32(-1)
    if startswith(text, "[")
        close_idx = findfirst(']', text)
        close_idx === nothing && return text, Int32(-1)
        if close_idx < lastindex(text) && @inbounds text[nextind(text, close_idx)] == ':'
            host = String(SubString(text, firstindex(text), close_idx))
            port_text = String(SubString(text, nextind(text, nextind(text, close_idx)), lastindex(text)))
            parsed = tryparse(Int, port_text)
            return host, parsed === nothing ? Int32(-1) : Int32(parsed)
        end
        return text, Int32(-1)
    end
    colon_count = count(==(':'), text)
    if colon_count == 1
        host, port = HostResolvers.split_host_port(text)
        parsed = tryparse(Int, port)
        return host, parsed === nothing ? Int32(-1) : Int32(parsed)
    end
    return text, Int32(-1)
end

function _port_matches(rule_port::Int32, port::Int32)::Bool
    return rule_port < 0 || rule_port == port
end

function _is_loopback_ip(ip::NTuple{4,UInt8})::Bool
    return ip[1] == UInt8(127)
end

function _is_loopback_ip(ip::NTuple{16,UInt8})::Bool
    for i in 1:15
        ip[i] == 0x00 || return false
    end
    return ip[16] == 0x01
end

function _cidr_matches(network::NTuple{N,UInt8}, prefix_len::UInt8, ip::NTuple{N,UInt8}) where {N}
    remaining = Int(prefix_len)
    for i in 1:N
        remaining <= 0 && return true
        if remaining >= 8
            network[i] == ip[i] || return false
            remaining -= 8
            continue
        end
        mask = UInt8(0xff << (8 - remaining))
        return (network[i] & mask) == (ip[i] & mask)
    end
    return true
end

function _domain_matches(host::String, rule::_NoProxyDomainRule, port::Int32)::Bool
    _port_matches(rule.port, port) || return false
    if rule.subdomains_only
        return endswith(host, "." * rule.domain)
    end
    host == rule.domain && return true
    return endswith(host, "." * rule.domain)
end

function _parse_no_proxy_entry!(matcher::NoProxy, raw_entry::AbstractString)
    entry = strip(String(raw_entry))
    isempty(entry) && return nothing
    if entry == "*"
        matcher.matches_all && return nothing
        matcher.matches_all = true
        empty!(matcher.ipv4)
        empty!(matcher.ipv6)
        empty!(matcher.ipv4_cidrs)
        empty!(matcher.ipv6_cidrs)
        empty!(matcher.domains)
        return nothing
    end
    host_text, port = _split_host_port_optional(entry)
    host_text = strip(host_text)
    isempty(host_text) && return nothing
    if occursin('/', host_text) && !occursin(':', host_text[findfirst('/', host_text):end])
        host_part, prefix_part = split(host_text, '/'; limit=2)
        prefix = tryparse(Int, prefix_part)
        prefix === nothing && return nothing
        ip4 = _parse_ipv4_literal(host_part)
        if ip4 !== nothing
            0 <= prefix <= 32 || return nothing
            push!(matcher.ipv4_cidrs, _NoProxyCIDRRule{4}(ip4::NTuple{4,UInt8}, UInt8(prefix)))
            return nothing
        end
        ip6 = _parse_ipv6_literal(host_part)
        if ip6 !== nothing
            0 <= prefix <= 128 || return nothing
            push!(matcher.ipv6_cidrs, _NoProxyCIDRRule{16}(ip6::NTuple{16,UInt8}, UInt8(prefix)))
            return nothing
        end
        return nothing
    end
    host_for_ip = startswith(host_text, "[") && endswith(host_text, "]") ? String(SubString(host_text, nextind(host_text, firstindex(host_text)), prevind(host_text, lastindex(host_text)))) : host_text
    ip4 = _parse_ipv4_literal(host_for_ip)
    if ip4 !== nothing
        push!(matcher.ipv4, _NoProxyIPRule{4}(ip4::NTuple{4,UInt8}, port))
        return nothing
    end
    ip6 = _parse_ipv6_literal(host_for_ip)
    if ip6 !== nothing
        push!(matcher.ipv6, _NoProxyIPRule{16}(ip6::NTuple{16,UInt8}, port))
        return nothing
    end
    host = _normalize_proxy_host(startswith(host_text, "*.") ? String(SubString(host_text, 3)) : (startswith(host_text, ".") ? String(SubString(host_text, 2)) : host_text))
    isempty(host) && return nothing
    subdomains_only = startswith(host_text, ".") || startswith(host_text, "*.")
    push!(matcher.domains, _NoProxyDomainRule(host, subdomains_only, port))
    return nothing
end

function NoProxy(spec)::NoProxy
    matcher = NoProxy()
    if spec isa AbstractString
        for entry in split(String(spec), ','; keepempty=false)
            _parse_no_proxy_entry!(matcher, entry)
        end
        return matcher
    end
    if spec isa AbstractVector
        for entry in spec
            _parse_no_proxy_entry!(matcher, string(entry))
        end
        return matcher
    end
    throw(ArgumentError("unsupported no_proxy spec type $(typeof(spec)); expected String or vector-like collection"))
end

function _matches_no_proxy(matcher::NoProxy, host::AbstractString, port::Integer)::Bool
    matcher.matches_all && return true
    normalized_host = _normalize_proxy_host(host)
    isempty(normalized_host) && return false
    port32 = Int32(port)
    normalized_host == "localhost" && return true
    ipv4 = _parse_ipv4_literal(normalized_host)
    if ipv4 !== nothing
        _is_loopback_ip(ipv4::NTuple{4,UInt8}) && return true
        for rule in matcher.ipv4
            rule.ip == ipv4 && _port_matches(rule.port, port32) && return true
        end
        for rule in matcher.ipv4_cidrs
            _cidr_matches(rule.network, rule.prefix_len, ipv4::NTuple{4,UInt8}) && return true
        end
    end
    ipv6 = _parse_ipv6_literal(normalized_host)
    if ipv6 !== nothing
        _is_loopback_ip(ipv6::NTuple{16,UInt8}) && return true
        for rule in matcher.ipv6
            rule.ip == ipv6 && _port_matches(rule.port, port32) && return true
        end
        for rule in matcher.ipv6_cidrs
            _cidr_matches(rule.network, rule.prefix_len, ipv6::NTuple{16,UInt8}) && return true
        end
    end
    for rule in matcher.domains
        _domain_matches(normalized_host, rule, port32) && return true
    end
    return false
end

@inline function _proxy_default_port(scheme::String)::UInt16
    scheme == "http" && return UInt16(80)
    scheme == "https" && return UInt16(443)
    (scheme == "socks5" || scheme == "socks5h") && return UInt16(1080)
    throw(ArgumentError("unsupported proxy scheme '$scheme'"))
end

@inline function _proxy_scheme_supported(scheme::String)::Bool
    return scheme == "http" || scheme == "https" || scheme == "socks5" || scheme == "socks5h"
end

@inline function _proxy_scheme_is_socks(scheme::String)::Bool
    return scheme == "socks5" || scheme == "socks5h"
end

function _proxy_url_scheme(value::AbstractString)::Tuple{String,String}
    text = String(value)
    scheme_idx = findfirst("://", text)
    if scheme_idx === nothing
        return "http", "http://" * text
    end
    scheme = lowercase(String(SubString(text, firstindex(text), prevind(text, first(scheme_idx)))))
    return scheme, text
end

function _parse_socks_proxy_target(value::AbstractString, scheme::String)::_ProxyTarget
    value = String(value)
    scheme_idx = findfirst("://", value)
    scheme_idx === nothing && throw(ArgumentError("proxy URL must include a scheme"))
    authority_start = nextind(value, last(scheme_idx))
    authority_start > lastindex(value) && throw(ArgumentError("proxy URL missing host: $value"))
    authority_stop = lastindex(value)
    for byte in ('/', '?', '#')
        idx = findnext(byte, value, authority_start)
        idx === nothing && continue
        authority_stop = min(authority_stop, prevind(value, idx))
    end
    authority_start <= authority_stop || throw(ArgumentError("proxy URL missing host: $value"))
    authority = String(SubString(value, authority_start, authority_stop))

    userinfo = nothing
    hostport = authority
    # Byte scan instead of findlast(==('@'), ...): the predicate form lands on
    # the generic Function method, which the juliac trim verifier rejects.
    at_idx = _find_last_url_byte(codeunits(authority), firstindex(authority), lastindex(authority), UInt8('@'))
    if at_idx !== nothing
        userinfo = String(SubString(authority, firstindex(authority), prevind(authority, at_idx)))
        hostport = String(SubString(authority, nextind(authority, at_idx), lastindex(authority)))
    end
    isempty(hostport) && throw(ArgumentError("proxy URL missing host: $value"))

    host = hostport
    port_text = ""
    if startswith(hostport, "[")
        close_idx = findfirst(']', hostport)
        close_idx === nothing && throw(ArgumentError("invalid IPv6 proxy authority: $hostport"))
        host = String(SubString(hostport, nextind(hostport, firstindex(hostport)), prevind(hostport, close_idx)))
        if close_idx < lastindex(hostport)
            colon_idx = nextind(hostport, close_idx)
            @inbounds hostport[colon_idx] == ':' || throw(ArgumentError("invalid IPv6 proxy authority: $hostport"))
            port_text = String(SubString(hostport, nextind(hostport, colon_idx), lastindex(hostport)))
        end
    elseif occursin(':', hostport)
        host, port_text = try
            HostResolvers.split_host_port(hostport)
        catch err
            ex = err::Exception
            ex isa HostResolvers.AddressError || rethrow(ex)
            throw(ArgumentError("invalid proxy URL authority: $hostport"))
        end
    end
    isempty(host) && throw(ArgumentError("proxy URL missing host: $value"))
    port = if isempty(port_text)
        _proxy_default_port(scheme)
    else
        all(ch -> '0' <= ch <= '9', port_text) || throw(ArgumentError("invalid proxy URL port: $port_text"))
        parsed_port = tryparse(Int, port_text)
        parsed_port === nothing && throw(ArgumentError("invalid proxy URL port: $port_text"))
        1 <= parsed_port <= 0xffff || throw(ArgumentError("proxy URL port out of range: $parsed_port"))
        UInt16(parsed_port)
    end
    address = HostResolvers.join_host_port(host, Int(port))
    authorization = nothing
    username = nothing
    password = nothing
    if userinfo !== nothing && !isempty(userinfo::String)
        authorization = _userinfo_basic_authorization(userinfo::String)
        username, password = _userinfo_username_password(userinfo::String)
    end
    return _ProxyTarget(
        string(scheme, "://", address, "/"),
        scheme,
        false,
        address,
        authorization,
        username,
        password,
    )
end

function _parse_proxy_target(url::AbstractString, allow_unsupported::Bool=false)::_ProxyTarget
    value = strip(String(url))
    isempty(value) && throw(ArgumentError("proxy URL must not be empty"))
    scheme, value = _proxy_url_scheme(value)
    if !_proxy_scheme_supported(scheme)
        allow_unsupported || throw(ArgumentError("unsupported proxy scheme '$scheme'"))
        throw(ArgumentError("unsupported proxy scheme '$scheme'"))
    end
    _proxy_scheme_is_socks(scheme) && return _parse_socks_proxy_target(value, scheme)
    parsed = _parse_http_url(value)
    return _ProxyTarget(
        parsed.url,
        scheme,
        parsed.secure,
        parsed.address,
        parsed.authorization,
        nothing,
        nothing,
    )
end

function _proxy_target(value)::Union{Nothing,_ProxyTarget}
    value === nothing && return nothing
    value isa _ProxyTarget && return value
    value isa AbstractString && return _parse_proxy_target(value)
    throw(ArgumentError("proxy target must be nothing or a proxy URL string"))
end

function _env_proxy(names::Vararg{String})::Union{Nothing,_ProxyTarget}
    for name in names
        value = get(() -> "", ENV, name)
        isempty(strip(value)) && continue
        try
            return _parse_proxy_target(value)
        catch
            return nothing
        end
    end
    return nothing
end

function _env_no_proxy()::Union{Nothing,NoProxy}
    raw = get(() -> get(() -> "", ENV, "no_proxy"), ENV, "NO_PROXY")
    isempty(strip(raw)) && return nothing
    return NoProxy(raw)
end

@inline function _cgi_http_proxy_refusal()::Bool
    return !isempty(get(() -> "", ENV, "REQUEST_METHOD"))
end

const _CGI_HTTP_PROXY_ERROR = "refusing to use HTTP_PROXY value in CGI environment; see golang.org/s/cgihttpproxy"

function ProxyConfig(url::AbstractString; no_proxy=nothing)::ProxyConfig
    matcher = no_proxy === nothing ? nothing : NoProxy(no_proxy)
    return ProxyConfig(nothing, nothing, _parse_proxy_target(url), matcher)
end

function ProxyConfig(;
    http=nothing,
    https=nothing,
    all=nothing,
    no_proxy=nothing,
    env::Bool=false,
)::ProxyConfig
    matcher = no_proxy === nothing ? (env ? _env_no_proxy() : nothing) : NoProxy(no_proxy)
    http_proxy = http === nothing ? (env ? _env_proxy("HTTP_PROXY", "http_proxy") : nothing) : _proxy_target(http)
    https_proxy = https === nothing ? (env ? _env_proxy("HTTPS_PROXY", "https_proxy") : nothing) : _proxy_target(https)
    all_proxy = all === nothing ? (env ? _env_proxy("ALL_PROXY", "all_proxy") : nothing) : _proxy_target(all)
    return ProxyConfig(
        http_proxy,
        https_proxy,
        all_proxy,
        matcher,
        env && http === nothing && http_proxy !== nothing && _cgi_http_proxy_refusal(),
    )
end

"""
    ProxyURL(url; no_proxy=nothing) -> ProxyConfig

Convenience constructor for a single proxy URL applied to all outbound
requests. Supported proxy URL schemes are `http://`, `https://` (parsed but
not yet dialed as a TLS proxy), `socks5://`, and `socks5h://`.
"""
function ProxyURL(url::AbstractString; no_proxy=nothing)::ProxyConfig
    return ProxyConfig(url; no_proxy=no_proxy)
end

"""
    ProxyFromEnvironment() -> ProxyConfig

Load proxy configuration from the standard `HTTP_PROXY`, `HTTPS_PROXY`,
`ALL_PROXY`, and `NO_PROXY` environment variables. Proxy values may use the
same schemes accepted by `ProxyURL`, including `socks5://` and `socks5h://`.
"""
function ProxyFromEnvironment()::ProxyConfig
    return ProxyConfig(; env=true)
end

function _normalize_proxy_config(proxy)::ProxyConfig
    proxy === nothing && return ProxyConfig()
    proxy isa ProxyConfig && return proxy
    proxy isa AbstractString && return ProxyURL(proxy)
    throw(ArgumentError("proxy must be nothing, a proxy URL string, or ProxyConfig"))
end

function _proxy_for(
    config::ProxyConfig,
    secure::Bool,
    host::AbstractString,
    port::Integer,
)::Union{Nothing,_ProxyTarget}
    !secure && config.refuse_http_proxy_in_cgi && throw(ArgumentError(_CGI_HTTP_PROXY_ERROR))
    config.no_proxy !== nothing && _matches_no_proxy(config.no_proxy::NoProxy, host, port) && return nothing
    if secure
        config.https !== nothing && return config.https::_ProxyTarget
    else
        config.http !== nothing && return config.http::_ProxyTarget
    end
    return config.all
end

function _proxy_plan(
    config::ProxyConfig,
    secure::Bool,
    address::AbstractString,
)::_ProxyPlan
    host, port_text = HostResolvers.split_host_port(String(address))
    port = tryparse(Int, port_text)
    port === nothing && throw(ArgumentError("invalid address port in proxy planning: $address"))
    proxy = _proxy_for(config, secure, host, port)
    if proxy === nothing
        return _ProxyPlan(_ProxyPlanMode.DIRECT, nothing, String(address), string(secure ? "https://" : "http://", address))
    end
    (proxy::_ProxyTarget).secure && throw(ArgumentError("https proxy URLs are not supported yet"))
    mode = if _proxy_scheme_is_socks((proxy::_ProxyTarget).scheme)
        (proxy::_ProxyTarget).scheme == "socks5h" ? _ProxyPlanMode.SOCKS5H : _ProxyPlanMode.SOCKS5
    else
        secure ? _ProxyPlanMode.HTTP_TUNNEL : _ProxyPlanMode.HTTP_FORWARD
    end
    return _ProxyPlan(mode, proxy::_ProxyTarget, (proxy::_ProxyTarget).address, string((proxy::_ProxyTarget).url, "|", secure ? "https://" : "http://", address))
end
