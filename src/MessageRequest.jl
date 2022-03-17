module MessageRequest

export setuseragent!, resource

using ..Base64
using ..IOExtras
using URIs
using ..Messages
import ..Messages: bodylength
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
            l = bodylength(body)
            if l != unknown_length
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
        req = Request(method, resource(url), headers, bodybytes(body); url=url, version=http_version, responsebody=response_stream, parent=parent)

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

bodylength(body) = unknown_length
bodylength(body::AbstractVector{UInt8}) = length(body)
bodylength(body::AbstractString) = sizeof(body)
bodylength(body::Form) = length(body)
bodylength(body::Vector{T}) where T <: AbstractString = sum(sizeof, body)
bodylength(body::Vector{T}) where T <: AbstractArray{UInt8,1} = sum(length, body)
bodylength(body::IOBuffer) = bytesavailable(body)
bodylength(body::Vector{IOBuffer}) = sum(bytesavailable, body)

bodybytes(body) = body
bodybytes(body::Vector{UInt8}) = body
bodybytes(body::IOBuffer) = read(body)
bodybytes(body::AbstractVector{UInt8}) = Vector{UInt8}(body)
bodybytes(body::AbstractString) = bytes(body)
bodybytes(body::Vector) = length(body) == 1 ? bodybytes(body[1]) : body

end # module MessageRequest
