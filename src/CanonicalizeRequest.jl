module CanonicalizeRequest

using ..Layers
using ..Messages
using ..Strings: tocameldash

"""
    Layers.request(CanonicalizeLayer, method, ::URI, headers, body) -> HTTP.Response

Rewrite request and response headers in Canonical-Camel-Dash-Format.
"""
struct CanonicalizeLayer{Next <: Layer} <: InitialLayer
    next::Next
end
export CanonicalizeLayer
Layers.keywordforlayer(::Val{:canonicalize_headers}) = CanonicalizeLayer
Layers.shouldinclude(::Type{CanonicalizeLayer}; canonicalize_headers::Bool=true, kw...) =
    canonicalize_headers
CanonicalizeLayer(next; kw...) = CanonicalizeLayer(next)

function Layers.request(layer::CanonicalizeLayer, method::String, url, headers, body)

    headers = canonicalizeheaders(headers)

    res = Layers.request(layer.next, method, url, headers, body)

    res.headers = canonicalizeheaders(res.headers)

    return res
end

canonicalizeheaders(h::T) where {T} = T([tocameldash(k) => v for (k,v) in h])

end # module CanonicalizeRequest
