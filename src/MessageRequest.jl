module MessageRequest

export body_is_a_stream, body_was_streamed

import ..Layer, ..request
using ..URIs
using ..Messages
import ..Messages.bodylength
using ..Headers
using ..Form


"""
    request(MessageLayer, method, ::URI, headers, body) -> HTTP.Response

Construct a [`Request`](@ref) object and set mandatory headers.
"""

struct MessageLayer{Next <: Layer} <: Layer end
export MessageLayer

function request(::Type{MessageLayer{Next}},
                 method::String, url::URI, headers::Headers, body;
                 http_version=v"1.1",
                 target=resource(url),
                 parent=nothing, iofunction=nothing, kw...) where Next

    defaultheader(headers, "Host" => url.host)

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

    req = Request(method, target, headers, bodybytes(body);
                  parent=parent, version=http_version)

    return request(Next, url, req, body; iofunction=iofunction, kw...)
end


bodylength(body) = unknown_length
bodylength(body::AbstractVector{UInt8}) = length(body)
bodylength(body::AbstractString) = sizeof(body)
bodylength(body::Form) = length(body)
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
