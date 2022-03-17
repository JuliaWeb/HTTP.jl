module CookieRequest

import ..Dates
using URIs
using ..Cookies
using ..Messages: Request, ascii_lc_isequal
using ..Pairs: getkv, setkv
import ..@debug, ..DEBUG_LEVEL, ..access_threaded

const default_cookiejar = Dict{String, Set{Cookie}}[]

function __init__()
    resize!(empty!(default_cookiejar), Threads.nthreads())
    return
end

export cookielayer

"""
    cookielayer(ctx, method, ::URI, headers, body) -> HTTP.Response

Add locally stored Cookies to the request headers.
Store new Cookies found in the response headers.
"""
function cookielayer(handler)
    return function(ctx, req::Request; cookies=true, cookiejar::Dict{String, Set{Cookie}}=access_threaded(Dict{String, Set{Cookie}}, default_cookiejar), kw...)
        println("cookielayer")
        if cookies === true || (cookies isa AbstractDict && !isempty(cookies))
            url = req.url
            hostcookies = get!(cookiejar, url.host, Set{Cookie}())
            cookiestosend = getcookies(hostcookies, url)
            if !(cookies isa Bool)
                for (name, value) in cookies
                    push!(cookiestosend, Cookie(name, value))
                end
            end
            if !isempty(cookiestosend)
                setkv(req.headers, "Cookie", stringify(getkv(req.headers, "Cookie", ""), cookiestosend))
            end
            @show cookiestosend
            res = handler(ctx, req; kw...)
            setcookies(hostcookies, url.host, res.headers)
            @show hostcookies
            return res
        else
            # skip
            return handler(ctx, req; kw...)
        end
    end
end

function getcookies(cookies, url)

    tosend = Vector{Cookie}()
    expired = Vector{Cookie}()

    # Check if cookies should be added to outgoing request based on host...
    for cookie in cookies
        if Cookies.shouldsend(cookie, url.scheme == "https",
                              url.host, url.path)
            t = cookie.expires
            if t != Dates.DateTime(1) && t < Dates.now(Dates.UTC)
                @debug 1 "Deleting expired Cookie: $cookie.name"
                push!(expired, cookie)
            else
                @debug 1 "Sending Cookie: $cookie.name to $url.host"
                push!(tosend, cookie)
            end
        end
    end
    setdiff!(cookies, expired)
    return tosend
end

function setcookies(cookies, host, headers)
    for (k, v) in headers
        ascii_lc_isequal(k, "set-cookie") || continue
        @debug 1 "Set-Cookie: $v (from $host)"
        push!(cookies, Cookies.readsetcookie(host, v))
    end
end

end # module CookieRequest
