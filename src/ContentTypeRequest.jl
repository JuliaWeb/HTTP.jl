module ContentTypeDetection

using ..Layers
using URIs
using ..Pairs: getkv, setkv
import ..sniff
import ..Form
using ..Messages
import ..MessageRequest: bodylength, bodybytes
import ..@debug, ..DEBUG_LEVEL

struct ContentTypeDetectionLayer{Next <: Layer} <: InitialLayer
    next::Next
    detect_content_type::Bool
end
export ContentTypeDetectionLayer
ContentTypeDetectionLayer(next; detect_content_type::Bool=false, kw...) = ContentTypeDetectionLayer(next, detect_content_type)

function Layers.request(layer::ContentTypeDetectionLayer, ctx, method::String, url::URI, headers, body)

    if layer.detect_content_type && (getkv(headers, "Content-Type", "") == ""
    &&  !isa(body, Form)
    &&  bodylength(body) != unknown_length
    &&  bodylength(body) > 0)

        sn = sniff(bodybytes(body))
        setkv(headers, "Content-Type", sn)
        @debug 1 "setting Content-Type header to: $sn"
    end
    return Layers.request(layer.next, ctx, method, url, headers, body)
end

end # module
