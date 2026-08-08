module BasicAuthRequest

if VERSION > v"0.7.0-DEV.2338"
using Base64
end

import ..Layer, ..request
using ..URIs
using ..Pairs: getkv, setkv
import ..@debug, ..DEBUG_LEVEL


"""
    request(BasicAuthLayer, method, ::URI, headers, body) -> HTTP.Response

Add `Authorization: Basic` header using credentials from url userinfo.
"""

abstract type BasicAuthLayer{Next <: Layer} <: Layer end
export BasicAuthLayer

function request(::Type{BasicAuthLayer{Next}},
                 method::String, uri::URI, headers, body; kw...) where Next

    userinfo = uri.userinfo
    
    if !isempty(userinfo) && getkv(headers, "Authorization", "") == ""
        @debug 1 "Adding Authorization: Basic header."
        setkv(headers, "Authorization", "Basic $(base64encode(userinfo))")
    end
    
    return request(Next, method, uri, headers, body; kw...)
end


end # module BasicAuthRequest
