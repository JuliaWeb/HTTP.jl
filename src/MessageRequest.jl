module MessageRequest

export body_is_a_stream, body_was_streamed

import ..Layer, ..request
using ..URIs
using ..Messages
using ..Headers
using ..minimal
if !minimal
using ..Form
end


"""
    request(MessageLayer, method, ::URI, headers, body) -> HTTP.Response

Construct a [`Request`](@ref) object and set mandatory headers.
"""

struct MessageLayer{Next <: Layer} <: Layer end
export MessageLayer

function request(::Type{MessageLayer{Next}},
                 method::String, uri::URI, headers::Headers, body;
                 parent=nothing, iofunction=nothing, kw...) where Next

    path = method == "CONNECT" ? hostport(uri) : resource(uri)

    defaultheader(headers, "Host" => uri.host)

    if !hasheader(headers, "Content-Length") &&
       !hasheader(headers, "Transfer-Encoding") &&
       !hasheader(headers, "Upgrade")
        l = bodylength(body)
        if l != unknownlength
            setheader(headers, "Content-Length" => string(l))
        elseif method == "GET" && iofunction isa Function
            setheader(headers, "Content-Length" => "0")
        else
            setheader(headers, "Transfer-Encoding" => "chunked")
        end
    end

    req = Request(method, path, headers, bodybytes(body); parent=parent)

    return request(Next, uri, req, body; iofunction=iofunction, kw...)
end


const unknownlength = -1
bodylength(body) = unknownlength
bodylength(body::AbstractVector{UInt8}) = length(body)
bodylength(body::AbstractString) = sizeof(body)
if !minimal
bodylength(body::Form) = length(body)
end
bodylength(body::Vector{T}) where T <: AbstractString = sum(sizeof, body)
bodylength(body::Vector{T}) where T <: AbstractArray{UInt8,1} = sum(length, body)
bodylength(body::IOBuffer) = nb_available(body)
bodylength(body::Vector{IOBuffer}) = sum(nb_available, body)


const body_is_a_stream = UInt8[]
const body_was_streamed = Vector{UInt8}("[Message Body was streamed]")
bodybytes(body) = body_is_a_stream
bodybytes(body::Vector{UInt8}) = body
bodybytes(body::IOBuffer) = read(body)
bodybytes(body::AbstractVector{UInt8}) = Vector{UInt8}(body)
bodybytes(body::AbstractString) = Vector{UInt8}(body)
bodybytes(body::Vector) = length(body) == 1 ? bodybytes(body[1]) :
                                              body_is_a_stream


end # module MessageRequest
