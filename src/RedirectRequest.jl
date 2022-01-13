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
    redirect_limit::Int
    forwardheaders::Bool
end

export RedirectLayer

Layers.keywordforlayer(::Val{:redirect}) = RedirectLayer

Layers.shouldinclude(::Type{RedirectLayer}; redirect::Bool=true, kw...) = redirect

RedirectLayer(next; redirect_limit=3, forwardheaders=true, kw...) =
    RedirectLayer(next, redirect_limit, forwardheaders)

function Layers.request(layer::RedirectLayer, method::String, url::URI, headers, body)
    redirect_limit = layer.redirect_limit
    forwardheaders = layer.forwardheaders
    count = 0
    while true

        # Verify the url before making the request. Verification is done in
        # the redirect loop to also catch bad redirect URLs.
        verify_url(url)
        # FIXME: can't pass keywords to other layers?
        res = Layers.request(layer.next, method, url, headers, body; reached_redirect_limit=(count == redirect_limit), kw...)

        if (count == redirect_limit
        ||  !isredirect(res)
        ||  (location = header(res, "Location")) == "")
            return res
        end


        kw = merge(merge(NamedTuple(), kw), (parent = res,))
        oldurl = url
        url = resolvereference(url, location)
        if forwardheaders
            headers = filter(headers) do h
                # false return values are filtered out
                header, value = h
                if header == "Host"
                    return false
                elseif (header in SENSITIVE_HEADERS
                    && !isdomainorsubdomain(url.host, oldurl.host))
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
