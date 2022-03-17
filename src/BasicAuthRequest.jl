module BasicAuthRequest

using ..Base64
using URIs
using ..Pairs: getkv, setkv
import ..@debug, ..DEBUG_LEVEL

export basicauthlayer
"""
    basicauthlayer(ctx, method, ::URI, headers, body) -> HTTP.Response

Add `Authorization: Basic` header using credentials from url userinfo.
"""
function basicauthlayer(handler)
    return function(ctx, method, url, headers, body; basicauth::Bool=true, kw...)
        if basicauth
            userinfo = unescapeuri(url.userinfo)
            if !isempty(userinfo) && getkv(headers, "Authorization", "") == ""
                @debug 1 "Adding Authorization: Basic header."
                setkv(headers, "Authorization", "Basic $(base64encode(userinfo))")
            end
        end
        return handler(ctx, method, url, headers, body; kw...)
    end
end

end # module BasicAuthRequest
