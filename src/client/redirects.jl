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

function with_redirect(f, allocator, method, uri, headers=nothing, body=nothing, redirect::Bool=true, redirect_limit::Int=3, redirect_method=nothing, forwardheaders::Bool=true)
    if !redirect || redirect_limit == 0
        # no redirecting
        return f(method, uri, headers, body)
    end
    count = 0
    while true
        ret = f(method, uri, headers, body)
        resp = getresponse(ret)
        if (count == redirect_limit || !isredirect(resp) || (location = getheader(resp.headers, "Location")) == "")
            return ret
        end

        # follow redirect
        olduri = uri
        newuri = resolvereference(makeuri(uri), location)
        uri = parseuri(newuri, nothing, allocator)
        method = newmethod(method, resp.status, redirect_method)
        body = method == "GET" ? nothing : body
        if forwardheaders
            headers = filter(headers) do (header, _)
                # false return values are filtered out
                if headereq(header, "host")
                    return false
                elseif any(x -> headereq(x, header), SENSITIVE_HEADERS) && !isdomainorsubdomain(host(uri), host(olduri))
                    return false
                elseif method == "GET" && (headereq(header, "content-type") || headereq(header, "content-length"))
                    return false
                else
                    return true
                end
            end
        else
            headers = Header[]
        end
        count += 1
    end
    @assert false "Unreachable!"
end