module ContentTypeDetection

using URIs
using ..Pairs: getkv, setkv
import ..sniff
import ..Form
using ..Messages
import ..IOExtras
import ..@debug, ..DEBUG_LEVEL

export contenttypedetectionlayer
# f(::Handler) -> Handler
function contenttypedetectionlayer(handler)
    return function(ctx, method, url, headers, body; detect_content_type::Bool=false, kw...)
        if detect_content_type && (getkv(headers, "Content-Type", "") == ""
            &&  !isa(body, Form)
            &&  isbytes(body))

            sn = sniff(bytes(body))
            setkv(headers, "Content-Type", sn)
            @debug 1 "setting Content-Type header to: $sn"
        end
        return handler(ctx, method, url, headers, body; kw...)
    end
end

end # module
