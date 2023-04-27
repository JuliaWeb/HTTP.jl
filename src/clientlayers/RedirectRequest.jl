module RedirectRequest

using URIs, LoggingExtras
using ..Messages, ..Pairs

export redirectlayer, nredirects

"""
    redirectlayer(handler) -> handler

Redirects the request in the case of 3xx response status.
"""
function redirectlayer(handler)
    return function redirects(req; redirect::Bool=true, redirect_limit::Int=3, redirect_method=nothing, forwardheaders::Bool=true, response_stream=nothing, kw...)
        if !redirect || redirect_limit == 0
            # no redirecting
            return handler(req; kw...)
        end
        req.context[:allow_redirects] = true
        count = 0
        while true
            # Verify the url before making the request. Verification is done in
            # the redirect loop to also catch bad redirect URLs.
            verify_url(req.url)
            res = handler(req; kw...)

            if (count == redirect_limit || !isredirect(res)
                || (location = header(res, "Location")) == "")
                return res
            end

            # follow redirect
            oldurl = req.url
            url = resolvereference(req.url, location)
            method = newmethod(req.method, res.status, redirect_method)
            body = method == "GET" ? UInt8[] : req.body
            req = Request(method, resource(url), copy(req.headers), body;
                url=url, version=req.version, responsebody=response_stream, parent=res, context=req.context)
            if forwardheaders
                req.headers = filter(req.headers) do (header, _)
                    # false return values are filtered out
                    if header == "Host"
                        return false
                    elseif (header in SENSITIVE_HEADERS && !isdomainorsubdomain(url.host, oldurl.host))
                        return false
                    elseif method == "GET" && header in ("Content-Type", "Content-Length")
                        return false
                    else
                        return true
                    end
                end
            else
                req.headers = Header[]
            end
            @debugv 1 "➡️  Redirect: $url"
            count += 1
            if count == redirect_limit
                req.context[:redirectlimitreached] = true
            end
        end
        @assert false "Unreachable!"
    end
end

function nredirects(req)
    return req.parent === nothing ? 0 : (1 + nredirects(req.parent.request))
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

function newmethod(request_method, response_status, redirect_method)
    # using https://everything.curl.dev/http/redirects#get-or-post as a reference
    # also reference: https://github.com/curl/curl/issues/5237#issuecomment-618293609
    if response_status == 307 || response_status == 308
        # specific status codes that indicate an identical request should be made to new location
        return request_method
    elseif response_status == 303
        # 303 means it's a new/different URI, so only GET allowed
        return "GET"
    elseif redirect_method == :same
        return request_method
    elseif redirect_method !== nothing && String(redirect_method) in ("GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH")
        return redirect_method
    elseif request_method == "HEAD"
        # Unless otherwise specified (e.g. with `redirect_method`), be conservative and keep the
        # same method, see:
        #
        # * <https://httpwg.org/specs/rfc9110.html#status.301>
        # * <https://developer.mozilla.org/en-US/docs/Web/HTTP/Redirections#permanent_redirections>
        #
        # Turning a HEAD request through a redirect may be undesired:
        # <https://developer.mozilla.org/en-US/docs/Web/HTTP/Methods/HEAD>.
        return request_method
    end
    return "GET"
end

end # module RedirectRequest
