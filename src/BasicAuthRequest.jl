module BasicAuthRequest

struct BasicAuthLayer{T} end
export BasicAuthLayer

import ..HTTP.RequestStack.request

using ..URIs
using ..Pairs: getkv, setkv

import ..@debug, ..DEBUG_LEVEL


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
