module ContentTypeDetection

using URIs
import ..sniff
import ..Form
using ..Messages
import ..IOExtras
using LoggingExtras

export contenttypedetectionlayer

function contenttypedetectionlayer(handler)
    return function(req; detect_content_type::Bool=false, kw...)
        if detect_content_type && (!hasheader(req.headers, "Content-Type")
            && !isa(req.body, Form)
            && isbytes(req.body))

            sn = sniff(bytes(req.body))
            setheader(req.headers, "Content-Type" => sn)
            @debugv 1 "setting Content-Type header to: $sn"
        end
        return handler(req; kw...)
    end
end

end # module
