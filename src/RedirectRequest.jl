module RedirectRequest

import ..Layer, ..request
using ..URIs
using ..Messages
using ..Pairs: setkv
using ..Header
import ..@debug, ..DEBUG_LEVEL


"""
    request(RedirectLayer, method, ::URI, headers, body) -> HTTP.Response

Redirects the request in the case of 3xx response status.
"""

abstract type RedirectLayer{Next <: Layer} <: Layer end
export RedirectLayer

function request(::Type{RedirectLayer{Next}},
                 method::String, uri::URI, headers, body;
                 redirect_limit=3, forwardheaders=false, kw...) where Next
    count = 0
    while true
    
        res = request(Next, method, uri, headers, body; kw...)

        if (count == redirect_limit
        ||  !isredirect(res)
        ||  (location = header(res, "Location")) == ""
        ||  method == "HEAD") #FIXME why not redirect HEAD?
            return res
        end
            

        if VERSION > v"0.7.0-DEV.2338"
        kw = merge(kw, [:parent => res])
        else
        setkv(kw, :parent, res)
        end
        uri = absuri(location, uri)
        if forwardheaders 
            headers = filter(h->!(h[1] in ("Host", "Cookie")), headers)
        else
            headers = Header[]
        end

        @debug 1 "➡️  Redirect: $uri"

        count += 1
    end

    @assert false "Unreachable!"
end


end # module RedirectRequest
