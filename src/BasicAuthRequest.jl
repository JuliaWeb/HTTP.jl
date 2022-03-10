module BasicAuthRequest

using ..Base64
using ..Layers
using URIs
using ..Pairs: getkv, setkv
import ..@debug, ..DEBUG_LEVEL

"""
    Layers.request(BasicAuthLayer, method, ::URI, headers, body) -> HTTP.Response

Add `Authorization: Basic` header using credentials from url userinfo.
"""
struct BasicAuthLayer{Next <: Layer} <: InitialLayer
    next::Next
    basicauth::Bool
end
export BasicAuthLayer
BasicAuthLayer(next; basicauth::Bool=true, kw...) = BasicAuthLayer(next, basicauth)

function Layers.request(layer::BasicAuthLayer, ctx, method::String, url::URI, headers, body)
    if layer.basicauth
        userinfo = unescapeuri(url.userinfo)
        if !isempty(userinfo) && getkv(headers, "Authorization", "") == ""
            @debug 1 "Adding Authorization: Basic header."
            setkv(headers, "Authorization", "Basic $(base64encode(userinfo))")
        end
    end
    return Layers.request(layer.next, ctx, method, url, headers, body)
end

end # module BasicAuthRequest
