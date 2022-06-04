module DefaultHeadersRequest

export defaultheaderslayer, setuseragent!

using ..Messages, ..Forms, ..IOExtras

"""
    defaultheaderslayer(handler) -> handler

Sets default expected headers.
"""
function defaultheaderslayer(handler)
    return function(req; iofunction=nothing, kw...)
        headers = req.headers
        if isempty(req.url.port) ||
            (req.url.scheme == "http" && req.url.port == "80") ||
            (req.url.scheme == "https" && req.url.port == "443")
            hostheader = req.url.host
        else
            hostheader = req.url.host * ":" * req.url.port
        end
        defaultheader!(headers, "Host" => hostheader)
        defaultheader!(headers, "Accept" => "*/*")
        if USER_AGENT[] !== nothing
            defaultheader!(headers, "User-Agent" => USER_AGENT[])
        end

        if !hasheader(headers, "Content-Length") &&
        !hasheader(headers, "Transfer-Encoding") &&
        !hasheader(headers, "Upgrade")
            l = nbytes(req.body)
            if l !== nothing
                setheader(headers, "Content-Length" => string(l))
            elseif req.method == "GET" && iofunction isa Function
                setheader(headers, "Content-Length" => "0")
            end
        end
        if !hasheader(headers, "Content-Type") && req.body isa Form && req.method in ("POST", "PUT")
            # "Content-Type" => "multipart/form-data; boundary=..."
            setheader(headers, content_type(req.body))
        end
        return handler(req; iofunction=iofunction, kw...)
    end
end

const USER_AGENT = Ref{Union{String, Nothing}}("HTTP.jl/$VERSION")

"""
    setuseragent!(x::Union{String, Nothing})

Set the default User-Agent string to be used in each HTTP request.
Can be manually overridden by passing an explicit `User-Agent` header.
Setting `nothing` will prevent the default `User-Agent` header from being passed.
"""
function setuseragent!(x::Union{String, Nothing})
    USER_AGENT[] = x
    return
end

end # module
