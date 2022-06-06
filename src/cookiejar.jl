"""
    CookieJar()

A thread-safe object for storing cookies returned in "Set-Cookie"
response headers. Keyed by appropriate host from the original request made.
Can be created manually and passed like `HTTP.get(url; cookiejar=mycookiejar)`
to avoid using the default global `CookieJar`. The 2 main functions for
interacting with a `CookieJar` are [`Cookies.getcookies!`](@ref), which
returns a `Vector{Cookie}` for a given url (and will remove expired cookies
from the jar), and [`Cookies.setcookies!`](@ref), which will store "Set-Cookie"
response headers in the cookie jar.
"""
struct CookieJar
    lock::ReentrantLock
    # map of host to cookies mapped by id(::Cookie)
    entries::Dict{String, Dict{String, Cookie}}
end

CookieJar() = CookieJar(ReentrantLock(), Dict{String, Dict{String, Cookie}}())
Base.empty!(c::CookieJar) = lock(() -> empty!(c.entries), c.lock)

# shouldsend determines whether e's cookie qualifies to be included in a
# request to host/path. It is the caller's responsibility to check if the
# cookie is expired.
function shouldsend(cookie::Cookie, https::Bool, host, path)
    return domainmatch(cookie, host) && pathmatch(cookie, path) && (https || !cookie.secure)
end

# domainMatch implements "domain-match" of RFC 6265 section 5.1.3.
function domainmatch(cookie::Cookie, host)
    cookie.domain == host && return true
    return !cookie.hostonly && hasdotsuffix(host, cookie.domain)
end

# hasdotsuffix reports whether s ends in "."+suffix.
function hasdotsuffix(s, suffix)
    return length(s) > length(suffix) && s[length(s)-length(suffix)] == '.' && s[(length(s)-length(suffix)+1):end] == suffix
end

# pathMatch implements "path-match" according to RFC 6265 section 5.1.4.
function pathmatch(cookie::Cookie, requestpath)
    requestpath == cookie.path && return true
    if startswith(requestpath, cookie.path)
        if length(cookie.path) > 0 && cookie.path[end] == '/'
            return true # The "/any/" matches "/any/path" case.
        elseif length(requestpath) >= length(cookie.path) + 1 && requestpath[length(cookie.path)+1] == '/'
            return true # The "/any" matches "/any/path" case.
        end
    end
    return false
end

"""
    Cookies.getcookies!(jar::CookieJar, url::URI)

Retrieve valid `Cookie`s from the `CookieJar` according to the provided `url`.
Cookies will be returned as a `Vector{Cookie}`. Only cookies for `http` or `https`
scheme in the url will be returned. Cookies will be checked according to the canonical
host of the url and any cookie max age or expiration will be accounted for. Expired
cookies will not be returned and will be removed from the cookie jar.
"""
function getcookies!(jar::CookieJar, url::URI, now::DateTime=Dates.now(Dates.UTC))::Vector{Cookie}
    cookies = Cookie[]
    if url.scheme != "http" && url.scheme != "https"
        return cookies
    end
    host = canonicalhost(url.host)
    host == "" && return cookies
    Base.@lock jar.lock begin
        !haskey(jar.entries, host) && return cookies
        entries = jar.entries[host]
        https = url.scheme == "https"
        path = url.path
        if path == ""
            path = "/"
        end
        modified = false
        expired = Cookie[]
        for (id, e) in entries
            if e.persistent && e.expires != DateTime(1) && e.expires < now
                @debugv 1 "Deleting expired cookie: $(e.name)"
                push!(expired, e)
                continue
            end
            if !shouldsend(e, https, host, path)
                continue
            end
            e.lastaccess = now
            @debugv 1 "Including cookie in request: $(e.name) to $(url.host)"
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

"""
    Cookies.setcookies!(jar::CookieJar, url::URI, headers::Headers)

Identify, "Set-Cookie" response headers from `headers`, parse the `Cookie`s,
and store valid entries in the cookie `jar` according to the canonical host
in `url`. Cookies can be retrieved from the `jar` via [`Cookies.getcookies!`](@ref).
"""
function setcookies!(jar::CookieJar, url::URI, headers::Headers)
    cookies = readsetcookies(headers)
    isempty(cookies) && return
    if url.scheme != "http" && url.scheme != "https"
        return
    end
    host = canonicalhost(url.host)
    host == "" && return
    defPath = defaultPath(url.path)
    now = Dates.now(Dates.UTC)
    Base.@lock jar.lock begin
        entries = get!(() -> Dict{String, Cookie}(), jar.entries, host)
        for c in cookies
            if c.path == "" || c.path[1] != '/'
                c.path = defPath
            end
            domainAndType!(jar, c, host) || continue
            cid = id(c)
            if c.maxage < 0
                @goto remove
            elseif c.maxage > 0
                c.expires = now + Dates.Second(c.maxage)
                c.persistent = true
            else
                if c.expires == DateTime(1)
                    c.expires = endOfTime
                    c.persistent = false
                else
                    if c.expires < now
                        @debugv 1 "Cookie expired: $(c.name)"
                        @goto remove
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
            continue
@label remove
            delete!(entries, cid)
        end
    end
    return
end

function canonicalhost(host)
    if hasport(host)
        host, _, err = splithostport(host)
        err && return ""
    end
    if host[end] == '.'
        host = chop(host)
    end
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
    i = findlast('/', path)
    if i === nothing || i == 1
        return "/"
    end
    return path[1:i]
end

const endOfTime = DateTime(9999, 12, 31, 23, 59, 59, 0)

function domainAndType!(jar::CookieJar, c::Cookie, host::String)
    domain = c.domain
    if domain == ""
        # No domain attribute in the SetCookie header indicates a
        # host cookie.
        c.domain = host
        c.hostonly = true
        return true
    end
    if isIP(host)
        # RFC 6265 is not super clear here, a sensible interpretation
        # is that cookies with an IP address in the domain-attribute
        # are allowed.

        # RFC 6265 section 5.2.3 mandates to strip an optional leading
        # dot in the domain-attribute before processing the cookie.
        #
        # Most browsers don't do that for IP addresses, only curl
        # version 7.54) and and IE (version 11) do not reject a
        #     Set-Cookie: a=1; domain=.127.0.0.1
        # This leading dot is optional and serves only as hint for
        # humans to indicate that a cookie with "domain=.bbc.co.uk"
        # would be sent to every subdomain of bbc.co.uk.
        # It just doesn't make sense on IP addresses.
        # The other processing and validation steps in RFC 6265 just
        # collaps to:
        if host != domain
            c.domain = ""
            c.hostonly = false
            return false
        end

        # According to RFC 6265 such cookies should be treated as
        # domain cookies.
        # As there are no subdomains of an IP address the treatment
        # according to RFC 6265 would be exactly the same as that of
        # a host-only cookie. Contemporary browsers (and curl) do
        # allows such cookies but treat them as host-only cookies.
        # So do we as it just doesn't make sense to label them as
        # domain cookies when there is no domain; the whole notion of
        # domain cookies requires a domain name to be well defined.
        c.domain = host
        c.hostonly = true
        return true
    end
    # From here on: If the cookie is valid, it is a domain cookie (with
    # the one exception of a public suffix below).
    # See RFC 6265 section 5.2.3.
    if domain[1] == '.'
        domain = chop(domain; head=1, tail=0)
    end

    if length(domain) == 0 || domain[1] == '.'
        # Received either "Domain=." or "Domain=..some.thing",
        # both are illegal.
        c.domain = ""
        c.hostonly = false
        return false
    end

    if !isascii(domain)
        # Received non-ASCII domain, e.g. "perché.com" instead of "xn--perch-fsa.com"
        c.domain = ""
        c.hostonly = false
        return false
    end
    domain = lowercase(domain)
    if domain[end] == '.'
        # We received stuff like "Domain=www.example.com.".
        # Browsers do handle such stuff (actually differently) but
        # RFC 6265 seems to be clear here (e.g. section 4.1.2.3) in
        # requiring a reject.  4.1.2.3 is not normative, but
        # "Domain Matching" (5.1.3) and "Canonicalized Host Names"
        # (5.1.2) are.
        c.domain = ""
        c.hostonly = false
        return false
    end
    # The domain must domain-match host: www.mycompany.com cannot
    # set cookies for .ourcompetitors.com.
    if host != domain && !hasdotsuffix(host, domain)
        c.domain = ""
        c.hostonly = false
        return false
    end
    c.domain = domain
    c.hostonly = false
    return true
end

# SplitHostPort splits a network address of the form "host:port",
# "host%zone:port", "[host]:port" or "[host%zone]:port" into host or
# host%zone and port.
#
# A literal IPv6 address in hostport must be enclosed in square
# brackets, as in "[::1]:80", "[::1%lo0]:80".
#
# See func Dial for a description of the hostport parameter, and host
# and port results.
function splithostport(hostport)
    j = k = 1

    # The port starts after the last colon.
    i = findlast(':', hostport)
    if i === nothing
        return "", "", true
    end

    if hostport[1] == '['
        # Expect the first ']' just before the last ':'.
        z = findfirst(']', hostport)
        if z === nothing
            return "", "", true
        end
        if z == length(hostport)
            return "", "", true
        elseif (z + 1) == i
            # expected
        else
            # Either ']' isn't followed by a colon, or it is
            # followed by a colon that is not the last one.
            return "", "", true
        end
        host = SubString(hostport, 2:(z-1))
        j = 2
        k = z + 1 # there can't be a '[' resp. ']' before these positions
    else
        host = SubString(hostport, 1:i-1)
        if contains(host, ":")
            return "", "", true
        end
    end
    len = length(hostport)
    if findfirst('[', SubString(hostport, j:len)) !== nothing
        return "", "", true
    end
    if findfirst(']', SubString(hostport, k:len)) !== nothing
        return "", "", true
    end

    port = SubString(hostport, (i+1):len)
    return host, port, false
end