module RedirectRequest

import ..Layer, ..request
using ..URIs
using ..Messages
using ..Pairs: setkv
import ..Header
import ..@debug, ..DEBUG_LEVEL

"""
    request(RedirectLayer, method, ::URI, headers, body) -> HTTP.Response

Redirects the request in the case of 3xx response status.
"""
abstract type RedirectLayer{Next <: Layer} <: Layer end
export RedirectLayer

function request(::Type{RedirectLayer{Next}},
                 method::String, url::URI, headers, body;
                 redirect_limit=3, forwardheaders=true, kw...) where Next
    count = 0
    while true
    
        res = request(Next, method, url, headers, body; kw...)

        if (count == redirect_limit
        ||  !isredirect(res)
        ||  (location = header(res, "Location")) == "")
            return res
        end
            

        kw = merge(merge(NamedTuple(), kw), (parent = res,))
        oldurl = url
        url = absuri(location, url)
        if forwardheaders 
            headers = filter(headers) do h
                # false return values are filtered out
                header, value = h
                if header == "Host"
                    return false
                elseif (header in SENSITIVE_HEADERS
                    && !isdomainorsubdomain(url.host, oldurl.host))
                    return false
                else
                    return true
                end
            end
        else
            headers = Header[]
        end

        @debug 1 "➡️  Redirect: $url"

        count += 1
    end

    @assert false "Unreachable!"
end

const SENSITIVE_HEADERS = Set([
    "Authorization",
    "Www-Authenticate",
    "Cookie",
    "Cookie2"
])

function isdomainorsubdomain(sub, parent)
    sub == parent && return true
    endswith(sub, parent) || return false
    return sub[length(sub)-length(parent)] == '.'
end

end # module RedirectRequest
