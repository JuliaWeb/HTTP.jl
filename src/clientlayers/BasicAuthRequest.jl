module BasicAuthRequest

using Base64, URIs, LoggingExtras
import ..Messages: setheader, hasheader
import ..DEBUG_LOG

export basicauthlayer

"""
    basicauthlayer(handler) -> handler

Add `Authorization: Basic` header using credentials from url userinfo.
"""
function basicauthlayer(handler)
    return function(req; basicauth::Bool=true, kw...)
        if basicauth
            userinfo = unescapeuri(req.url.userinfo)
            if !isempty(userinfo) && !hasheader(req.headers, "Authorization")
                DEBUG_LOG[] && @warnv 1 "Adding Authorization: Basic header."
                setheader(req.headers, "Authorization" => "Basic $(base64encode(userinfo))")
            end
        end
        return handler(req; kw...)
    end
end

end # module BasicAuthRequest
