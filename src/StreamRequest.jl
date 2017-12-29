module StreamRequest

import ..Layer, ..request
using ..IOExtras
using ..Parsers
using ..Messages
using ..HTTPStreams
import ..ConnectionPool
using ..MessageRequest
import ..@debugshort, ..DEBUG_LEVEL, ..printlncompact

abstract type StreamLayer <: Layer end
export StreamLayer


writebody(http, req, body) = for chunk in body write(http, req, chunk) end

function writebody(http, req, body::IO)
    req.body = body_was_streamed
    write(http, body)
end


"""
    request(StreamLayer, ::IO, ::Request, ::Response)

Send a `Request` and receive a `Response`.
Run the `Request` in a background task if response body is a stream.
"""

function request(::Type{StreamLayer}, io::IO, req::Request, body;
                 response_stream=nothing,
                 iofunction=nothing,
                 verbose::Int=0,
                 kw...)::Response

    verbose == 1 && printlncompact(req)
    verbose >= 2 && println(req)

    http = HTTPStream(io, req, ConnectionPool.getparser(io))

    if iofunction != nothing
        write(io, req)
        iofunction(http)
    else
        write(io, req)
        if req.body === body_is_a_stream
            writebody(http, req, body)
        end
#= FIXME
        @async begin
            write(io, req)
            if req.body === body_is_a_stream
                writebody(http, req, body)
            end
            writeend(http)
            closewrite(http.stream)
        end
=#


        readheaders(http)
        if response_stream == nothing
            req.response.body = read(http)
        else
            req.response.body = body_was_streamed
            write(response_stream, http)
        end
    end

    close(http)

    verbose == 1 && printlncompact(req.response)
    verbose >= 2 && println(req.response)

    return req.response
end


end # module StreamRequest
