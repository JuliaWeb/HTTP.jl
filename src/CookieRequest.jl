module CookieRequest

export request

import ..HTTP

using ..URIs
using ..Cookies
using ..Messages
using ..Pairs: getkv, setkv
using ..Strings.tocameldash!

import ..@debug, ..DEBUG_LEVEL

import ..RetryRequest


const default_cookiejar = Dict{String, Set{Cookie}}()


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


canonicalizeheaders{T}(h::T) = T([tocameldash!(k) => v for (k,v) in h])


function setbasicauthorization(headers, uri)
    if !isempty(uri.userinfo) && getkv(headers, "Authorization", "") == ""
        @debug 1 "Adding Authorization: Basic header."
        setkv(headers, "Authorization", "Basic $(base64encode(uri.userinfo))")
    end
end


function request(method::String, uri, headers=[], body="";
                 cookiejar=default_cookiejar, kw...)

    u = URI(uri)
    hostcookies = get!(cookiejar, u.host, Set{Cookie}())

    cookies = getcookies(hostcookies, u)
    if !isempty(cookies)
        setkv(headers, "Cookie", string(getkv(headers, "Cookie", ""), cookies))
    end

    if getkv(kw, :basicauthorization, false)
        setbasicauthorization(headers, uri)
    end

    try
        res = RetryRequest.request(method, uri, headers, body; kw...)

        if getkv(kw, :canonicalizeheaders, false)
            res.headers = canonicalizeheaders(res.headers)
        end

        setcookies(hostcookies, u.host, res.headers)

        return res

    catch e
        # Redirect request to new location...
        if (isa(e, HTTP.StatusError)
        &&  isredirect(e.response)
        &&  parentcount(e.response) < getkv(kw, :maxredirects, 3)
        &&  header(e.response, "Location") != ""
        &&  method != "HEAD") #FIXME why not redirect HEAD?

            setcookies(hostcookies, u.host, e.response.headers)

            return redirect(e.response, method, uri, headers, body; kw...)
        else
            rethrow(e)
        end
    end
    @assert false "Unreachable!"
end


function redirect(res, method, uri, headers, body; kw...)

    uri = absuri(header(res, "Location"), uri)
    @debug 1 "Redirect: $uri"

    if getkv(kw, :forwardheaders, true)
        headers = filter(h->!(h[1] in ("Host", "Cookie")), headers)
    else
        headers = []
    end

    setkv(kw, :parent, res)

    return request(method, uri, headers, body; kw...)
end


end # module CookieRequest
