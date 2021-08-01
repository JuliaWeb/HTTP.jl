module CanonicalizeRequest

import ..Layer, ..request
using HTTP
using ..Messages
using ..Strings: tocameldash

"""
    request(CanonicalizeLayer, method, ::URI, headers, body) -> HTTP.Response

Rewrite request and response headers in Canonical-Camel-Dash-Format.
"""
abstract type CanonicalizeLayer <: Layer end
export CanonicalizeLayer

function request(stack::Stack{CanonicalizeLayer},
                 method::String, url, headers, body; kw...)

    headers = canonicalizeheaders(headers)

    res = request(stack.next, method, url, headers, body; kw...)

    res.headers = canonicalizeheaders(res.headers)

    return res
end

canonicalizeheaders(h::T) where {T} = T([tocameldash(k) => v for (k,v) in h])

end # module CanonicalizeRequest
