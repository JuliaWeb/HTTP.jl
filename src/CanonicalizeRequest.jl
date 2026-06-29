module CanonicalizeRequest

import ..Layer, ..request
using ..Messages
using ..Strings.tocameldash!


"""
    request(CanonicalizeLayer, method, ::URI, headers, body) -> HTTP.Response

Rewrite request and response headers in Canonical-Camel-Dash-Format.
"""

abstract type CanonicalizeLayer{Next <: Layer} <: Layer end
export CanonicalizeLayer

function request(::Type{CanonicalizeLayer{Next}},
                 method::String, uri, headers, body; kw...) where Next

    headers = canonicalizeheaders(headers)
    
    res = request(Next, method, uri, headers, body; kw...)

    res.headers = canonicalizeheaders(res.headers)

    return res
end


canonicalizeheaders(h::T) where T = T([tocameldash!(k) => v for (k,v) in h])


end # module CanonicalizeRequest
