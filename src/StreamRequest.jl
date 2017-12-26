module StreamRequest

import ..Layer, ..request
using ..IOExtras
using ..Parsers
using ..Messages
using ..HTTPStreams
using ..ConnectionPool.getparser
using ..MessageRequest
import ..@debug, ..DEBUG_LEVEL

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

    @debug 1 req

    http = HTTPStream(io, req, getparser(io))

    if iofunction != nothing
        iofunction(http)
    else
        if req.body === body_is_a_stream
            writebody(http, req, body)
        end

        readheaders(http)
        if response_stream == nothing
            http.message.body = read(http)
        else
            http.message.body = body_was_streamed
            write(response_stream, http)
        end
    end

    close(http)

    @debug 1 http.message

    return http.message
end


end # module StreamRequest
