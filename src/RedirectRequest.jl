module RedirectRequest

import ..Layer, ..RequestStack.request
using ..URIs
using ..Messages
using ..Pairs: setkv
using ..Strings.tocameldash!
import ..@debug, ..DEBUG_LEVEL

abstract type RedirectLayer{Next <: Layer} <: Layer end
export RedirectLayer


function request(::Type{RedirectLayer{Next}},
                 method::String, uri, headers, body, response_body;
                 maxredirects=3, forwardheaders=false, kw...) where Next
    count = 0
    while true
    
        res = request(Next, method, uri, headers, body, response_body; kw...)

        if (count == maxredirects
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
            headers = []
        end

        count += 1
    end

    @assert false "Unreachable!"
end


end # module RedirectRequest
