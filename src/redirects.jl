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
