module CanonicalizeRequest

import ..Layer, ..Layers
using ..Messages
using ..Strings: tocameldash

"""
    Layers.request(CanonicalizeLayer, method, ::URI, headers, body) -> HTTP.Response

Rewrite request and response headers in Canonical-Camel-Dash-Format.
"""
abstract type CanonicalizeLayer{Next <: Layer} <: Layer{Next} end
export CanonicalizeLayer

function Layers.request(::Type{CanonicalizeLayer{Next}},
                 method::String, url, headers, body; kw...) where Next

    headers = canonicalizeheaders(headers)

    res = Layers.request(Next, method, url, headers, body; kw...)

    res.headers = canonicalizeheaders(res.headers)

    return res
end

canonicalizeheaders(h::T) where {T} = T([tocameldash(k) => v for (k,v) in h])

end # module CanonicalizeRequest
