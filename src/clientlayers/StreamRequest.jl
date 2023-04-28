module StreamRequest

using ..IOExtras, ..Messages, ..Streams, ..Connections, ..Strings, ..RedirectRequest, ..Exceptions
using LoggingExtras, CodecZlib, URIs
using SimpleBufferStream: BufferStream

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
function streamlayer(stream::Stream; iofunction=nothing, decompress::Union{Nothing, Bool}=nothing, logerrors::Bool=false, logtag=nothing, timedout=nothing, kw...)::Response
    response = stream.message
    req = response.request
    @debugv 1 sprintcompact(req)
    @debugv 2 "client startwrite"
    write_start = time()
    startwrite(stream)

    @debugv 2 sprint(show, req)
    if iofunction === nothing && !isbytes(req.body)
        @debugv 2 "$(typeof(req)).body: $(sprintcompact(req.body))"
    end

    try
        @sync begin
            if iofunction === nothing
                Threads.@spawn try
                    writebody(stream, req)
                finally
                    req.context[:write_duration_ms] = get(req.context, :write_duration_ms, 0.0) + ((time() - write_start) * 1000)
                    @debugv 2 "client closewrite"
                    closewrite(stream)
                end
                read_start = time()
                Threads.@spawn try
                    @debugv 2 "client startread"
                    startread(stream)
                    if !isaborted(stream)
                        readbody(stream, response, decompress)
                    end
                finally
                    req.context[:read_duration_ms] = get(req.context, :read_duration_ms, 0.0) + ((time() - read_start) * 1000)
                    @debugv 2 "client closeread"
                    closeread(stream)
                end
            else
                try
                    iofunction(stream)
                finally
                    closewrite(stream)
                    closeread(stream)
                end
            end
        end
    catch e
        if timedout === nothing || !timedout[]
            req.context[:io_errors] = get(req.context, :io_errors, 0) + 1
            if logerrors
                err = current_exceptions_to_string(CapturedException(e, catch_backtrace()))
                @error err type=Symbol("HTTP.IOError") method=req.method url=req.url context=req.context logtag=logtag
            end
        end
        rethrow()
    end

    @debugv 1 sprintcompact(response)
    @debugv 2 sprint(show, response)
    return response
end

function writebody(stream::Stream, req::Request)
    if !isbytes(req.body)
        n = writebodystream(stream, req.body)
        closebody(stream)
    else
        n = write(stream, req.body)
    end
    stream.message.request.context[:nbytes_written] = n
    return n
end

function writebodystream(stream, body)
    n = 0
    for chunk in body
        n += writechunk(stream, chunk)
    end
    return n
end

function writebodystream(stream, body::IO)
    return write(stream, body)
end

function writebodystream(stream, body::Union{AbstractDict, NamedTuple})
    # application/x-www-form-urlencoded
    return write(stream, URIs.escapeuri(body))
end

writechunk(stream, body::IO) = writebodystream(stream, body)
writechunk(stream, body::Union{AbstractDict, NamedTuple}) = writebodystream(stream, body)
writechunk(stream, body) = write(stream, body)

function readbody(stream::Stream, res::Response, decompress::Union{Nothing, Bool})
    if decompress === true || (decompress === nothing && header(res, "Content-Encoding") == "gzip")
        # Plug in a buffer stream in between so that we can (i) read the http stream in
        # chunks instead of byte-by-byte and (ii) make sure to stop reading the http stream
        # at eof.
        buf = BufferStream()
        gzstream = GzipDecompressorStream(buf)
        tsk = @async begin
            try
                write(gzstream, stream)
            finally
                # Close here to (i) deallocate resources in zlib and (ii) make sure that
                # read(buf)/write(..., buf) below don't block forever. Note that this will
                # close the stream wrapped by the decompressor (buf) but *not* the http
                # stream, which should be left open.
                close(gzstream)
            end
        end
        readbody!(stream, res, buf)
        wait(tsk)
    else
        readbody!(stream, res, stream)
    end
end

# 2 most common types of IOBuffers
const IOBuffers = Union{IOBuffer, Base.GenericIOBuffer{SubArray{UInt8, 1, Vector{UInt8}, Tuple{UnitRange{Int64}}, true}}}

function readbody!(stream::Stream, res::Response, buf_or_stream)
    n = 0
    if !iserror(res)
        if isbytes(res.body)
            if length(res.body) > 0
                # user-provided buffer to read response body into
                # specify write=true to make the buffer writable
                # but also specify maxsize, which means it won't be grown
                # (we don't want to be changing the user's buffer for them)
                body = IOBuffer(res.body; write=true, maxsize=length(res.body))
                if buf_or_stream isa BufferStream
                    # if it's a BufferStream, the response body was gzip encoded
                    # so using the default write is fastest because it utilizes
                    # readavailable under the hood, for which BufferStream is optimized
                    n = write(body, buf_or_stream)
                elseif buf_or_stream isa Stream{Response}
                    # for HTTP.Stream, there's already an optimized read method
                    # that just needs an IOBuffer to write into
                    n = readall!(buf_or_stream, body)
                else
                    error("unreachable")
                end
            else
                res.body = read(buf_or_stream)
                n = length(res.body)
            end
        elseif res.body isa Base.GenericIOBuffer && buf_or_stream isa Stream{Response}
            # optimization for IOBuffer response_stream to avoid temporary allocations
            n = readall!(buf_or_stream, res.body)
        else
            n = write(res.body, buf_or_stream)
        end
    else
        # read the response body into the request context so that it can be
        # read by the user if they want to or set later if
        # we end up not retrying/redirecting/etc.
        res.request.context[:response_body] = read(buf_or_stream)
    end
    res.request.context[:nbytes] = n
end

end # module StreamRequest
