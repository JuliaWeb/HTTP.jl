module CookieRequest

import ..Layer, ..request
using ..URIs
using ..Cookies
using ..Pairs: getkv, setkv
import ..@debug, ..DEBUG_LEVEL


const default_cookiejar = Dict{String, Set{Cookie}}()


"""
    request(CookieLayer, method, ::URI, headers, body) -> HTTP.Response

Add locally stored Cookies to the request headers.
Store new Cookies found in the response headers.
"""

abstract type CookieLayer{Next <: Layer} <: Layer end
export CookieLayer

function request(::Type{CookieLayer{Next}},
                 method::String, uri::URI, headers, body;
                 cookiejar::Dict{String, Set{Cookie}}=default_cookiejar,
                 kw...) where Next

    hostcookies = get!(cookiejar, uri.host, Set{Cookie}())

    cookies = getcookies(hostcookies, uri)
    if !isempty(cookies)
        setkv(headers, "Cookie", string(getkv(headers, "Cookie", ""), cookies))
    end

    res = request(Next, method, uri, headers, body; kw...)

    setcookies(hostcookies, uri.host, res.headers)

    return res
end


function getcookies(cookies, uri)

    tosend = Vector{Cookie}()
    expired = Vector{Cookie}()

    # Check if cookies should be added to outgoing request based on host...
    for cookie in cookies
        if Cookies.shouldsend(cookie, uri.scheme == "https",
                              uri.host, uri.path)
            t = cookie.expires
            if t != Dates.DateTime() && t < Dates.now(Dates.UTC)
                @debug 1 "Deleting expired Cookie: $cookie.name"
                push!(expired, cookie)
            else
                @debug 1 "Sending Cookie: $cookie.name to $uri.host"
                push!(tosend, cookie)
            end
        end
    end
    setdiff!(cookies, expired)
    return tosend
end


function setcookies(cookies, host, headers)
    for (k,v) in filter(x->x[1]=="Set-Cookie", headers)
        @debug 1 "Set-Cookie: $v (from $host)"
        push!(cookies, Cookies.readsetcookie(host, v))
    end
end


end # module CookieRequest
