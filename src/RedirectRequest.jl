module RedirectRequest

using URIs
using ..Messages
using ..Pairs: setkv
import ..Header
import ..@debug, ..DEBUG_LEVEL

export redirectlayer

"""
    redirectlayer(ctx, method, ::URI, headers, body) -> HTTP.Response

Redirects the request in the case of 3xx response status.
"""
function redirectlayer(handler)
    return function(ctx, method, url, headers, body; redirect::Bool=true, redirect_limit::Int=3, forwardheaders::Bool=true, kw...)
        println("redirectlayer")
        if !redirect || redirect_limit == 0
            # no redirecting
            return handler(ctx, method, url, headers, body; kw...)
        end

        count = 0
        while true
            # Verify the url before making the request. Verification is done in
            # the redirect loop to also catch bad redirect URLs.
            verify_url(url)
            if count == redirect_limit
                ctx[:redirectlimitreached] = true
            end
            res = handler(ctx, method, url, headers, body; kw...)

            if (count == redirect_limit ||  !isredirect(res)
                ||  (location = header(res, "Location")) == "")
                return res
            end

            # follow redirect
            ctx[:parentrequest] = res
            oldurl = url
            url = resolvereference(oldurl, location)
            if forwardheaders
                headers = filter(headers) do (header, _)
                    # false return values are filtered out
                    if header == "Host"
                        return false
                    elseif (header in SENSITIVE_HEADERS && !isdomainorsubdomain(url.host, oldurl.host))
                        return false
                    else
                        return true
                    end
                end
            else
                headers = Header[]
            end
            @show 1 "➡️  Redirect: $url"
            @show headers
            count += 1
        end
        @assert false "Unreachable!"
    end
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
