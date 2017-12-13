module BasicAuthRequest

import ..Layer, ..RequestStack.request
using ..URIs
using ..Pairs: getkv, setkv
import ..@debug, ..DEBUG_LEVEL

abstract type BasicAuthLayer{Next <: Layer} <: Layer end
export BasicAuthLayer


function request(::Type{BasicAuthLayer{Next}},
                 method::String, uri, headers=[], body=""; kw...) where Next

    userinfo = URI(uri).userinfo
    
    if !isempty(userinfo) && getkv(headers, "Authorization", "") == ""
        @debug 1 "Adding Authorization: Basic header."
        setkv(headers, "Authorization", "Basic $(base64encode(userinfo))")
    end
    
    return request(Next, method, uri, headers, body; kw...)
end


end # module BasicAuthRequest
