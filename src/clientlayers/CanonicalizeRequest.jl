module CanonicalizeRequest

using ..Messages, ..Strings

export canonicalizelayer

"""
    canonicalizelayer(handler) -> handler

Rewrite request and response headers in Canonical-Camel-Dash-Format.
"""
function canonicalizelayer(handler)
    return function(req; canonicalize_headers::Bool=false, kw...)
        if canonicalize_headers
            req.headers = canonicalizeheaders(req.headers)
        end
        res = handler(req; kw...)
        if canonicalize_headers
            res.headers = canonicalizeheaders(res.headers)
        end
        return res
    end
end

canonicalizeheaders(h::T) where {T} = T([tocameldash(k) => v for (k,v) in h])

end # module CanonicalizeRequest
