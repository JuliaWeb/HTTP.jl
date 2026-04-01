# HTTP client URL parsing, request-target, and query-string helpers.
struct _TextRange
    first::Int
    last::Int
end

const _EMPTY_TEXT_RANGE = _TextRange(0, 0)

@inline function _text_range(lo::Int, hi::Int)::_TextRange
    return lo <= hi ? _TextRange(lo, hi) : _EMPTY_TEXT_RANGE
end

@inline function _text_range_empty(r::_TextRange)::Bool
    return r.first == 0
end

@inline function _text_range_string(source::String, r::_TextRange)::String
    _text_range_empty(r) && return ""
    return String(SubString(source, r.first, r.last))
end

@inline function _find_url_byte(
    bytes::Base.CodeUnits{UInt8,String},
    lo::Int,
    hi::Int,
    byte::UInt8,
)::Union{Nothing,Int}
    lo > hi && return nothing
    @inbounds for i in lo:hi
        bytes[i] == byte && return i
    end
    return nothing
end

@inline function _find_last_url_byte(
    bytes::Base.CodeUnits{UInt8,String},
    lo::Int,
    hi::Int,
    byte::UInt8,
)::Union{Nothing,Int}
    lo > hi && return nothing
    @inbounds for i in hi:-1:lo
        bytes[i] == byte && return i
    end
    return nothing
end

@inline function _find_first_url_sep(
    bytes::Base.CodeUnits{UInt8,String},
    lo::Int,
    hi::Int,
)::Union{Nothing,Int}
    lo > hi && return nothing
    @inbounds for i in lo:hi
        b = bytes[i]
        (b == UInt8('/') || b == UInt8('?')) && return i
    end
    return nothing
end

@inline function _ascii_equal_fold_literal(
    bytes::Base.CodeUnits{UInt8,String},
    lo::Int,
    hi::Int,
    literal::String,
)::Bool
    n = hi >= lo ? (hi - lo + 1) : 0
    n == ncodeunits(literal) || return false
    @inbounds for j in 1:n
        _to_ascii_lower(bytes[lo+j-1]) == _to_ascii_lower(codeunit(literal, j)) || return false
    end
    return true
end

mutable struct _URLParts
    source::String
    secure::Bool
    default_port::UInt16
    authority_range::_TextRange
    host_range::_TextRange
    userinfo_range::_TextRange
    target_range::_TextRange
    query_suffix::String
    has_explicit_port::Bool
    target_starts_with_query::Bool
    has_userinfo::Bool
    address_cache::String
    target_cache::String
    server_name_cache::String
    url_cache::String
    authorization_cache::String
end

function _urlparts_address!(parts::_URLParts)::String
    cached = getfield(parts, :address_cache)
    isempty(cached) || return cached
    source = getfield(parts, :source)
    address = if getfield(parts, :has_explicit_port)
        _text_range_string(source, getfield(parts, :authority_range))
    else
        host = _text_range_string(source, getfield(parts, :host_range))
        HostResolvers.join_host_port(host, Int(getfield(parts, :default_port)))
    end
    setfield!(parts, :address_cache, address)
    return address
end

function _urlparts_target!(parts::_URLParts)::String
    cached = getfield(parts, :target_cache)
    isempty(cached) || return cached
    source = getfield(parts, :source)
    query_suffix = getfield(parts, :query_suffix)
    target_range = getfield(parts, :target_range)
    target = if _text_range_empty(target_range)
        isempty(query_suffix) ? "/" : string("/?", query_suffix)
    else
        base = if getfield(parts, :target_starts_with_query)
            string("/", SubString(source, target_range.first, target_range.last))
        else
            String(SubString(source, target_range.first, target_range.last))
        end
        isempty(query_suffix) ? base : _append_query(base, query_suffix)
    end
    setfield!(parts, :target_cache, target)
    return target
end

function _urlparts_server_name!(parts::_URLParts)::String
    cached = getfield(parts, :server_name_cache)
    isempty(cached) || return cached
    source = getfield(parts, :source)
    server_name = if getfield(parts, :has_explicit_port)
        host, _ = HostResolvers.split_host_port(_urlparts_address!(parts))
        host
    else
        _text_range_string(source, getfield(parts, :host_range))
    end
    setfield!(parts, :server_name_cache, server_name)
    return server_name
end

function _urlparts_url!(parts::_URLParts)::String
    cached = getfield(parts, :url_cache)
    isempty(cached) || return cached
    url = _request_url(getfield(parts, :secure), _urlparts_address!(parts), _urlparts_target!(parts))
    setfield!(parts, :url_cache, url)
    return url
end

function _urlparts_authorization!(parts::_URLParts)::Union{Nothing,String}
    getfield(parts, :has_userinfo) || return nothing
    cached = getfield(parts, :authorization_cache)
    isempty(cached) || return cached
    userinfo = _text_range_string(getfield(parts, :source), getfield(parts, :userinfo_range))
    authorization = _userinfo_basic_authorization(userinfo)
    setfield!(parts, :authorization_cache, authorization)
    return authorization
end

function Base.getproperty(parts::_URLParts, sym::Symbol)
    if sym === :secure
        return getfield(parts, :secure)
    elseif sym === :address
        return _urlparts_address!(parts)
    elseif sym === :target
        return _urlparts_target!(parts)
    elseif sym === :server_name
        return _urlparts_server_name!(parts)
    elseif sym === :url
        return _urlparts_url!(parts)
    elseif sym === :authorization
        return _urlparts_authorization!(parts)
    end
    return getfield(parts, sym)
end

function Base.propertynames(::_URLParts, private::Bool=false)
    return private ? fieldnames(_URLParts) : (:secure, :address, :target, :server_name, :url, :authorization)
end

@inline function _request_url(secure::Bool, address::String, target::String)::String
    return string(secure ? "https://" : "http://", address, target)
end

@inline function _userinfo_basic_authorization(userinfo::AbstractString)::String
    parts_split = split(userinfo, ':'; limit=2)
    username = parts_split[1]
    password = length(parts_split) == 2 ? parts_split[2] : ""
    return "Basic " * base64encode(string(username, ":", password))
end

function _query_string(query)::String
    query === nothing && return ""
    query isa AbstractString && return String(query)
    _is_unreserved_query_byte(b::UInt8) = (
        (b >= UInt8('A') && b <= UInt8('Z')) ||
        (b >= UInt8('a') && b <= UInt8('z')) ||
        (b >= UInt8('0') && b <= UInt8('9')) ||
        b == UInt8('-') ||
        b == UInt8('.') ||
        b == UInt8('_') ||
        b == UInt8('~')
    )
    function _percent_encode_query_component(value)::String
        text = string(value)
        encoded = IOBuffer()
        for b in codeunits(text)
            if _is_unreserved_query_byte(b)
                write(encoded, b)
            else
                print(encoded, '%')
                print(encoded, uppercase(string(b, base=16, pad=2)))
            end
        end
        return String(take!(encoded))
    end
    _pair_string(k, v) = string(_percent_encode_query_component(k), "=", _percent_encode_query_component(v))
    parts = String[]
    if query isa AbstractDict
        query_pairs = collect(pairs(query))
        sort!(query_pairs; by=x -> String(x.first))
        for (k, v) in query_pairs
            push!(parts, _pair_string(k, v))
        end
        return join(parts, "&")
    end
    if query isa AbstractVector
        for item in query
            if item isa Pair
                pair = item::Pair
                push!(parts, _pair_string(pair.first, pair.second))
                continue
            end
            if item isa Tuple && length(item) == 2
                tup = item::Tuple
                push!(parts, _pair_string(tup[1], tup[2]))
                continue
            end
            throw(ArgumentError("unsupported query entry type $(typeof(item)); expected Pair or 2-tuple"))
        end
        return join(parts, "&")
    end
    throw(ArgumentError("unsupported query type $(typeof(query)); expected String, Dict, or vector of Pair/tuples"))
end

function _append_query(target::String, query)::String
    query_s = _query_string(query)
    isempty(query_s) && return target
    occursin('?', target) && return string(target, "&", query_s)
    return string(target, "?", query_s)
end

@inline _uri_component_present(component)::Bool = component !== URIs.absent

@inline function _uri_component_string(component)::String
    return _uri_component_present(component) ? String(component) : ""
end

function _uri_request_target(uri::URI)::String
    path = _uri_component_string(uri.path)
    has_query = _uri_component_present(uri.query)
    query = has_query ? String(uri.query) : ""
    if isempty(path)
        return has_query ? string("/?", query) : "/"
    end
    return has_query ? string(path, "?", query) : path
end

function _parse_http_url(url::AbstractString, query=nothing)::_URLParts
    s = url isa String ? url : String(url)
    bytes = codeunits(s)
    scheme_idx = findfirst("://", s)
    scheme_idx === nothing && throw(ArgumentError("URL must include http:// or https:// scheme: $s"))
    scheme_start = first(scheme_idx)
    scheme_end = last(scheme_idx)
    scheme_last = prevind(s, scheme_start)
    secure = if _ascii_equal_fold_literal(bytes, firstindex(s), scheme_last, "http")
        false
    elseif _ascii_equal_fold_literal(bytes, firstindex(s), scheme_last, "https")
        true
    else
        scheme = String(SubString(s, firstindex(s), scheme_last))
        throw(ArgumentError("unsupported URL scheme '$scheme'; expected http or https"))
    end
    rest_start = nextind(s, scheme_end)
    rest_start > lastindex(s) && throw(ArgumentError("URL missing authority: $s"))
    fragment_idx = _find_url_byte(bytes, rest_start, lastindex(s), UInt8('#'))
    rest_last = fragment_idx === nothing ? lastindex(s) : prevind(s, fragment_idx)
    sep = _find_first_url_sep(bytes, rest_start, rest_last)
    authority_range = sep === nothing ? _text_range(rest_start, rest_last) : _text_range(rest_start, prevind(s, sep))
    target_range = sep === nothing ? _EMPTY_TEXT_RANGE : _text_range(sep, rest_last)
    target_starts_with_query = sep !== nothing && @inbounds bytes[sep] == UInt8('?')

    userinfo_range = _EMPTY_TEXT_RANGE
    has_userinfo = false
    at_idx = _text_range_empty(authority_range) ? nothing : _find_last_url_byte(bytes, authority_range.first, authority_range.last, UInt8('@'))
    if at_idx !== nothing
        userinfo_range = _text_range(authority_range.first, prevind(s, at_idx))
        has_userinfo = !_text_range_empty(userinfo_range)
        authority_range = _text_range(nextind(s, at_idx), authority_range.last)
    end

    _text_range_empty(authority_range) && throw(ArgumentError("URL missing host: $s"))

    host_range = authority_range
    has_explicit_port = false
    if @inbounds bytes[authority_range.first] == UInt8('[')
        close_idx = _find_url_byte(bytes, authority_range.first, authority_range.last, UInt8(']'))
        close_idx === nothing && throw(ArgumentError("invalid IPv6 host authority: $(_text_range_string(s, authority_range))"))
        host_range = _text_range(nextind(s, authority_range.first), prevind(s, close_idx))
        if close_idx < authority_range.last
            next_after_close = nextind(s, close_idx)
            has_explicit_port = next_after_close <= authority_range.last && @inbounds(bytes[next_after_close] == UInt8(':'))
        end
    else
        has_explicit_port = _find_last_url_byte(bytes, authority_range.first, authority_range.last, UInt8(':')) !== nothing
        has_explicit_port || (host_range = authority_range)
    end

    query_suffix = query === nothing ? "" : _query_string(query)
    default_port = secure ? UInt16(443) : UInt16(80)
    return _URLParts(
        s,
        secure,
        default_port,
        authority_range,
        host_range,
        userinfo_range,
        target_range,
        query_suffix,
        has_explicit_port,
        target_starts_with_query,
        has_userinfo,
        "",
        "",
        "",
        "",
        "",
    )
end

function _parse_http_url(url::URI, query=nothing)::_URLParts
    source = string(url)
    scheme = _uri_component_present(url.scheme) ? String(url.scheme) : ""
    secure = if scheme == "http"
        false
    elseif scheme == "https"
        true
    elseif isempty(scheme)
        throw(ArgumentError("URL must include http:// or https:// scheme: $source"))
    else
        throw(ArgumentError("unsupported URL scheme '$scheme'; expected http or https"))
    end

    host = _uri_component_string(url.host)
    isempty(host) && throw(ArgumentError("URL missing host: $source"))

    default_port = secure ? UInt16(443) : UInt16(80)
    has_explicit_port = _uri_component_present(url.port)
    address = if has_explicit_port
        string(URIs.hoststring(host), ":", String(url.port))
    else
        HostResolvers.join_host_port(host, Int(default_port))
    end

    target = _uri_request_target(url)
    query === nothing || (target = _append_query(target, query))

    has_userinfo = _uri_component_present(url.userinfo) && !isempty(url.userinfo)
    authorization = has_userinfo ? _userinfo_basic_authorization(String(url.userinfo)) : nothing
    return _URLParts(
        source,
        secure,
        default_port,
        _EMPTY_TEXT_RANGE,
        _EMPTY_TEXT_RANGE,
        _EMPTY_TEXT_RANGE,
        _EMPTY_TEXT_RANGE,
        "",
        has_explicit_port,
        startswith(target, "/?"),
        has_userinfo,
        address,
        target,
        host,
        _request_url(secure, address, target),
        authorization === nothing ? "" : authorization,
    )
end
