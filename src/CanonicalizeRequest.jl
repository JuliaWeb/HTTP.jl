module CanonicalizeRequest

import ..Layer, ..RequestStack.request
using ..Messages
using ..Strings.tocameldash!

abstract type CanonicalizeLayer{Next <: Layer} <: Layer end
export CanonicalizeLayer


canonicalizeheaders(h::T) where T = T([tocameldash!(k) => v for (k,v) in h])

function request(::Type{CanonicalizeLayer{Next}},
                 method::String, uri, headers, body, response_body;
                 kw...) where Next

    headers = canonicalizeheaders(headers)
    
    res = request(Next, method, uri, headers, body, response_body; kw...)

    res.headers = canonicalizeheaders(res.headers)

    return res
end



end # module CanonicalizeRequest
