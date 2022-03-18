module StreamRequest

using ..IOExtras
using ..Messages
using ..Streams
import ..ConnectionPool
using ..MessageRequest
import ..RedirectRequest: nredirects
import ..@debug, ..DEBUG_LEVEL, ..printlncompact, ..sprintcompact

export streamlayer

"""
    streamlayer(ctx, stream) -> HTTP.Response

Create a [`Stream`](@ref) to send a `Request` and `body` to an `IO`
stream and read the response.

Send the `Request` body in a background task and begins reading the response
immediately so that the transmission can be aborted if the `Response` status
indicates that the server does not wish to receive the message body.
[RFC7230 6.5](https://tools.ietf.org/html/rfc7230#section-6.5).
"""
function streamlayer(stream::Stream; iofunction=nothing, verbose=0, redirect_limit::Int=3, kw...)::Response
    response = stream.message
    req = response.request
    io = stream.stream
    verbose == 1 && printlncompact(req)
    @debug 2 "client startwrite"
    startwrite(stream)

    if verbose == 2
        println(req)
        if iofunction === nothing && req.body isa IO
            println("$(typeof(req)).body: $(sprintcompact(req.body))")
        end
    end

    write_error = nothing
    try
        @sync begin
            if iofunction === nothing
                @async try
                    writebody(stream, req)
                    @debug 2 "client closewrite"
                    closewrite(stream)
                catch e
                    write_error = e
                    isopen(io) && try; close(io); catch; end
                end
                @debug 2 "client startread"
                startread(stream)
                readbody(stream, response, redirect_limit == nredirects(req))
            else
                iofunction(stream)
            end
            if isaborted(stream)
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
    closewrite(stream)
    @debug 2 "client closeread"
    closeread(stream)

    verbose == 1 && printlncompact(response)
    verbose == 2 && println(response)

    return response
end

function writebody(stream::Stream, req::Request)

    if !isbytes(req.body)
        writebodystream(stream, req.body)
        closebody(stream)
    else
        write(stream, req.body)
    end
    req.context[:retrycount] = get(req.context, :retrycount, 0) + 1
    return
end

function writebodystream(stream, body)
    for chunk in body
        writechunk(stream, chunk)
    end
end

function writebodystream(stream, body::IO)
    write(stream, body)
end

writechunk(stream, body::IO) = writebodystream(stream, body)
writechunk(stream, body) = write(stream, body)

function readbody(stream::Stream, res::Response, redirectlimitreached)
    if isbytes(res.body)
        res.body = read(stream)
    else
        if redirectlimitreached || !isredirect(res)
            write(res.body, stream)
        end
    end
end

end # module StreamRequest
