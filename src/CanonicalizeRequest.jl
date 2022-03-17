module CanonicalizeRequest

using ..Messages
using ..Strings: tocameldash

export canonicalizelayer

"""
    canonicalizelayer(ctx, method, ::URI, headers, body) -> HTTP.Response

Rewrite request and response headers in Canonical-Camel-Dash-Format.
"""
function canonicalizelayer(handler)
    return function(ctx, method, url, headers, body; canonicalize_headers::Bool=false, kw...)
        if canonicalize_headers
            headers = canonicalizeheaders(headers)
        end
        res = handler(ctx, method, url, headers, body; kw...)
        if canonicalize_headers
            res.headers = canonicalizeheaders(res.headers)
        end
        return res
    end
end

canonicalizeheaders(h::T) where {T} = T([tocameldash(k) => v for (k,v) in h])

end # module CanonicalizeRequest
