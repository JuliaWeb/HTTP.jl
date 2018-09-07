# based on go implementation in src/net/http/cookie.go

# Copyright (c) 2009 The Go Authors. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#
#    * Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
#    * Redistributions in binary form must reproduce the above
# copyright notice, this list of conditions and the following disclaimer
# in the documentation and/or other materials provided with the
# distribution.
#    * Neither the name of Google Inc. nor the names of its
# contributors may be used to endorse or promote products derived from
# this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

module Cookies

export Cookie, cookies

import Base: ==
using ..Dates
using ..IOExtras: bytes
using ..Parsers: Headers
using ..Messages: Request, mkheaders, hasheader, header

import ..IPAddr

"""
    Cookie()
    Cookie(; kwargs...)
    Cookie(name, value; kwargs...)

A Cookie represents an HTTP cookie as sent in the Set-Cookie header of an
HTTP response or the Cookie header of an HTTP request. Supported fields
(which can be set using keyword arguments) include:

  * `name`: name of the cookie
  * `value`: value of the cookie
  * `path`: applicable path for the cookie
  * `domain`: applicable domain for the cookie
  * `expires`: a `Dates.DateTime` representing when the cookie should expire
  * `maxage`: `maxage == 0` means no max age, `maxage < 0` means delete cookie now, `max age > 0` means the # of seconds until expiration
  * `secure::Bool`: secure cookie attribute
  * `httponly::Bool`: httponly cookie attribute
  * `hostonly::Bool`: hostonly cookie attribute

See http:#tools.ietf.org/html/rfc6265 for details.
"""
mutable struct Cookie
    name::String
    value::String

    path::String      # optional
    domain::String    # optional
    expires::Dates.DateTime # optional

    # MaxAge=0 means no 'Max-Age' attribute specified.
    # MaxAge<0 means delete cookie now, equivalently 'Max-Age: 0'
    # MaxAge>0 means Max-Age attribute present and given in seconds
    maxage::Int
    secure::Bool
    httponly::Bool
    hostonly::Bool
    unparsed::Vector{String} # Raw text of unparsed attribute-value pairs
end

function Cookie(cookie::Cookie; kwargs...)
    for (k, v) in kwargs
        setfield!(cookie, k, convert(fieldtype(Cookie, k), v))
    end
    return cookie
end
Cookie(; kwargs...) = Cookie(Cookie("", ""); kwargs...)

Cookie(name, value; args...) = Cookie(Cookie(name, value, "", "", Dates.DateTime(1), 0, false, false, false, String[]); args...)

Base.isequal(a::Cookie, b::Cookie) = a.name == b.name && a.path == b.path && a.domain == b.domain
Base.hash(x::Cookie, h::UInt) = hash(x.name, hash(x.path, hash(x.domain, h)))

==(a::Cookie,b::Cookie) = (a.name     == b.name)    &&
                          (a.value    == b.value)   &&
                          (a.path     == b.path)    &&
                          (a.domain   == b.domain)  &&
                          (a.expires  == b.expires) &&
                          (a.maxage   == b.maxage)  &&
                          (a.secure   == b.secure)  &&
                          (a.httponly == b.httponly)

# request cookie stringify-ing
function Base.String(c::Cookie, isrequest::Bool=true)
    io = IOBuffer()
    nm = strip(c.name)
    !iscookienamevalid(nm) && return ""
    write(io, sanitizeCookieName(nm), '=', sanitizeCookieValue(c.value))
    if !isrequest
        length(c.path) > 0 && write(io, "; Path=", sanitizeCookiePath(c.path))
        length(c.domain) > 0 && validCookieDomain(c.domain) && write(io, "; Domain=", c.domain[1] == '.' ? c.domain[2:end] : c.domain)
        validCookieExpires(c.expires) && write(io, "; Expires=", Dates.format(c.expires, Dates.RFC1123Format), " GMT")
        c.maxage > 0 && write(io, "; Max-Age=", string(c.maxage))
        c.maxage < 0 && write(io, "; Max-Age=0")
        c.httponly && write(io, "; HttpOnly")
        c.secure && write(io, "; Secure")
    end
    return String(take!(io))
end

function Base.string(cookiestring::String, cookies::Vector{Cookie}, isrequest::Bool=true)
    io = IOBuffer()
    !isempty(cookiestring) && write(io, cookiestring, cookiestring[end] == ';' ? "" : ";")
    len = length(cookies)
    for (i, cookie) in enumerate(cookies)
        write(io, String(cookie, isrequest), ifelse(i == len, "", "; "))
    end
    return String(take!(io))
end

validcookiepathbyte(b) = (' ' <= b < '\x7f') && b != ';'
validcookievaluebyte(b) = (' ' <= b < '\x7f') && b != '"' && b != ';' && b != '\\'

function parsecookievalue(raw, allowdoublequote::Bool)
    if allowdoublequote && length(raw) > 1 && raw[1] == '"' && raw[end] == '"'
        raw = raw[2:end-1]
    end
    for i = 1:length(raw)
        !validcookievaluebyte(raw[i]) && return "", false
    end
    return raw, true
end

iscookienamevalid(raw) = raw == "" ? false : any(isurlchar, raw)

const AlternateRFC1123Format = Dates.DateFormat("e, dd-uuu-yyyy HH:MM:SS G\\MT")

# readSetCookies parses all "Set-Cookie" values from
# the header h and returns the successfully parsed Cookies.
readsetcookies(host, cookies) = Cookie[readsetcookie(host, c) for c in cookies]

function readsetcookie(host, cookie)
    parts = split(strip(cookie), ';')
    length(parts) == 1 && parts[1] == "" && return Cookie()
    parts[1] = strip(parts[1])
    j = findfirst(isequal('='), parts[1])
    j === nothing && return Cookie()
    name, value = parts[1][1:j-1], parts[1][j+1:end]
    iscookienamevalid(name) || return Cookie()
    value, ok = parsecookievalue(value, true)
    ok || return Cookie()
    c = Cookie(name, value)
    for x = 2:length(parts)
        parts[x] = strip(parts[x])
        length(parts[x]) == 0 && continue
        attr, val = parts[x], ""
        j = findfirst(isequal('='), parts[x])
        if j !== nothing
            attr, val = attr[1:j-1], attr[j+1:end]
        end
        lowerattr = lowercase(attr)
        val, ok = parsecookievalue(val, false)
        if !ok
            push!(c.unparsed, parts[x])
            continue
        end
        if lowerattr == "secure"
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
            try
                c.expires = Dates.DateTime(val, Dates.RFC1123Format)
            catch
                try
                    c.expires = Dates.DateTime(val, AlternateRFC1123Format)
                catch
                    continue
                end
            end
        elseif lowerattr == "path"
            c.path = val
        else
            push!(c.unparsed, parts[x])
        end
    end
    c.domain, c.hostonly = domainandtype(host == "" ? c.domain : host, c.domain)
    return c
end

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
    return length(s) > length(suffix) && s[length(s)-length(suffix)] == '.' && s[length(s)-length(suffix)+1:end] == suffix
end

# pathMatch implements "path-match" according to RFC 6265 section 5.1.4.
function pathmatch(cookie::Cookie, requestpath)
    requestpath == cookie.path && return true
    if startswith(requestpath, cookie.path)
        if cookie.path[end] == '/'
            return true # The "/any/" matches "/any/path" case.
        elseif length(requestpath) >= length(cookie.path) + 1 && requestpath[length(cookie.path)+1] == '/'
            return true # The "/any" matches "/any/path" case.
        end
    end
    return false
end

function isIP(host)
    try
        Base.parse(IPAddr, host)
        return true
    catch e
        isa(e, ArgumentError) && return false
        rethrow(e)
    end
end

# domainAndType determines the cookie's domain and hostOnly attribute.
function domainandtype(host, domain)
    if domain == ""
        # No domain attribute in the SetCookie header indicates a
        # host cookie.
        return host, true
    end

    if isIP(host)
        # According to RFC 6265 domain-matching includes not being
        # an IP address.
        # TODO: This might be relaxed as in common browsers.
        return "", false
    end

    # From here on: If the cookie is valid, it is a domain cookie (with
    # the one exception of a public suffix below).
    # See RFC 6265 section 5.2.3.
    if domain[1] == '.'
        domain = domain[2:end]
    end

    if length(domain) == 0 || domain[1] == '.'
        # Received either "Domain=." or "Domain=..some.thing",
        # both are illegal.
        return "", false
    end
    domain = lowercase(domain)

    if domain[end] == '.'
        # We received stuff like "Domain=www.example.com.".
        # Browsers do handle such stuff (actually differently) but
        # RFC 6265 seems to be clear here (e.g. section 4.1.2.3) in
        # requiring a reject.  4.1.2.3 is not normative, but
        # "Domain Matching" (5.1.3) and "Canonicalized Host Names"
        # (5.1.2) are.
        return "", false
    end

    #TODO:
    # See RFC 6265 section 5.3 #5.
    # if j.psList != nil
    #     if ps := j.psList.PublicSuffix(domain); ps != "" && !hasDotSuffix(domain, ps)
    #         if host == domain
    #             # This is the one exception in which a cookie
    #             # with a domain attribute is a host cookie.
    #             return host, true, nil
    #         end
    #         return "", false
    #     end
    # end

    # The domain must domain-match host: www.mycompany.com cannot
    # set cookies for .ourcompetitors.com.
    if host != domain && !hasdotsuffix(host, domain)
        return "", false
    end

    return domain, false
end

cookies(r::Request) = readcookies(r.headers, "")

# readCookies parses all "Cookie" values from the header h and
# returns the successfully parsed Cookies.
# if filter isn't empty, only cookies of that name are returned
function readcookies(h::Headers, filter::String)

    result = Cookie[]

    for part in split(header(h, "Cookie", ""), ';')
        part = strip(part)
        length(part) <= 1 && continue
        j = findfirst(isequal('='), part)
        if j !== nothing
            name, val = part[1:j-1], part[j+1:end]
        else
            name, val = part, ""
        end
        !iscookienamevalid(name) && continue
        filter != "" && filter != name && continue
        val, ok = parsecookievalue(val, true)
        !ok && continue
        push!(result, Cookie(name, val))
    end
    return result
end

readcookies(h, f) = readcookies(mkheaders(h), f)


# validCookieExpires returns whether v is a valid cookie expires-value.
function validCookieExpires(dt)
    # IETF RFC 6265 Section 5.1.1.5, the year must not be less than 1601
    return Dates.year(dt) >= 1601
end

# validCookieDomain returns whether v is a valid cookie domain-value.
function validCookieDomain(v::String)
    isCookieDomainName(v) && return true
    isIP(v) && !occursin(":", v) && return true
    return false
end

# isCookieDomainName returns whether s is a valid domain name or a valid
# domain name with a leading dot '.'.  It is almost a direct copy of
# package net's isDomainName.
function isCookieDomainName(s::String)
    length(s) == 0 && return false
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

sanitizeCookieName(n::String) = replace(replace(n, '\n'=>'-'), '\r'=>'-')
sanitizeCookieName(n) = sanitizeCookieName(String(n))

# http:#tools.ietf.org/html/rfc6265#section-4.1.1
# cookie-value      = *cookie-octet / ( DQUOTE *cookie-octet DQUOTE )
# cookie-octet      = %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E
#           ; US-ASCII characters excluding CTLs,
#           ; whitespace DQUOTE, comma, semicolon,
#           ; and backslash
# We loosen this as spaces and commas are common in cookie values
# but we produce a quoted cookie-value in when value starts or ends
# with a comma or space.
# See https:#golang.org/issue/7243 for the discussion.
function sanitizeCookieValue(v::String)
    v = String(filter(validcookievaluebyte, [Char(b) for b in bytes(v)]))
    length(v) == 0 && return v
    if v[1] == ' ' || v[1] == ',' || v[end] == ' ' || v[end] == ','
        return string('"', v, '"')
    end
    return v
end

sanitizeCookiePath(v) = filter(validcookiepathbyte, v)

const normal_url_char = Bool[
#=   0 nul    1 soh    2 stx    3 etx    4 eot    5 enq    6 ack    7 bel  =#
        false,   false,   false,   false,   false,   false,   false,   false,
#=   8 bs     9 ht    10 nl    11 vt    12 np    13 cr    14 so    15 si   =#
        false,   true,   false,   false,   true,   false,   false,   false,
#=  16 dle   17 dc1   18 dc2   19 dc3   20 dc4   21 nak   22 syn   23 etb =#
        false,   false,   false,   false,   false,   false,   false,   false,
#=  24 can   25 em    26 sub   27 esc   28 fs    29 gs    30 rs    31 us  =#
        false,   false,   false,   false,   false,   false,   false,   false,
#=  32 sp    33  !    34  "    35  #    36  $    37  %    38  &    39  '  =#
        false,   true,   true,   false,   true,   true,   true,  true,
#=  40  (    41  )    42  *    43  +    44  ,    45  -    46  .    47  /  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#=  48  0    49  1    50  2    51  3    52  4    53  5    54  6    55  7  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#=  56  8    57  9    58  :    59  ;    60  <    61  =    62  >    63  ?  =#
        true,   true,   true,   true,   true,   true,   true,   false,
#=  64  @    65  A    66  B    67  C    68  D    69  E    70  F    71  G  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#=  72  H    73  I    74  J    75  K    76  L    77  M    78  N    79  O  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#=  80  P    81  Q    82  R    83  S    84  T    85  U    86  V    87  W  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#=  88  X    89  Y    90  Z    91  [    92  \    93  ]    94  ^    95  _  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#=  96  `    97  a    98  b    99  c   100  d   101  e   102  f   103  g  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#= 104  h   105  i   106  j   107  k   108  l   109  m   110  n   111  o  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#= 112  p   113  q   114  r   115  s   116  t   117  u   118  v   119  w  =#
        true,   true,   true,   true,   true,   true,   true,  true,
#= 120  x   121  y   122  z   123  {   124,   125  }   126  ~   127 del =#
        true,   true,   true,   true,   true,   true,   true,   false,
]

@inline isurlchar(c) =  c > '\u80' ? true : normal_url_char[Int(c) + 1]

end # module
