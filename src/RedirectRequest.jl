module RedirectRequest

using ..Layers
using URIs
using ..Messages
using ..Pairs: setkv
import ..Header
import ..@debug, ..DEBUG_LEVEL

"""
    Layers.request(RedirectLayer, method, ::URI, headers, body) -> HTTP.Response

Redirects the request in the case of 3xx response status.
"""
struct RedirectLayer{Next <: Layer} <: InitialLayer
    next::Next
    redirect::Bool
    redirect_limit::Int
    forwardheaders::Bool
end

export RedirectLayer

RedirectLayer(next; redirect::Bool=true, redirect_limit=3, forwardheaders=true, kw...) =
    RedirectLayer(next, redirect, redirect_limit, forwardheaders)

function Layers.request(layer::RedirectLayer, ctx, method, url, headers, body)
    redirect_limit = layer.redirect_limit
    if !layer.redirect || layer.redirect_limit == 0
        # no redirecting
        return Layers.request(layer.next, ctx, method, url, headers, body)
    end

    forwardheaders = layer.forwardheaders
    count = 0
    while true

        # Verify the url before making the request. Verification is done in
        # the redirect loop to also catch bad redirect URLs.
        verify_url(url)
        if count == redirect_limit
            ctx[:redirectlimitreached] = true
        end
        res = Layers.request(layer.next, ctx, method, url, headers, body)

        if (count == redirect_limit
        ||  !isredirect(res)
        ||  (location = header(res, "Location")) == "")
            return res
        end

        # follow redirect
        ctx[:parentrequest] = res.request
        oldurl = url
        url = resolvereference(oldurl, location)
        if forwardheaders
            headers = filter(headers) do (header, _)
                # false return values are filtered out
                if header == "Host"
                    return false
                elseif (header in SENSITIVE_HEADERS && !isdomainorsubdomain(url.host, url.host))
                    return false
                else
                    return true
                end
            end
        else
            headers = Header[]
        end

        @debug 1 "➡️  Redirect: $url"

        count += 1
    end

    @assert false "Unreachable!"
end

const SENSITIVE_HEADERS = Set([
    "Authorization",
    "Www-Authenticate",
    "Cookie",
    "Cookie2"
])

function isdomainorsubdomain(sub, parent)
    sub == parent && return true
    endswith(sub, parent) || return false
    return sub[length(sub)-length(parent)] == '.'
end

function verify_url(url::URI)
    if !(url.scheme in ("http", "https", "ws", "wss"))
        throw(ArgumentError("missing or unsupported scheme in URL (expected http(s) or ws(s)): $(url)"))
    end
    if isempty(url.host)
        throw(ArgumentError("missing host in URL: $(url)"))
    end
end

end # module RedirectRequest
