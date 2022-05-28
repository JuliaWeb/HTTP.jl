module StreamRequest

using ..IOExtras
using ..Messages
using ..Streams
import ..ConnectionPool
using ..MessageRequest
import ..RedirectRequest: nredirects
import ..sprintcompact
using LoggingExtras, CodecZlib

export streamlayer

"""
    streamlayer(stream) -> HTTP.Response

Create a [`Stream`](@ref) to send a `Request` and `body` to an `IO`
stream and read the response.

Send the `Request` body in a background task and begins reading the response
immediately so that the transmission can be aborted if the `Response` status
indicates that the server does not wish to receive the message body.
[RFC7230 6.5](https://tools.ietf.org/html/rfc7230#section-6.5).
"""
function streamlayer(stream::Stream; iofunction=nothing, redirect_limit::Int=3, decompress::Bool=true, kw...)::Response
    response = stream.message
    req = response.request
    io = stream.stream
    @debugv 1 sprintcompact(req)
    @debugv 2 "client startwrite"
    startwrite(stream)

    @debugv 2 sprint(show, req)
    if iofunction === nothing && !isbytes(req.body)
        @debugv 2 "$(typeof(req)).body: $(sprintcompact(req.body))"
    end

    write_error = nothing
    try
        @sync begin
            if iofunction === nothing
                @async try
                    writebody(stream, req)
                    @debugv 2 "client closewrite"
                    closewrite(stream)
                catch e
                    write_error = e
                    isopen(io) && try; close(io); catch; end
                end
                @debugv 2 "client startread"
                startread(stream)
                readbody(stream, response, redirect_limit == nredirects(req), decompress)
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

    @debugv 2 "client closewrite"
    closewrite(stream)
    @debugv 2 "client closeread"
    closeread(stream)

    @debugv 1 sprintcompact(response)
    @debugv 2 sprint(show, response)

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

function readbody(stream::Stream, res::Response, redirectlimitreached, decompress)
    if isbytes(res.body)
        if decompress && header(res, "Content-Encoding") == "gzip"
            res.body = transcode(GzipDecompressor, read(stream))
        else
            res.body = read(stream)
        end
    else
        if redirectlimitreached || !isredirect(res)
            write(res.body, stream)
        end
    end
end

end # module StreamRequest
