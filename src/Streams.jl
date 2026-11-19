module Streams

export Stream, closebody, isaborted

import ..HTTP
using ..IOExtras
using ..Parsers
using ..Messages
import ..Messages: header, hasheader, writestartline
import ..ConnectionPool.getrawstream
import ..@require, ..precondition_error
import ..@debug, ..DEBUG_LEVEL


mutable struct Stream{T <: Message} <: IO
    stream::IO
    message::T
    parser::Parser
    writechunked::Bool
end


"""
    Stream(::IO, ::Request, ::Parser)

Creates a `HTTP.Stream` that wraps an existing `IO` stream.

 - `startwrite(::Stream)` sends the `Request` headers to the `IO` stream.
 - `write(::Stream, body)` sends the `body` (or a chunk of the bocdy).
 - `closewrite(::Stream)` sends the final `0` chunk (if needed) and calls
   `closewrite` on the `IO` stream. When the `IO` stream is a
   [`HTTP.ConnectionPool.Transaction`](@ref), calling `closewrite` releases
   the [`HTTP.ConnectionPool.Connection`](@ref) back into the pool for use by the
   next pipelined request.

 - `startread(::Stream)` calls `startread` on the `IO` stream then
    reads and parses the `Response` headers.  When the `IO` stream is a
   [`HTTP.ConnectionPool.Transaction`](@ref), calling `startread` waits for other
   pipelined responses to be read from the [`HTTP.ConnectionPool.Connection`](@ref).
 - `eof(::Stream)` and `readavailable(::Stream)` parse the body from the `IO`
    stream.
 - `closeread(::Stream)` reads the trailers and calls `closeread` on the `IO`
    stream.  When the `IO` stream is a [`HTTP.ConnectionPool.Transaction`](@ref),
    calling `closeread` releases the readlock and allows the next pipelined
    response to be read by another `Stream` that is waiting in `startread`.
    If the `Parser` has not recieved a complete response, `closeread` throws
    an `EOFError`.
"""

function Stream(io::IO, request::Request, parser::Parser)
    @require iswritable(io)
    writechunked = header(request, "Transfer-Encoding") == "chunked"
    Stream{Response}(io, request.response, parser, writechunked)
end

header(http::Stream, a...) = header(http.message, a...)
hasheader(http::Stream, a) = header(http.message, a)
getrawstream(http::Stream) = getrawstream(http.stream)


# Writing HTTP Messages

IOExtras.iswritable(http::Stream) = iswritable(http.stream)

function IOExtras.startwrite(http::Stream)
    @require iswritable(http.stream)
    writeheaders(http.stream, http.message.request)
end


function Base.unsafe_write(http::Stream, p::Ptr{UInt8}, n::UInt)
    if !http.writechunked
        return unsafe_write(http.stream, p, n)
    end
    return write(http.stream, hex(n), "\r\n") +
           unsafe_write(http.stream, p, n) +
           write(http.stream, "\r\n")
end

"""
    closebody(::Stream)

Write the final `0` chunk if needed.
"""

function closebody(http::Stream)
    if http.writechunked
        write(http.stream, "0\r\n\r\n")
        http.writechunked = false
    end
end


function IOExtras.closewrite(http::Stream)
    if !iswritable(http)
        return
    end
    closebody(http)
    closewrite(http.stream)
end


# Reading HTTP Messages

IOExtras.isreadable(http::Stream) = isreadable(http.stream)

function IOExtras.startread(http::Stream)
    startread(http.stream)
    configure_parser(http)
    h = readheaders(http.stream, http.parser, http.message)
    if http.message isa Response && http.message.status == 100
        # 100 Continue
        # https://tools.ietf.org/html/rfc7230#section-5.6
        # https://tools.ietf.org/html/rfc7231#section-6.2.1
        @debug 1 "✅  Continue:   $(http.stream)"
        configure_parser(http)
        h = readheaders(http.stream, http.parser, http.message)
    end
    return h

end


function configure_parser(http::Stream{Response})
    reset!(http.parser)
    req = http.message.request::Request
    if req.method in ("HEAD", "CONNECT")
        setnobody(http.parser)
    end
end

configure_parser(http::Stream{Request}) = reset!(http.parser)


function Base.eof(http::Stream)
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


function Base.readavailable(http::Stream)::ByteView
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


IOExtras.unread!(http::Stream, excess) = unread!(http.stream, excess)


function Base.read(http::Stream)
    buf = IOBuffer()
    write(buf, http)
    return take!(buf)
end


"""
    isaborted(::Stream{Response}) 

Has the server signalled that it does not wish to receive the message body?

"If [the response] indicates the server does not wish to receive the
 message body and is closing the connection, the client SHOULD
 immediately cease transmitting the body and close the connection."
[RFC7230, 6.5](https://tools.ietf.org/html/rfc7230#section-6.5)
"""

function isaborted(http::Stream{Response})

    if iswritable(http.stream) &&
       iserror(http.message) &&
       connectionclosed(http.parser)
        @debug 1 "✋  Abort on $(sprint(writestartline, http.message)): " *
                 "$(http.stream)"
        @debug 2 "✋  $(http.message)"
        return true
    end
    return false
end


function IOExtras.closeread(http::Stream{Response})

    # Discard body bytes that were not read...
    while !eof(http)
        readavailable(http)
    end

    # Read trailers...
    if bodycomplete(http.parser) && !messagecomplete(http.parser)
        readtrailers(http.stream, http.parser, http.message)
    end

    if !messagecomplete(http.parser)
        # Error if Message is not complete...
        close(http.stream)
        throw(EOFError())
    elseif connectionclosed(http.parser)
        # Close conncetion if server sent "Connection: close"...
        @debug 1 "✋  \"Connection: close\": $(http.stream)"
        close(http.stream)
    elseif isreadable(http.stream)
        closeread(http.stream)
    end

    return http.message
end


end #module Streams
