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
end
export ContentTypeDetectionLayer
Layers.keywordforlayer(::Val{:detect_content_type}) = ContentTypeDetectionLayer
ContentTypeDetectionLayer(next; detect_content_type::Bool=true, kw...) =
    detect_content_type ? ContentTypeDetectionLayer(netx) : nothing

function Layers.request(layer::ContentTypeDetectionLayer,
                 method::String, url::URI, headers, body; kw...)

    if (getkv(headers, "Content-Type", "") == ""
    &&  !isa(body, Form)
    &&  bodylength(body) != unknown_length
    &&  bodylength(body) > 0)

        sn = sniff(bodybytes(body))
        setkv(headers, "Content-Type", sn)
        @debug 1 "setting Content-Type header to: $sn"
    end
    return Layers.request(layer.next, method, url, headers, body; kw...)
end

end # module
