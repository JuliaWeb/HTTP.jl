module CanonicalizeRequest

import ..Layer, ..RequestStack.request
using ..Messages
using ..Strings.tocameldash!

abstract type CanonicalizeLayer{Next <: Layer} <: Layer end
export CanonicalizeLayer


canonicalizeheaders{T}(h::T) = T([tocameldash!(k) => v for (k,v) in h])

function request(::Type{CanonicalizeLayer{Next}},
                 method::String, uri, headers=[], body=""; kw...) where Next

    headers = canonicalizeheaders(headers)
    
    res = request(Next, method, uri, headers, body; kw...)

    res.headers = canonicalizeheaders(res.headers)

    return res
end



end # module CanonicalizeRequest
