module CanonicalizeRequest

struct CanonicalizeLayer{T} end
export CanonicalizeLayer

import ..HTTP.RequestStack.request

using ..Messages
using ..Strings.tocameldash!

canonicalizeheaders{T}(h::T) = T([tocameldash!(k) => v for (k,v) in h])

function request(::Type{CanonicalizeLayer{Next}},
                 method::String, uri, headers=[], body=""; kw...) where Next

    headers = canonicalizeheaders(headers)
    
    res = request(Next, method, uri, headers, body; kw...)

    res.headers = canonicalizeheaders(res.headers)

    return res
end



end # module CanonicalizeRequest
