export Cookie
export CookieJar
export cookies
export stringify
export getcookies!
export setcookies!
export addcookie!

module Cookies

using Dates

import Base: ==, copy, empty!, hash, isequal
import ..Headers
import ..Request
import ..Response
import ..appendheader
import ..headers
import .._valid_header_field_name

include("http_public_suffix_data.jl")

@enum SameSite SameSiteDefaultMode = 1 SameSiteLaxMode SameSiteStrictMode SameSiteNoneMode

"""
    Cookie

HTTP cookie model used for both request `Cookie` headers and response
`Set-Cookie` headers.

Construct a cookie with `Cookie(name, value; kwargs...)` and mutate additional
fields such as `path`, `domain`, `secure`, or `httponly` when needed.
"""
mutable struct Cookie
    name::String
    value::String
    path::String
    domain::String
    expires::Dates.DateTime
    rawexpires::String
    creation::Dates.DateTime
    lastaccess::Dates.DateTime
    maxage::Int
    secure::Bool
    httponly::Bool
    persistent::Bool
    hostonly::Bool
    samesite::SameSite
    raw::String
    unparsed::Vector{String}
end

function Cookie(cookie::Cookie; kwargs...)
    for (k, v) in kwargs
        if k === :samesite && v isa Symbol
            setfield!(cookie, k, _samesite_from_symbol(v))
        else
            setfield!(cookie, k, convert(fieldtype(Cookie, k), v))
        end
    end
    return cookie
end

function _samesite_from_symbol(s::Symbol)::SameSite
    s === :strict && return SameSiteStrictMode
    s === :lax && return SameSiteLaxMode
    s === :none && return SameSiteNoneMode
    s === :default && return SameSiteDefaultMode
    throw(ArgumentError("invalid samesite symbol $(repr(s)); expected :strict, :lax, :none, or :default"))
end

Cookie(; kwargs...) = Cookie(Cookie("", "", ""); kwargs...)

function Cookie(name, value, raw=""; args...)
    return Cookie(Cookie(
            String(name),
            String(value),
            "",
            "",
            Dates.DateTime(1),
            "",
            Dates.DateTime(1),
            Dates.DateTime(1),
            0,
            false,
            false,
            false,
            false,
            SameSiteDefaultMode,
            String(raw),
            String[],
        ); args...)
end

Base.isequal(a::Cookie, b::Cookie) = a.name == b.name && a.path == b.path && a.domain == b.domain
Base.hash(x::Cookie, h::UInt) = hash(x.name, hash(x.path, hash(x.domain, h)))
id(c::Cookie) = "$(c.domain);$(c.path);$(c.name)"

==(a::Cookie, b::Cookie) = (a.name == b.name) &&
                           (a.value == b.value) &&
                           (a.path == b.path) &&
                           (a.domain == b.domain) &&
                           (a.expires == b.expires) &&
                           (a.creation == b.creation) &&
                           (a.lastaccess == b.lastaccess) &&
                           (a.maxage == b.maxage) &&
                           (a.secure == b.secure) &&
                           (a.httponly == b.httponly) &&
                           (a.persistent == b.persistent) &&
                           (a.hostonly == b.hostonly) &&
                           (a.samesite == b.samesite)

"""
    stringify(cookie, isrequest=true) -> String
    stringify(prefix, cookies, isrequest=true) -> String

Serialize cookies back to HTTP header text.

When `isrequest=true`, the output matches a request `Cookie` header. When
`false`, response-only attributes such as `Path`, `Domain`, and `HttpOnly` are
included for `Set-Cookie` serialization.
"""
function stringify(c::Cookie, isrequest::Bool=true)::String
    nm = strip(c.name)
    !iscookienamevalid(nm) && return ""
    io = IOBuffer()
    write(io, sanitizeCookieName(nm), '=', sanitizeCookieValue(c.value))
    if !isrequest
        length(c.path) > 0 && write(io, "; Path=", sanitizeCookiePath(c.path))
        length(c.domain) > 0 && validCookieDomain(c.domain) && write(io, "; Domain=", c.domain[1] == '.' ? SubString(c.domain, 2) : c.domain)
        validCookieExpires(c.expires) && write(io, "; Expires=", Dates.format(c.expires, Dates.RFC1123Format), " GMT")
        c.maxage > 0 && write(io, "; Max-Age=", string(c.maxage))
        c.maxage < 0 && write(io, "; Max-Age=0")
        c.httponly && write(io, "; HttpOnly")
        c.secure && write(io, "; Secure")
        if c.samesite == SameSiteLaxMode
            write(io, "; SameSite=Lax")
        elseif c.samesite == SameSiteStrictMode
            write(io, "; SameSite=Strict")
        elseif c.samesite == SameSiteNoneMode
            write(io, "; SameSite=None")
        end
    end
    return String(take!(io))
end

function stringify(cookiestring::AbstractString, cookies::Vector{Cookie}, isrequest::Bool=true)::String
    io = IOBuffer()
    if !isempty(cookiestring)
        write(io, cookiestring)
        if !isempty(cookies)
            if endswith(rstrip(cookiestring, [' ']), ";")
                cookiestring[end] == ';' && write(io, ' ')
            else
                write(io, "; ")
            end
        end
    end
    len = length(cookies)
    for (i, cookie) in enumerate(cookies)
        write(io, stringify(cookie, isrequest), i == len ? "" : "; ")
    end
    return String(take!(io))
end

"""
    addcookie!(message, cookie) -> typeof(message)

Append `cookie` to a request or response message in the appropriate header
slot.
"""
function addcookie! end

function addcookie!(r::Request, c::Cookie)
    appendheader(r.headers, "Cookie", stringify(c))
    return r
end

function addcookie!(r::Response, c::Cookie)
    appendheader(r.headers, "Set-Cookie", stringify(c, false))
    return r
end

validcookiepathbyte(b) = (' ' <= b < '\x7f') && b != ';'
validcookievaluebyte(b) = (' ' <= b < '\x7f') && b != '"' && b != ';' && b != '\\'

function parsecookievalue(raw, allowdoublequote::Bool)
    if allowdoublequote && length(raw) > 1 && raw[1] == '"' && raw[end] == '"'
        raw = raw[2:(end-1)]
    end
    for i in eachindex(raw)
        !validcookievaluebyte(raw[i]) && return "", false
    end
    return raw, true
end

iscookienamevalid(raw) = _valid_header_field_name(raw)

gmtformat(::DateFormat{S,T}) where {S,T} = Dates.DateFormat(string(S, " G\\MT"))
const AlternateRFC1123GMTFormat = gmtformat(dateformat"e, dd-uuu-yyyy HH:MM:SS")
const RFC1123GMTFormat = gmtformat(Dates.RFC1123Format)
const _HTTP_GMT_DATE_RE = r"^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun),[ \t]+(\d{1,2})[- ]([A-Za-z]{3})[- ](\d{4})[ \t]+(\d{2}):(\d{2}):(\d{2})[ \t]+GMT$"

@inline function _ascii_lower_byte(b::UInt8)::UInt8
    0x41 <= b <= 0x5a || return b
    return b + 0x20
end

@inline function _find_last_ascii_delim(s::String, delim::UInt8)::Int
    bytes = codeunits(s)
    for i in length(bytes):-1:1
        @inbounds bytes[i] == delim && return i
    end
    return 0
end

@inline function _http_month_number(mon::AbstractString)::Int
    bytes = codeunits(mon)
    length(bytes) == 3 || return 0
    b1 = _ascii_lower_byte(@inbounds bytes[1])
    b2 = _ascii_lower_byte(@inbounds bytes[2])
    b3 = _ascii_lower_byte(@inbounds bytes[3])
    b1 == 0x6a && b2 == 0x61 && b3 == 0x6e && return 1
    b1 == 0x66 && b2 == 0x65 && b3 == 0x62 && return 2
    b1 == 0x6d && b2 == 0x61 && b3 == 0x72 && return 3
    b1 == 0x61 && b2 == 0x70 && b3 == 0x72 && return 4
    b1 == 0x6d && b2 == 0x61 && b3 == 0x79 && return 5
    b1 == 0x6a && b2 == 0x75 && b3 == 0x6e && return 6
    b1 == 0x6a && b2 == 0x75 && b3 == 0x6c && return 7
    b1 == 0x61 && b2 == 0x75 && b3 == 0x67 && return 8
    b1 == 0x73 && b2 == 0x65 && b3 == 0x70 && return 9
    b1 == 0x6f && b2 == 0x63 && b3 == 0x74 && return 10
    b1 == 0x6e && b2 == 0x6f && b3 == 0x76 && return 11
    b1 == 0x64 && b2 == 0x65 && b3 == 0x63 && return 12
    return 0
end

function _parse_http_gmt_datetime(value::AbstractString)::Union{Nothing,Dates.DateTime}
    m = match(_HTTP_GMT_DATE_RE, value)
    m === nothing && return nothing
    captures = m.captures
    day_capture = captures[1]
    day_capture === nothing && return nothing
    day = tryparse(Int, day_capture)
    day === nothing && return nothing
    month_capture = captures[2]
    month_capture === nothing && return nothing
    month = _http_month_number(month_capture)
    month == 0 && return nothing
    year_capture = captures[3]
    year_capture === nothing && return nothing
    year = tryparse(Int, year_capture)
    year === nothing && return nothing
    hour_capture = captures[4]
    hour_capture === nothing && return nothing
    hour = tryparse(Int, hour_capture)
    hour === nothing && return nothing
    minute_capture = captures[5]
    minute_capture === nothing && return nothing
    minute = tryparse(Int, minute_capture)
    minute === nothing && return nothing
    second_capture = captures[6]
    second_capture === nothing && return nothing
    second = tryparse(Int, second_capture)
    second === nothing && return nothing
    try
        return Dates.DateTime(year, month, day, hour, minute, second)
    catch
        return nothing
    end
end

function readsetcookies(hdrs::Headers)::Vector{Cookie}
    result = Cookie[]
    for line in headers(hdrs, "Set-Cookie")
        isempty(line) && continue
        parts = split(strip(line), ';'; keepempty=false)
        length(parts) == 1 && parts[1] == "" && continue
        part = strip(parts[1])
        j = findfirst(isequal('='), part)
        if j !== nothing
            name, val = SubString(part, 1:(j-1)), SubString(part, j + 1)
        else
            name, val = part, ""
        end
        !iscookienamevalid(name) && continue
        val, ok = parsecookievalue(val, true)
        !ok && continue
        c = Cookie(name, val, line)
        for i in 2:length(parts)
            part = strip(parts[i])
            isempty(part) && continue
            j = findfirst(isequal('='), part)
            if j !== nothing
                attr, val = SubString(part, 1:(j-1)), SubString(part, j + 1)
            else
                attr, val = part, ""
            end
            !isascii(attr) && continue
            lowerattr = lowercase(attr)
            val, ok = parsecookievalue(val, false)
            if !ok
                push!(c.unparsed, part)
                continue
            end
            if lowerattr == "samesite"
                if !isascii(val)
                    c.samesite = SameSiteDefaultMode
                    continue
                end
                val = lowercase(val)
                if val == "lax"
                    c.samesite = SameSiteLaxMode
                elseif val == "strict"
                    c.samesite = SameSiteStrictMode
                elseif val == "none"
                    c.samesite = SameSiteNoneMode
                else
                    c.samesite = SameSiteDefaultMode
                end
            elseif lowerattr == "secure"
                c.secure = true
            elseif lowerattr == "httponly"
                c.httponly = true
            elseif lowerattr == "domain"
                c.domain = val
            elseif lowerattr == "max-age"
                try
                    secs = parse(Int, val)
                    val[1] == '0' && continue
                    c.maxage = max(secs, -1)
                catch
                    continue
                end
            elseif lowerattr == "expires"
                c.rawexpires = val
                parsed = _parse_http_gmt_datetime(val)
                parsed === nothing && continue
                c.expires = parsed
            elseif lowerattr == "path"
                c.path = val
            else
                push!(c.unparsed, parts[i])
            end
        end
        push!(result, c)
    end
    return result
end

function isIP(host::AbstractString)::Bool
    parts = split(host, '.'; keepempty=false)
    length(parts) == 4 || return false
    for p in parts
        isempty(p) && return false
        all(isdigit, p) || return false
        v = tryparse(Int, p)
        v === nothing && return false
        (0 <= v <= 255) || return false
    end
    return true
end

"""
    cookies(request_or_response) -> Vector{Cookie}

Parse cookies from a request `Cookie` header or response `Set-Cookie` headers.
"""
function cookies end

cookies(r::Response) = readsetcookies(r.headers)
cookies(r::Request) = readcookies(r.headers, "")

function readcookies(hdrs::Headers, filter::String="")::Vector{Cookie}
    result = Cookie[]
    for line in headers(hdrs, "Cookie")
        for part in split(strip(line), ';'; keepempty=false)
            part = strip(part)
            length(part) <= 1 && continue
            j = findfirst(isequal('='), part)
            if j !== nothing
                name, val = part[1:(j-1)], part[(j+1):end]
            else
                name, val = part, ""
            end
            !iscookienamevalid(name) && continue
            filter != "" && filter != name && continue
            val, ok = parsecookievalue(val, true)
            !ok && continue
            push!(result, Cookie(name, val, line))
        end
    end
    return result
end

function validCookieExpires(dt)
    return Dates.year(dt) >= 1601
end

function validCookieDomain(v::String)::Bool
    isCookieDomainName(v) && return true
    isIP(v) && !occursin(":", v) && return true
    return false
end

function isCookieDomainName(s::String)::Bool
    isempty(s) && return false
    length(s) > 255 && return false
    s = s[1] == '.' ? s[2:end] : s
    last = '.'
    ok = false
    partlen = 0
    for c in s
        if 'a' <= c <= 'z' || 'A' <= c <= 'Z'
            ok = true
            partlen += 1
        elseif '0' <= c <= '9'
            partlen += 1
        elseif c == '-'
            last == '.' && return false
            partlen += 1
        elseif c == '.'
            (last == '.' || last == '-') && return false
            (partlen > 63 || partlen == 0) && return false
            partlen = 0
        else
            return false
        end
        last = c
    end
    (last == '-' || partlen > 63) && return false
    return ok
end

sanitizeCookieName(n::String) = replace(replace(n, '\n' => '-'), '\r' => '-')
sanitizeCookieName(n) = sanitizeCookieName(String(n))

function sanitizeCookieValue(v::String)::String
    v = String(filter(validcookievaluebyte, [c for c in v]))
    isempty(v) && return v
    if contains(v, ' ') || contains(v, ',')
        return string('"', v, '"')
    end
    return v
end

sanitizeCookiePath(v) = filter(validcookiepathbyte, v)

const normal_url_char = Bool[
    false, false, false, false, false, false, false, false,  # 0-7
    false, true, false, false, true, false, false, false,    # 8-15
    false, false, false, false, false, false, false, false,  # 16-23
    false, false, false, false, false, false, false, false,  # 24-31
    false, true, true, false, true, true, true, true,        # 32-39: space ! " # $ % & '
    true, true, true, true, true, true, true, true,          # 40-47: ( ) * + , - . /
    true, true, true, true, true, true, true, true,          # 48-55: 0-7
    true, true, true, true, true, true, true, false,         # 56-63: 8 9 : ; < = > ?
    true, true, true, true, true, true, true, true,          # 64-71: @ A B C D E F G
    true, true, true, true, true, true, true, true,          # 72-79: H I J K L M N O
    true, true, true, true, true, true, true, true,          # 80-87: P Q R S T U V W
    true, true, true, true, true, true, true, true,          # 88-95: X Y Z [ \ ] ^ _
    true, true, true, true, true, true, true, true,          # 96-103: ` a b c d e f g
    true, true, true, true, true, true, true, true,          # 104-111: h i j k l m n o
    true, true, true, true, true, true, true, true,          # 112-119: p q r s t u v w
    true, true, true, true, true, true, true, false,         # 120-127: x y z { | } ~ DEL
]

@inline isurlchar(c) = c ≥ '\u80' ? true : normal_url_char[Int(c)+1]

"""
    CookieJar()
    CookieJar(entries::Dict{String, Dict{String, Cookie}})

Create an in-memory cookie jar suitable for attaching to `Client`.

The jar applies standard domain/path/expiry rules when storing cookies from
responses and when selecting cookies for future requests.

Pass `entries` to start from previously saved cookies: `jar.entries` is the
jar's storage (keyed by canonical host), so persisting a jar amounts to saving
`jar.entries` and restoring it is `CookieJar(entries)`. The jar takes ownership
of the passed dict; it is not copied.
"""
struct CookieJar
    lock::ReentrantLock
    entries::Dict{String,Dict{String,Cookie}}
end

CookieJar() = CookieJar(ReentrantLock(), Dict{String,Dict{String,Cookie}}())
CookieJar(entries::Dict{String,Dict{String,Cookie}}) = CookieJar(ReentrantLock(), entries)
Base.empty!(c::CookieJar) = lock(() -> empty!(c.entries), c.lock)

function shouldsend(cookie::Cookie, https::Bool, host, path)::Bool
    return domainmatch(cookie, host) && pathmatch(cookie, path) && (https || !cookie.secure)
end

function domainmatch(cookie::Cookie, host)::Bool
    cookie.domain == host && return true
    return !cookie.hostonly && hasdotsuffix(host, cookie.domain)
end

function hasdotsuffix(s, suffix)::Bool
    return length(s) > length(suffix) && s[length(s)-length(suffix)] == '.' && s[(length(s)-length(suffix)+1):end] == suffix
end

function _public_suffix_label_count(domain::String)::Int
    labels = split(domain, '.'; keepempty=false)
    n = length(labels)
    n == 0 && return 0
    best = 1 # Default "*" rule.
    for i in 1:n
        candidate = join(@view(labels[i:n]), ".")
        candidate_count = n - i + 1
        if candidate in _PUBLIC_SUFFIX_EXCEPTION_RULES
            return max(candidate_count - 1, 0)
        end
        if candidate in _PUBLIC_SUFFIX_EXACT_RULES
            best = max(best, candidate_count)
        end
        if i < n
            wildcard_suffix = join(@view(labels[(i + 1):n]), ".")
            if wildcard_suffix in _PUBLIC_SUFFIX_WILDCARD_RULES
                best = max(best, candidate_count)
            end
        end
    end
    return best
end

function ispublicsuffix(domain::String)::Bool
    isempty(domain) && return false
    isIP(domain) && return false
    labels = split(domain, '.'; keepempty=false)
    return length(labels) == _public_suffix_label_count(domain)
end

function pathmatch(cookie::Cookie, requestpath)::Bool
    requestpath == cookie.path && return true
    if startswith(requestpath, cookie.path)
        if !isempty(cookie.path) && cookie.path[end] == '/'
            return true
        elseif length(requestpath) >= length(cookie.path) + 1 && requestpath[length(cookie.path)+1] == '/'
            return true
        end
    end
    return false
end

"""
    getcookies!(jar, scheme, host, path[, now]) -> Vector{Cookie}

Return the cookies from `jar` that should be attached to a request for
`scheme://host/path`.
"""
function getcookies!(jar::CookieJar, scheme::String, host::String, path::String, now::DateTime=Dates.now(Dates.UTC))::Vector{Cookie}
    cookies = Cookie[]
    if scheme != "http" && scheme != "https"
        return cookies
    end
    host = canonicalhost(host)
    host == "" && return cookies
    key = jarKey(host)
    Base.@lock jar.lock begin
        !haskey(jar.entries, key) && return cookies
        entries = jar.entries[key]
        https = scheme == "https"
        path == "" && (path = "/")
        expired = Cookie[]
        for (_, e) in entries
            if e.persistent && e.expires != DateTime(1) && e.expires < now
                push!(expired, e)
                continue
            end
            shouldsend(e, https, host, path) || continue
            e.lastaccess = now
            push!(cookies, e)
        end
        for c in expired
            delete!(entries, id(c))
        end
    end
    sort!(cookies; lt=(x, y) -> begin
        if length(x.path) != length(y.path)
            return length(x.path) > length(y.path)
        end
        if x.creation != y.creation
            return x.creation < y.creation
        end
        return x.name < y.name
    end)
    return cookies
end

# ASCII case-insensitive prefix test. Used for the RFC 6265bis cookie-name
# prefixes ("__Secure-"/"__Host-"), whose match is defined to be
# case-insensitive (§4.1.3.1/§4.1.3.2). `prefix` must be supplied lowercase.
function has_prefix(name::AbstractString, prefix::AbstractString)
    ncodeunits(name) >= ncodeunits(prefix) || return false
    for i in 1:ncodeunits(prefix)
        a = codeunit(name, i)
        # Lowercase ASCII A-Z so the comparison is case-insensitive.
        ('A' % UInt8) <= a <= ('Z' % UInt8) && (a += 0x20)
        a == codeunit(prefix, i) || return false
    end
    return true
end

"""
    setcookies!(jar, scheme, host, path, headers) -> Nothing

Update `jar` from response headers received for `scheme://host/path`.
"""
function setcookies!(jar::CookieJar, scheme::String, host::String, path::String, headers::Headers)
    cookies = readsetcookies(headers)
    isempty(cookies) && return nothing
    if scheme != "http" && scheme != "https"
        return nothing
    end
    host = canonicalhost(host)
    host == "" && return nothing
    key = jarKey(host)
    def_path = defaultPath(path)
    now = Dates.now(Dates.UTC)
    # Whether the response was delivered over a secure transport. The store path
    # must mirror the read path (shouldsend), which already withholds Secure
    # cookies from non-secure requests, so that a plaintext origin cannot plant
    # or evict Secure cookies (RFC 6265bis §5.5/§5.6).
    secure_origin = scheme == "https"
    Base.@lock jar.lock begin
        entries = get!(() -> Dict{String,Cookie}(), jar.entries, key)
        for c in cookies
            # RFC 6265bis §5.6: ignore a Set-Cookie with the Secure attribute
            # received over a non-secure ("http") scheme. Without this an on-path
            # attacker on a plaintext hop could fixate a Secure cookie that the
            # client would then replay over https.
            if c.secure && !secure_origin
                continue
            end
            # RFC 6265bis §5.4 (cookie name prefixes / §4.1.3): enforce the
            # "__Secure-" and "__Host-" name prefixes at storage time. The raw
            # Domain attribute is still available as `c.domain` here (empty means
            # no Domain attribute was sent) and `c.path` still holds the raw Path
            # attribute (normalization happens below), so the checks must run
            # before any mutation. Per RFC 6265bis §4.1.3.1/§4.1.3.2 the prefix
            # match is ASCII case-insensitive (`has_prefix`), so case variants
            # such as "__host-" cannot evade the rules.
            if has_prefix(c.name, "__secure-")
                # "__Secure-" requires the Secure attribute and a secure origin.
                (c.secure && secure_origin) || continue
            elseif has_prefix(c.name, "__host-")
                # "__Host-" requires Secure, a secure origin, Path exactly "/",
                # and NO Domain attribute (host-only).
                (c.secure && secure_origin && c.path == "/" && c.domain == "") || continue
            end
            if c.path == "" || c.path[1] != '/'
                c.path = def_path
            end
            domainAndType!(jar, c, host) || continue
            cid = id(c)
            # RFC 6265bis §5.6: a cookie arriving over a non-secure scheme must
            # not overwrite or delete an existing stored cookie that carries the
            # Secure attribute. This prevents a plaintext-origin Set-Cookie (e.g.
            # injected by an on-path attacker, including via Max-Age=-1) from
            # clobbering a Secure cookie previously set over https. The check
            # uses the same domain;path;name identity (`cid`) as storage below.
            if !secure_origin
                old = get(entries, cid, nothing)
                if old !== nothing && old.secure
                    continue
                end
            end
            if c.maxage < 0
                delete!(entries, cid)
                continue
            elseif c.maxage > 0
                c.expires = now + Dates.Second(c.maxage)
                c.persistent = true
            else
                if c.expires == DateTime(1)
                    c.expires = endOfTime
                    c.persistent = false
                else
                    if c.expires < now
                        delete!(entries, cid)
                        continue
                    end
                    c.persistent = true
                end
            end
            if haskey(entries, cid)
                old = entries[cid]
                c.creation = old.creation
            else
                c.creation = now
            end
            c.lastaccess = now
            entries[cid] = c
        end
    end
    return nothing
end

function canonicalhost(host)
    isempty(host) && return ""
    if hasport(host)
        host, _, err = splithostport(host)
        err && return ""
    end
    host[end] == '.' && (host = chop(host))
    return isascii(host) ? lowercase(host) : ""
end

function hasport(host)
    colons = count(":", host)
    colons == 0 && return false
    colons == 1 && return true
    return host[1] == '[' && contains(host, "]:")
end

function defaultPath(path)
    if isempty(path) || path[1] != '/'
        return "/"
    end
    i = _find_last_ascii_delim(path, UInt8('/'))
    if i == 0 || i == 1
        return "/"
    end
    return path[1:(i-1)]
end

const endOfTime = DateTime(9999, 12, 31, 23, 59, 59, 0)

function jarKey(host::String)::String
    isIP(host) && return host
    parts = split(host, '.'; keepempty=false)
    length(parts) >= 2 || return host
    return string(parts[end-1], ".", parts[end])
end

function domainAndType!(jar::CookieJar, c::Cookie, host::String)
    _ = jar
    domain = c.domain
    if domain == ""
        c.domain = host
        c.hostonly = true
        return true
    end
    if isIP(host)
        if host != domain
            c.domain = ""
            c.hostonly = false
            return false
        end
        c.domain = host
        c.hostonly = true
        return true
    end
    if domain[1] == '.'
        domain = chop(domain; head=1, tail=0)
    end
    if length(domain) == 0 || domain[1] == '.'
        c.domain = ""
        c.hostonly = false
        return false
    end
    if !isascii(domain)
        c.domain = ""
        c.hostonly = false
        return false
    end
    domain = lowercase(domain)
    if domain[end] == '.'
        c.domain = ""
        c.hostonly = false
        return false
    end
    if host != domain && !hasdotsuffix(host, domain)
        c.domain = ""
        c.hostonly = false
        return false
    end
    if ispublicsuffix(domain)
        c.domain = ""
        c.hostonly = false
        return false
    end
    c.domain = domain
    c.hostonly = false
    return true
end

function splithostport(hostport)
    j = k = 1
    i = _find_last_ascii_delim(hostport, UInt8(':'))
    i == 0 && return "", "", true
    if hostport[1] == '['
        z = findfirst(']', hostport)
        z === nothing && return "", "", true
        z == length(hostport) && return "", "", true
        if (z + 1) != i
            return "", "", true
        end
        host = SubString(hostport, 2:(z-1))
        j = 2
        k = z + 1
    else
        host = SubString(hostport, 1:(i-1))
    end
    if occursin(":", host)
        return "", "", true
    end
    colon_pos = findfirst(':', hostport)
    if colon_pos !== i
        return "", "", true
    end
    if j < i && hostport[j] == '['
        return "", "", true
    end
    if k + 1 > length(hostport)
        return "", "", true
    end
    port = SubString(hostport, i + 1)
    return host, port, false
end

end

using .Cookies: Cookie, CookieJar, cookies, stringify, getcookies!, setcookies!, addcookie!,
    SameSite, SameSiteDefaultMode, SameSiteLaxMode, SameSiteStrictMode, SameSiteNoneMode
