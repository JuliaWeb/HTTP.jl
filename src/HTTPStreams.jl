module HTTPStreams

export HTTPStream

using ..IOExtras
using ..Parsers
using ..Messages
import ..Messages: header, hasheader
import ..ConnectionPool.getrawstream
import ..@require, ..precondition_error


struct HTTPStream{T <: Message} <: IO
    stream::IO
    message::T
    parser::Parser
    writechunked::Bool
end

function HTTPStream(io::IO, request::Request, parser::Parser)
    @require iswritable(io)
    writechunked = header(request, "Transfer-Encoding") == "chunked"
    HTTPStream{Response}(io, request.response, parser, writechunked)
end

header(http::HTTPStream, a...) = header(http.message, a...)
hasheader(http::HTTPStream, a) = header(http.message, a)
getrawstream(http::HTTPStream) = getrawstream(http.stream)


# Writing HTTP Messages

IOExtras.iswritable(http::HTTPStream) = iswritable(http.stream)

function IOExtras.startwrite(http::HTTPStream)
    @require iswritable(http.stream)
    writeheaders(http.stream, http.message.request)
end


function Base.unsafe_write(http::HTTPStream, p::Ptr{UInt8}, n::UInt)
    if !http.writechunked
        return unsafe_write(http.stream, p, n)
    end
    return write(http.stream, hex(n), "\r\n") +
           unsafe_write(http.stream, p, n) +
           write(http.stream, "\r\n")
end


function IOExtras.closewrite(http::HTTPStream)
    if !iswritable(http)
        return
    end
    if http.writechunked
        write(http.stream, "0\r\n\r\n")
    end
    closewrite(http.stream)
end


# Reading HTTP Messages

IOExtras.isreadable(http::HTTPStream) = isreadable(http.stream)

function IOExtras.startread(http::HTTPStream)
    @require !isreadable(http.stream)
    startread(http.stream)
    configure_parser(http)
    return readheaders(http.stream, http.parser, http.message)
end


function configure_parser(http::HTTPStream{Response})
    reset!(http.parser)
    req = http.message.request::Request
    if req.method in ("HEAD", "CONNECT")
        setnobody(http.parser)
    end
end

configure_parser(http::HTTPStream{Request}) = reset!(http.parser)


function Base.eof(http::HTTPStream)
    if !headerscomplete(http.message)
        startread(http)
    end
    if bodycomplete(http.parser)
        return true
    end
    if eof(http.stream)
        seteof(http.parser)
        return true
    end
    return false
end


function Base.readavailable(http::HTTPStream)::ByteView
    @require headerscomplete(http.message)
    @require !bodycomplete(http.parser)

    bytes = readavailable(http.stream)
    if isempty(bytes)
        return nobytes
    end
    bytes, excess = parsebody(http.parser, bytes)
    unread!(http, excess)
    return bytes
end


IOExtras.unread!(http::HTTPStream, excess) = unread!(http.stream, excess)


function Base.read(http::HTTPStream)
    buf = IOBuffer()
    write(buf, http)
    return take!(buf)
end


function IOExtras.closeread(http::HTTPStream{Response})

    # "If [the response] indicates the server does not wish to receive the
    #  message body and is closing the connection, the client SHOULD immediately
    #  cease transmitting the body and close its side of the connection."
    # https://tools.ietf.org/html/rfc7230#section-6.5
    if iswritable(http.stream) &&
       iserror(http.message) &&
       connectionclosed(http.parser)
        @debug 0 "✋  Abort on $(sprint(writestartline, http.message)): " *
                      http.stream
        @debug 1 "✋  $(http.message)"
        close(http.stream)
        return http.message
    end

    # Discard unread body bytes...
    while !eof(http)
        readavailable(http)
    end

    # Read trailers...
    if bodycomplete(http.parser) && !messagecomplete(http.parser)
        readtrailers(http.stream, http.parser, http.message)
    end

    if isreadable(http.stream)
        closeread(http.stream)
    end

    # Error if Message is not complete...
    if !messagecomplete(http.parser)
        close(http.stream)
        throw(EOFError())
    end

    # Close conncetion if server sent "Connection: close"...
    if connectionclosed(http.parser)
        @debug 0 "✋  \"Connection: close\": $(http.stream)"
        close(http.stream)
    end

    return http.message
end


end #module HTTPStreams
