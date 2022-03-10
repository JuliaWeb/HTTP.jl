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
    canonicalize_headers::Bool
end
export CanonicalizeLayer
CanonicalizeLayer(next; canonicalize_headers::Bool=false, kw...) = CanonicalizeLayer(next, canonicalize_headers)

function Layers.request(layer::CanonicalizeLayer, ctx, method::String, url, headers, body)

    if layer.canonicalize_headers
        headers = canonicalizeheaders(headers)
    end
    res = Layers.request(layer.next, ctx, method, url, headers, body)
    if layer.canonicalize_headers
        res.headers = canonicalizeheaders(res.headers)
    end
    return res
end

canonicalizeheaders(h::T) where {T} = T([tocameldash(k) => v for (k,v) in h])

end # module CanonicalizeRequest
