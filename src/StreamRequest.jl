module StreamRequest

import ..Layer, ..request
using ..IOExtras
using ..Messages
using ..Streams
import ..ConnectionPool
using ..MessageRequest
import ..@debug, ..DEBUG_LEVEL, ..printlncompact, ..sprintcompact

"""
    request(StreamLayer, ::IO, ::Request, body) -> HTTP.Response

Create a [`Stream`](@ref) to send a `Request` and `body` to an `IO`
stream and read the response.

Send the `Request` body in a background task and begins reading the response
immediately so that the transmission can be aborted if the `Response` status
indicates that the server does not wish to receive the message body.
[RFC7230 6.5](https://tools.ietf.org/html/rfc7230#section-6.5).
"""
abstract type StreamLayer <: Layer end
export StreamLayer

function request(::Type{StreamLayer}, io::IO, request::Request, body;
                 response_stream=nothing,
                 iofunction=nothing,
                 verbose::Int=0,
                 kw...)::Response

    verbose == 1 && printlncompact(request)

    response = request.response
    http = Stream(response, io)
    startwrite(http)

    if verbose == 2
        println(request)
        if iofunction === nothing && request.body === body_is_a_stream
            println("$(typeof(request)).body: $(sprintcompact(body))")
        end
    end

    if !isidempotent(request)
        # Wait for pipelined reads to complete
        # before sending non-idempotent request body.
        startread(io)
    end

    aborted = false
    write_error = nothing
    try

        @sync begin
            if iofunction === nothing
                @async try
                    writebody(http, request, body)
                catch e
                    write_error = e
                    @warn("Error in @async writebody task",
                          exception=(write_error, catch_backtrace()))
                    close(io)
                end
                yield()
                startread(http)
                readbody(http, response, response_stream)
            else
                iofunction(http)
            end

            if isaborted(http)
                close(io)
                aborted = true
            end
        end

    catch e
        if write_error !== nothing
            throw(write_error)
        else
            rethrow(e)
        end
    end

    closewrite(http)
    closeread(http)

    verbose == 1 && printlncompact(response)
    verbose == 2 && println(response)

    return response
end

function writebody(http::Stream, req::Request, body)

    if req.body === body_is_a_stream
        writebodystream(http, req, body)
        closebody(http)
    else
        write(http, req.body)
    end

    req.txcount += 1

    if isidempotent(req)
        closewrite(http)
    else
        @debug 2 "🔒  $(req.method) non-idempotent, " *
                 "holding write lock: $(http.stream)"
        # "A user agent SHOULD NOT pipeline requests after a
        #  non-idempotent method, until the final response
        #  status code for that method has been received"
        # https://tools.ietf.org/html/rfc7230#section-6.3.2
    end
end

function writebodystream(http, req, body)
    for chunk in body
        writechunk(http, req, chunk)
    end
end

function writebodystream(http, req, body::IO)
    req.body = body_was_streamed
    write(http, body)
end

writechunk(http, req, body::IO) = writebodystream(http, req, body)
writechunk(http, req, body) = write(http, body)

function readbody(http::Stream, res::Response, response_stream)
    if response_stream == nothing
        res.body = read(http)
    else
        res.body = body_was_streamed
        write(response_stream, http)
        close(response_stream)
    end
end

end # module StreamRequest
