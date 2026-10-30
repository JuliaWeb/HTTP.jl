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
    target = _escape_target_spaces(target)
    setfield!(parts, :target_cache, target)
    return target
end

# A request target cannot contain a space (RFC 9112 §3.2), so send each as
# `%20`, as browsers do, rather than split the request line.
@inline function _escape_target_spaces(target::String)::String
    return occursin(' ', target) ? replace(target, ' ' => "%20") : target
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

# Authority for the `Host` header, as written in the URL: an explicit port is
# kept and a default port is never added, because servers that compare `Host`
# verbatim (e.g. AWS SigV4 signing) reject `host:443`. For a default-port URL,
# trim the port off `address` rather than using `server_name`, which drops the
# IPv6 brackets that `Host` requires.
function _urlparts_host_header!(parts::_URLParts)::String
    getfield(parts, :has_explicit_port) && return _urlparts_address!(parts)
    address = _urlparts_address!(parts)
    suffix = string(':', Int(getfield(parts, :default_port)))
    return String(chopsuffix(address, suffix))
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
    elseif sym === :host_header
        return _urlparts_host_header!(parts)
    elseif sym === :url
        return _urlparts_url!(parts)
    elseif sym === :authorization
        return _urlparts_authorization!(parts)
    end
    return getfield(parts, sym)
end

function Base.propertynames(::_URLParts, private::Bool=false)
    return private ? fieldnames(_URLParts) :
           (:secure, :address, :target, :server_name, :host_header, :url, :authorization)
end

@inline function _request_url(secure::Bool, address::String, target::String)::String
    return string(secure ? "https://" : "http://", address, target)
end

@inline function _userinfo_username_password(userinfo::AbstractString)::Tuple{String,String}
    # Per RFC 3986 §3.2.1 the userinfo sub-components are percent-encoded; decode
    # them before they are used for Basic or SOCKS username/password credentials.
    parts_split = split(userinfo, ':'; limit=2)
    username = URIs.unescapeuri(parts_split[1])
    password = length(parts_split) == 2 ? URIs.unescapeuri(parts_split[2]) : ""
    return username, password
end

@inline function _userinfo_basic_authorization(userinfo::AbstractString)::String
    username, password = _userinfo_username_password(userinfo)
    return "Basic " * _base64encode(string(username, ":", password))
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
    # RFC 3986 §3.3: after an authority the path is empty or starts with "/".
    startswith(path, '/') || throw(ArgumentError("URL path must start with \"/\" after the host: $(repr(path))"))
    return has_query ? string(path, "?", query) : path
end

# RFC 3986 §3.2.3: a port is decimal digits; a connection also needs 1-65535.
function _check_url_port(port::AbstractString)::Nothing
    n = all(isdigit, port) ? tryparse(Int, port) : nothing
    n !== nothing && 1 <= n <= 65535 && return nothing
    throw(ArgumentError("invalid URL port: $(repr(port))"))
end

@inline function _is_url_sub_delim(b::UInt8)::Bool
    return b == UInt8('!') || b == UInt8('$') || b == UInt8('&') || b == UInt8('\'') ||
        b == UInt8('(') || b == UInt8(')') || b == UInt8('*') || b == UInt8('+') ||
        b == UInt8(',') || b == UInt8(';') || b == UInt8('=')
end

@inline _is_url_hex(b::UInt8)::Bool = 0x30 <= b <= 0x39 || 0x41 <= b <= 0x46 || 0x61 <= b <= 0x66

# RFC 3986 §3.2.1 userinfo, plus `@` (the last `@` ends the userinfo, as in Go
# and browsers) and non-ASCII bytes. Any other byte, such as a backslash, which
# browsers read as the end of the authority, is rejected.
function _check_url_userinfo(bytes::AbstractVector{UInt8}, lo::Int, hi::Int)::Nothing
    i = lo
    while i <= hi
        b = @inbounds bytes[i]
        if b == UInt8('%')
            (i + 2 <= hi && _is_url_hex(bytes[i + 1]) && _is_url_hex(bytes[i + 2])) ||
                throw(ArgumentError("invalid percent-encoding in URL userinfo"))
            i += 3
            continue
        end
        (b >= 0x80 || b == UInt8(':') || b == UInt8('@') || _is_unreserved_form_byte(b) || _is_url_sub_delim(b)) ||
            throw(ArgumentError("invalid character $(repr(Char(b))) in URL userinfo"))
        i += 1
    end
    return nothing
end

# A URL host the client dials as written: an IPv6 address (`bracketed`, with an
# optional zone) or an RFC 3986 §3.2.2 reg-name of unreserved and sub-delim
# characters and non-ASCII bytes. Hosts are not percent-decoded, so `%` is
# rejected outside a zone.
function _check_url_host(host::AbstractString, bracketed::Bool)::Nothing
    bytes = codeunits(host)
    if bracketed
        zone = findfirst(==(UInt8('%')), bytes)
        stop = zone === nothing ? length(bytes) : zone - 1
        valid = stop > 0 && all(b -> _is_url_hex(b) || b == UInt8(':') || b == UInt8('.'), @view(bytes[1:stop])) &&
            HostResolvers._parse_ipv6_literal(SubString(host, 1, stop)) !== nothing &&
            (zone === nothing || (zone < length(bytes) &&
                all(b -> _is_unreserved_form_byte(b) || b == UInt8('%'), @view(bytes[(zone + 1):end]))))
        valid || throw(ArgumentError("invalid IPv6 address in URL host: $(repr(host))"))
        return nothing
    end
    for b in bytes
        (b >= 0x80 || _is_unreserved_form_byte(b) || _is_url_sub_delim(b)) ||
            throw(ArgumentError("invalid character $(repr(Char(b))) in URL host $(repr(host))"))
    end
    # RFC 3986 §7.4: system resolvers read other numeric forms (`127.1`,
    # `0x7f.1`, `2130706433`, `010.0.0.1`) as IPv4 addresses, differently on
    # each platform, while URL parsers such as URIs.jl see a host name.
    _host_ends_in_number(bytes) && !_is_dotted_decimal_ipv4(host) &&
        throw(ArgumentError("invalid IPv4 address in URL host $(repr(host)); only dotted-decimal form is allowed"))
    return nothing
end

# RFC 3986 §3.2.2 IPv4address: four decimal octets without leading zeros.
# `inet_pton` cannot decide this: macOS accepts `010.0.0.1` as 10.0.0.1.
function _is_dotted_decimal_ipv4(host::AbstractString)::Bool
    parts = split(host, '.')
    length(parts) == 4 || return false
    return all(p -> 1 <= ncodeunits(p) <= 3 && all(isdigit, p) && (p == "0" || p[1] != '0') &&
        parse(Int, p) <= 255, parts)
end

# Whether the last label, ignoring one trailing dot, is decimal digits or
# `0x` hex: a host the WHATWG URL parser reads as an IPv4 address.
function _host_ends_in_number(bytes::AbstractVector{UInt8})::Bool
    hi = lastindex(bytes)
    hi >= 1 && bytes[hi] == UInt8('.') && (hi -= 1)
    lo = hi
    while lo >= 1 && bytes[lo] != UInt8('.')
        lo -= 1
    end
    label = @view bytes[(lo + 1):hi]
    isempty(label) && return false
    all(b -> UInt8('0') <= b <= UInt8('9'), label) && return true
    return length(label) >= 2 && label[1] == UInt8('0') && (label[2] | 0x20) == UInt8('x') &&
        all(_is_url_hex, @view label[3:end])
end

# `url` with any userinfo left out, for error messages.
function _url_for_message(url::AbstractString)::String
    s = String(url)
    sep = findfirst("://", s)
    if sep === nothing
        # Where the authority is cannot be told, so drop everything up to the last `@`.
        at = findprev(isequal('@'), s, lastindex(s))
        return at === nothing ? s : String(SubString(s, nextind(s, at)))
    end
    start = last(sep) + 1
    stop = something(findnext(c -> c == '/' || c == '?' || c == '#', s, start), ncodeunits(s) + 1)
    at = findprev('@', s, prevind(s, stop))
    (at === nothing || at < start) && return s
    return string(SubString(s, 1, prevind(s, start)), SubString(s, nextind(s, at)))
end

function _parse_http_url(url::AbstractString, query=nothing)::_URLParts
    s = url isa String ? url : String(url)
    bytes = codeunits(s)
    scheme_idx = findfirst("://", s)
    scheme_idx === nothing && throw(ArgumentError("URL must include http:// or https:// scheme: $(_url_for_message(s))"))
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
        _check_url_userinfo(bytes, authority_range.first, at_idx - 1)
        userinfo_range = _text_range(authority_range.first, prevind(s, at_idx))
        has_userinfo = !_text_range_empty(userinfo_range)
        authority_range = _text_range(nextind(s, at_idx), authority_range.last)
    end
    # An empty port (`host:`) means the scheme's default port (RFC 3986 §3.2.3).
    if !_text_range_empty(authority_range) && @inbounds(bytes[authority_range.last] == UInt8(':'))
        authority_range = _text_range(authority_range.first, prevind(s, authority_range.last))
    end

    _text_range_empty(authority_range) && throw(ArgumentError("URL missing host: $(_url_for_message(s))"))

    host_range = authority_range
    port_first = 0
    bracketed = @inbounds bytes[authority_range.first] == UInt8('[')
    if bracketed
        close_idx = _find_url_byte(bytes, authority_range.first, authority_range.last, UInt8(']'))
        close_idx === nothing && throw(ArgumentError("invalid IPv6 host authority: $(_text_range_string(s, authority_range))"))
        host_range = _text_range(nextind(s, authority_range.first), prevind(s, close_idx))
        if close_idx < authority_range.last
            # Only `:port` may follow an IPv6 literal.
            @inbounds(bytes[close_idx + 1] == UInt8(':')) || throw(ArgumentError("invalid IPv6 host authority: $(_text_range_string(s, authority_range))"))
            port_first = close_idx + 2
        end
    else
        colon_idx = _find_last_url_byte(bytes, authority_range.first, authority_range.last, UInt8(':'))
        if colon_idx !== nothing
            host_range = _text_range(authority_range.first, prevind(s, colon_idx))
            port_first = colon_idx + 1
        end
    end
    has_explicit_port = port_first != 0
    has_explicit_port && _check_url_port(SubString(s, port_first, authority_range.last))
    # RFC 9110 §4.2.1: an http(s) URI with an empty host is invalid. Dialing
    # one (`http://:8080/`) would reach the local machine.
    _text_range_empty(host_range) && throw(ArgumentError("URL missing host: $(_url_for_message(s))"))
    _check_url_host(SubString(s, host_range.first, host_range.last), bracketed)

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
    scheme = _uri_component_present(url.scheme) ? lowercase(String(url.scheme)) : ""
    secure = if scheme == "http"
        false
    elseif scheme == "https"
        true
    elseif isempty(scheme)
        throw(ArgumentError("URL must include http:// or https:// scheme: $(_url_for_message(source))"))
    else
        throw(ArgumentError("unsupported URL scheme '$scheme'; expected http or https"))
    end

    host = _uri_component_string(url.host)
    isempty(host) && throw(ArgumentError("URL missing host: $(_url_for_message(source))"))
    # URIs keeps an IPv6 address without its brackets.
    _check_url_host(host, occursin(':', host))

    default_port = secure ? UInt16(443) : UInt16(80)
    # An absent or empty port means the scheme's default port.
    has_explicit_port = !isempty(url.port)
    has_explicit_port && _check_url_port(url.port)
    address = if has_explicit_port
        string(URIs.hoststring(host), ":", String(url.port))
    else
        HostResolvers.join_host_port(host, Int(default_port))
    end

    target = _uri_request_target(url)
    query === nothing || (target = _escape_target_spaces(_append_query(target, query)))

    has_userinfo = _uri_component_present(url.userinfo) && !isempty(url.userinfo)
    if has_userinfo
        userinfo = String(url.userinfo)
        _check_url_userinfo(codeunits(userinfo), 1, ncodeunits(userinfo))
    end
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
