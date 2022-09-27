module ContentTypeDetection

using URIs, LoggingExtras
using ..Sniff, ..Forms, ..Messages, ..IOExtras

export contenttypedetectionlayer

"""
    contenttypedetectionlayer(handler) -> handler

Try and detect the content type of the request body and add the "Content-Type" header.
"""
function contenttypedetectionlayer(handler)
    return function(req; detect_content_type::Bool=false, kw...)
        if detect_content_type && (!hasheader(req.headers, "Content-Type")
            && !isa(req.body, Form)
            && isbytes(req.body))

            sn = sniff(bytes(req.body))
            setheader(req.headers, "Content-Type" => sn)
            @warnv 1 "setting Content-Type header to: $sn"
        end
        return handler(req; kw...)
    end
end

end # module
