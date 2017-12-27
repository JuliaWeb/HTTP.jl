module StreamRequest

import ..Layer, ..request
using ..IOExtras
using ..Parsers
using ..Messages
using ..HTTPStreams
import ..ConnectionPool
using ..MessageRequest
import ..@debugshort, ..DEBUG_LEVEL

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
                 kw...)::Response

    write(io, req)

    @debugshort 2 req
    @debug 3 req

    http = HTTPStream(io, req, ConnectionPool.getparser(io))

    if iofunction != nothing
        iofunction(http)
    else
        if req.body === body_is_a_stream
            writebody(http, req, body)
        end

        readheaders(http)
        if response_stream == nothing
            req.response.body = read(http)
        else
            req.response.body = body_was_streamed
            write(response_stream, http)
        end
    end

    close(http)

    @debugshort 2 req.response
    @debug 3 req.response

    return req.response
end


end # module StreamRequest
