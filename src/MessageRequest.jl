module MessageRequest

export body_is_a_stream, body_was_streamed, setuseragent!, resource


import ..Layer, ..request
using HTTP
using ..IOExtras
using URIs
using ..Messages
import ..Messages: bodylength
import ..Headers
import ..Form, ..content_type

"""
"request-target" per https://tools.ietf.org/html/rfc7230#section-5.3
"""
resource(uri::URI) = string( isempty(uri.path)     ? "/" :     uri.path,
                            !isempty(uri.query)    ? "?" : "", uri.query,
                            !isempty(uri.fragment) ? "#" : "", uri.fragment)

"""
    request(stack::Stack{MessageLayer}, method, ::URI, headers, body) -> HTTP.Response

Construct a [`Request`](@ref) object and set mandatory headers.
"""
abstract type MessageLayer <: Layer end
export MessageLayer

function request(stack::Stack{MessageLayer},
                 method::String, url::URI, headers::Headers, body;
                 http_version=v"1.1",
                 target=resource(url),
                 parent=nothing, iofunction=nothing, kw...)

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
    if !hasheader(headers, "Content-Type") && body isa Form && method == "POST"
        # "Content-Type" => "multipart/form-data; boundary=..."
        setheader(headers, content_type(body))
    end

    req = Request(method, target, headers, bodybytes(body);
                  parent=parent, version=http_version)

    return request(stack.next, url, req, body; iofunction=iofunction, kw...)
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

const body_is_a_stream = UInt8[]
const body_was_streamed = bytes("[Message Body was streamed]")
bodybytes(body) = body_is_a_stream
bodybytes(body::Vector{UInt8}) = body
bodybytes(body::IOBuffer) = read(body)
bodybytes(body::AbstractVector{UInt8}) = Vector{UInt8}(body)
bodybytes(body::AbstractString) = bytes(body)
bodybytes(body::Vector) = length(body) == 1 ? bodybytes(body[1]) :
                                              body_is_a_stream

end # module MessageRequest
