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
end
export BasicAuthLayer
Layers.keywordforlayer(::Val{:basicauth}) = BasicAuthLayer
BasicAuthLayer(next; kw...) = BasicAuthLayer(next)

function Layers.request(layer::BasicAuthLayer,
                 method::String, url::URI, headers, body; kw...)

    userinfo = unescapeuri(url.userinfo)

    if !isempty(userinfo) && getkv(headers, "Authorization", "") == ""
        @debug 1 "Adding Authorization: Basic header."
        setkv(headers, "Authorization", "Basic $(base64encode(userinfo))")
    end

    return Layers.request(layer.next, method, url, headers, body; kw...)
end


end # module BasicAuthRequest
