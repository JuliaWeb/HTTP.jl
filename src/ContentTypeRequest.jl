module ContentTypeDetection

import ..Layer, ..request
using ..URIs
using ..Pairs: getkv, setkv
import ..sniff
import ..Form
using ..Messages
import ..MessageRequest: bodylength, bodybytes
import ..@debug, ..DEBUG_LEVEL

abstract type ContentTypeDetectionLayer{Next <: Layer} <: Layer end
export ContentTypeDetectionLayer

function request(::Type{ContentTypeDetectionLayer{Next}},
                 method::String, url::URI, headers, body; kw...) where Next

    if (getkv(headers, "Content-Type", "") == ""
    &&  !isa(body, Form)
    &&  bodylength(body) != unknown_length
    &&  bodylength(body) > 0)

        sn = sniff(bodybytes(body))
        setkv(headers, "Content-Type", sn)
        @debug 1 "setting Content-Type header to: $sn"
    end
    return request(Next, method, url, headers, body; kw...)
end

end # module
