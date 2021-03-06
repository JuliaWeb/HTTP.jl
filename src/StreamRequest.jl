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
abstract type StreamLayer{Next <: Layer} <: Layer{Next} end
export StreamLayer

function request(::Type{StreamLayer{Next}}, io::IO, req::Request, body;
                 reached_redirect_limit=false,
                 response_stream=nothing,
                 iofunction=nothing,
                 verbose::Int=0,
                 kw...)::Response where Next

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

    if !isidempotent(req)
        # Wait for pipelined reads to complete
        # before sending non-idempotent request body.
        @debug 2 "non-idempotent client startread"
        startread(io)
    end

    aborted = false
    write_error = nothing
    try

        @sync begin
            if iofunction === nothing
                @async try
                    writebody(http, req, body)
                catch e
                    write_error = e
                    isopen(io) && try; close(io); catch; end
                end
                yield()
                @debug 2 "client startread"
                startread(http)
                readbody(http, response, response_stream, reached_redirect_limit)
                iserror(response) && save_response_stream!(response, response_stream)
            else
                iofunction(http)
            end

            if isaborted(http)
                # The server may have closed the connection.
                # Don't propagate such errors.
                try; close(io); catch; end
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

    # Suppress errors from closing
    try
        @debug 2 "client closewrite"
        closewrite(http)
        @debug 2 "client closeread"
        closeread(http)
    catch;
    end

    verbose == 1 && printlncompact(response)
    verbose == 2 && println(response)

    return request(Next, response)
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
        @debug 2 "client closewrite"
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

function readbody(http::Stream, res::Response, response_stream, reached_redirect_limit)
    if response_stream === nothing
        res.body = read(http)
    else
        if reached_redirect_limit || !isredirect(res)
            res.body = body_was_streamed
            write(response_stream, http)
            close(response_stream)
        end
    end
end

function save_response_stream!(response::Response, response_stream)
    resp = UInt8[]
    response_stream_copy = deepcopy(response_stream)
    while !eof(response_stream_copy)
        append!(resp, readavailable(response_stream_copy))
    end
    response.body = resp
end

end # module StreamRequest
