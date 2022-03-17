module ContentTypeDetection

using URIs
using ..Pairs: getkv, setkv
import ..sniff
import ..Form
using ..Messages
import ..MessageRequest: bodylength, bodybytes
import ..@debug, ..DEBUG_LEVEL

export contenttypedetectionlayer

function contenttypedetectionlayer(handler)
    return function(ctx, method, url, headers, body; detect_content_type::Bool=false, kw...)
        if detect_content_type && (getkv(headers, "Content-Type", "") == ""
            &&  !isa(body, Form)
            &&  bodylength(body) != unknown_length
            &&  bodylength(body) > 0)

            sn = sniff(bodybytes(body))
            setkv(headers, "Content-Type", sn)
            @debug 1 "setting Content-Type header to: $sn"
        end
        return handler(ctx, method, url, headers, body; kw...)
    end
end

end # module
