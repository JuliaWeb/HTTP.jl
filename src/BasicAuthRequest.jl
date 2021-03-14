module BasicAuthRequest

using ..Base64

import ..Layer, ..Layers
using URIs
using ..Pairs: getkv, setkv
import ..@debug, ..DEBUG_LEVEL

"""
    Layers.request(BasicAuthLayer, method, ::URI, headers, body) -> HTTP.Response

Add `Authorization: Basic` header using credentials from url userinfo.
"""
abstract type BasicAuthLayer{Next <: Layer} <: Layer{Next} end
export BasicAuthLayer

function Layers.request(::Type{BasicAuthLayer{Next}},
                        method::String, url::URI, headers, body; kw...) where Next

    userinfo = unescapeuri(url.userinfo)

    if !isempty(userinfo) && getkv(headers, "Authorization", "") == ""
        @debug 1 "Adding Authorization: Basic header."
        setkv(headers, "Authorization", "Basic $(base64encode(userinfo))")
    end

    return Layers.request(Next, method, url, headers, body; kw...)
end


end # module BasicAuthRequest
