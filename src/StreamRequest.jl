module StreamRequest

using ..Layers
using ..IOExtras
using ..Messages
using ..Streams
import ..ConnectionPool
using ..MessageRequest
import ..@debug, ..DEBUG_LEVEL, ..printlncompact, ..sprintcompact

"""
    Layers.request(StreamLayer, ::IO, ::Request, body) -> HTTP.Response

Create a [`Stream`](@ref) to send a `Request` and `body` to an `IO`
stream and read the response.

Send the `Request` body in a background task and begins reading the response
immediately so that the transmission can be aborted if the `Response` status
indicates that the server does not wish to receive the message body.
[RFC7230 6.5](https://tools.ietf.org/html/rfc7230#section-6.5).
"""
struct StreamLayer <: ConnectionLayer end
export StreamLayer

function Layers.request(::StreamLayer, io::IO, req::Request, body;
                 reached_redirect_limit=false,
                 response_stream=nothing,
                 iofunction=nothing,
                 verbose::Int=0,
                 kw...)::Response

    verbose == 1 && printlncompact(req)

    response = req.response
    http = Stream(response, io)
    @debug 2 "client startwrite"
    startwrite(http)

    if verbose == 2
        println(req)
        if iofunction === nothing && req.body === body_is_a_stream
            println("$(typeof(req)).body: $(sprintcompact(body))")
        end
    end

    write_error = nothing
    try
        @sync begin
            if iofunction === nothing
                @async try
                    writebody(http, req, body)
                    @debug 2 "client closewrite"
                    closewrite(http)
                catch e
                    write_error = e
                    isopen(io) && try; close(io); catch; end
                end
                @debug 2 "client startread"
                startread(http)
                readbody(http, response, response_stream, reached_redirect_limit)
            else
                iofunction(http)
            end

            if isaborted(http)
                # The server may have closed the connection.
                # Don't propagate such errors.
                try; close(io); catch; end
            end
        end
    catch e
        if write_error !== nothing
            throw(write_error)
        else
            rethrow(e)
        end
    end

    @debug 2 "client closewrite"
    closewrite(http)
    @debug 2 "client closeread"
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
    return
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

function readbody(http::Stream, res::Response, response_stream, reached_redirect_limit)
    if response_stream === nothing
        res.body = read(http)
    else
        if reached_redirect_limit || !isredirect(res)
            res.body = body_was_streamed
            write(response_stream, http)
        end
    end
end

end # module StreamRequest
