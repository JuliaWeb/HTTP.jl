module MessageRequest

export setuseragent!, resource

using ..Base64
using ..IOExtras
using URIs
using ..Messages
import ..Headers
import ..Form, ..content_type

export messagelayer

"""
    messagelayer(ctx, method, ::URI, headers, body) -> HTTP.Response

Construct a [`Request`](@ref) object and set mandatory headers.
"""
function messagelayer(handler)
    return function(ctx, method::String, url::URI, headers::Headers, body; iofunction=nothing, response_stream=nothing, http_version=v"1.1", kw...)
        if isempty(url.port) ||
                (url.scheme == "http" && url.port == "80") ||
                (url.scheme == "https" && url.port == "443")
            hostheader = url.host
        else
            hostheader = url.host * ":" * url.port
        end
        defaultheader!(headers, "Host" => hostheader)
        defaultheader!(headers, "Accept" => "*/*")
        if USER_AGENT[] !== nothing
            defaultheader!(headers, "User-Agent" => USER_AGENT[])
        end

        if !hasheader(headers, "Content-Length") &&
        !hasheader(headers, "Transfer-Encoding") &&
        !hasheader(headers, "Upgrade")
            l = nbytes(body)
            if l !== nothing
                setheader(headers, "Content-Length" => string(l))
            elseif method == "GET" && iofunction isa Function
                setheader(headers, "Content-Length" => "0")
            end
        end
        if !hasheader(headers, "Content-Type") && body isa Form && method in ("POST", "PUT")
            # "Content-Type" => "multipart/form-data; boundary=..."
            setheader(headers, content_type(body))
        end
        parent = get(ctx, :parentrequest, nothing)
        req = Request(method, resource(url), headers, body; url=url, version=http_version, responsebody=response_stream, parent=parent)

        return handler(ctx, req; iofunction=iofunction, kw...)
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

end # module MessageRequest
