module BasicAuthRequest

using ..Base64

import ..request
using HTTP
using URIs
using ..Pairs: getkv, setkv
import ..@debug, ..DEBUG_LEVEL

"""
    request(BasicAuthLayer, method, ::URI, headers, body) -> HTTP.Response

Add `Authorization: Basic` header using credentials from url userinfo.
"""
abstract type BasicAuthLayer <: Layer end
export BasicAuthLayer

function request(stack::Stack{BasicAuthLayer},
                 method::String, url::URI, headers, body; kw...)

    userinfo = unescapeuri(url.userinfo)

    if !isempty(userinfo) && getkv(headers, "Authorization", "") == ""
        @debug 1 "Adding Authorization: Basic header."
        setkv(headers, "Authorization", "Basic $(base64encode(userinfo))")
    end

    return request(stack.next, method, url, headers, body; kw...)
end

end # module BasicAuthRequest
