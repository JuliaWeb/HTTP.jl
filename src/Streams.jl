module Streams

export Stream, closebody, isaborted,
       header, hasheader,
       setstatus, setheader

import ..HTTP
using ..Sockets
using ..IOExtras
using ..Messages
import ..bytesavailable, ..compat_string
import ..ByteView
import ..Messages: header, hasheader, setheader,
                   writeheaders, writestartline
import ..ConnectionPool: getrawstream, nobytes, ByteView, last_read_info
import ..@require, ..precondition_error
import ..@ensure, ..postcondition_error
import ..@debug, ..DEBUG_LEVEL

mutable struct Stream{M <: Message, S <: IO} <: IO
    message::M
    stream::S
    writechunked::Bool
    readchunked::Bool
    ntoread::Int
end

"""
    Stream(::IO, ::Request)

Creates a `HTTP.Stream` that wraps an existing `IO` stream.

 - `startwrite(::Stream)` sends the `Request` headers to the `IO` stream.
 - `write(::Stream, body)` sends the `body` (or a chunk of the body).
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
    If a complete response has not been recieved, `closeread` throws `EOFError`.
"""
Stream(r::M, io::S) where {M, S} = Stream{M,S}(r, io, false, false, 0)

header(http::Stream, a...) = header(http.message, a...)
setstatus(http::Stream, status) = (http.message.response.status = status)
setheader(http::Stream, a...) = setheader(http.message.response, a...)
getrawstream(http::Stream) = getrawstream(http.stream)

Sockets.getsockname(http::Stream) = Sockets.getsockname(getrawstream(http))

IOExtras.isopen(http::Stream) = isopen(http.stream)

# Writing HTTP Messages

messagetowrite(http::Stream{Response}) = http.message.request
messagetowrite(http::Stream{Request}) = http.message.response

IOExtras.iswritable(http::Stream) = iswritable(http.stream)

function IOExtras.startwrite(http::Stream)
    if !iswritable(http.stream)
        startwrite(http.stream)
    end
    m = messagetowrite(http)
    if !hasheader(m, "Content-Length") &&
       !hasheader(m, "Transfer-Encoding") &&
       !hasheader(m, "Upgrade")
        http.writechunked = true
        setheader(m, "Transfer-Encoding" => "chunked")
    else
        http.writechunked = ischunked(m)
    end
    writeheaders(http.stream, m)
end

function Base.unsafe_write(http::Stream, p::Ptr{UInt8}, n::UInt)
    if n == 0
        return 0
    end
    if !iswritable(http) && isopen(http.stream)
        startwrite(http)
    end
    if !http.writechunked
        return unsafe_write(http.stream, p, n)
    end
    return write(http.stream, compat_string(n, base=16), "\r\n") +
           unsafe_write(http.stream, p, n) +
           write(http.stream, "\r\n")
end

"""
    closebody(::Stream)

Write the final `0` chunk if needed.
"""
function closebody(http::Stream)
    if http.writechunked
        http.writechunked = false
        write(http.stream, "0\r\n\r\n")
    end
end

function IOExtras.closewrite(http::Stream{Response})
    if !iswritable(http)
        return
    end
    closebody(http)
    closewrite(http.stream)
end

function IOExtras.closewrite(http::Stream{Request})

    if iswritable(http)
        closebody(http)
        closewrite(http.stream)
    end

    if hasheader(http.message, "Connection", "close") ||
       hasheader(http.message, "Connection", "upgrade") ||
       http.message.version < v"1.1" &&
      !hasheader(http.message, "Connection", "keep-alive")

        @debug 1 "✋  \"Connection: close\": $(http.stream)"
        close(http.stream)
    end
end

# Reading HTTP Messages

IOExtras.isreadable(http::Stream) = isreadable(http.stream)

function IOExtras.startread(http::Stream)

    if !isreadable(http.stream)
        startread(http.stream)
    end

    readheaders(http.stream, http.message)
    handle_continue(http)

    http.readchunked = ischunked(http.message)
    http.ntoread = bodylength(http.message)

    return http.message
end

"""
100 Continue
https://tools.ietf.org/html/rfc7230#section-5.6
https://tools.ietf.org/html/rfc7231#section-6.2.1
"""
function handle_continue(http::Stream{Response})
    if http.message.status == 100
        @debug 1 "✅  Continue:   $(http.stream)"
        readheaders(http.stream, http.message)
    end
end

function handle_continue(http::Stream{Request})
    if hasheader(http.message, "Expect", "100-continue")
        if !iswritable(http.stream)
            startwrite(http.stream)
        end
        @debug 1 "✅  Continue:   $(http.stream)"
        writeheaders(http.stream, Response(100))
    end
end

function Base.eof(http::Stream)
    if !headerscomplete(http.message)
        startread(http)
    end
    if http.ntoread == 0
        return true
    end
    if eof(http.stream)
        return true
    end
    return false
end

function Base.readavailable(http::Stream)::ByteView
    @require headerscomplete(http.message)

    # Find length of next chunk
    if http.ntoread == unknown_length && http.readchunked
        http.ntoread = readchunksize(http.stream, http.message)
        if http.ntoread > 0
            http.ntoread += 2 # expect CRLF after chunk-data
        end
    end

    if http.ntoread == 0
        return nobytes
    end

    # Read bytes from stream and update ntoread
    bytes = read(http.stream, http.ntoread)
    if http.ntoread != unknown_length
        http.ntoread -= length(bytes)
    end

    # Ignore CRLF at end of chunk-data
    if http.readchunked
        if http.ntoread < 2
            l = length(bytes) + http.ntoread - 2
            bytes = view(bytes, 1:l)
        end
        if http.ntoread == 0
            http.ntoread = unknown_length
        end
    end

    @ensure http.ntoread >= 0
    return bytes
end

function IOExtras.unread!(http::Stream, excess)

    if http.readchunked && http.ntoread == unknown_length
        # If the whole chunk was read, unread! needs to push
        # back the CRLF that came after the chunk data
        # (See readavailable above).
        excess = view(excess.parent, excess.indexes[1].start:
                                     excess.indexes[1].stop + 2)
        http.ntoread = length(excess)

    elseif http.ntoread != unknown_length
        http.ntoread += length(excess)
    end

    unread!(http.stream, excess)
end

@static if VERSION < v"0.7.0-DEV.2005"

    find_delim(bytes, d::UInt8) = findfirst(x->x==d, bytes)

    Base.readuntil(http::Stream, delim::UInt8) =
        Vector{UInt8}(readuntil(http, bytes->find_delim(bytes, delim)))
                # See readuntil(::IO, ::Function) in IOExtras.jl

else

    find_delim(bytes, d::UInt8) =
        (i = findfirst(isequal(d), bytes)) == nothing ? 0 : i

    function Base.readuntil(http::Stream, delim::UInt8; keep::Bool=false)
        bytes = readuntil(http, bytes->find_delim(bytes, delim))
        if keep == false
            bytes = view(bytes, 1:length(bytes)-1)
        end
        return Vector{UInt8}(bytes)
    end
end

function Base.read(http::Stream)
    buf = IOBuffer()

    wait_for_timeout = Ref{Bool}(true)
    @schedule while wait_for_timeout[]
        sleep(2)
        if wait_for_timeout[]
            println("Waiting to read $(http.ntoread) bytes.",
                    sprint(showcompact, http.message))
            last_read_info()
            @show http.stream
            @show http.readchunked
            @show incomplete(http)
        end
    end
    try
        write(buf, http)
    finally
        wait_for_timeout[] = false
    end
    return take!(buf)
end

"""
    isaborted(::Stream{Response})

Has the server signaled that it does not wish to receive the message body?

"If [the response] indicates the server does not wish to receive the
 message body and is closing the connection, the client SHOULD
 immediately cease transmitting the body and close the connection."
[RFC7230, 6.5](https://tools.ietf.org/html/rfc7230#section-6.5)
"""
function isaborted(http::Stream{Response})

    if iswritable(http.stream) &&
       iserror(http.message) &&
       hasheader(http.message, "Connection", "close")
        @debug 1 "✋  Abort on $(sprint(writestartline, http.message)): " *
                 "$(http.stream)"
        @debug 2 "✋  $(http.message)"
        return true
    end
    return false
end

incomplete(http::Stream) =
    http.ntoread > 0 && (http.readchunked || http.ntoread != unknown_length)

function IOExtras.closeread(http::Stream{Response})

    # Discard body bytes that were not read...
    while !eof(http)
        readavailable(http)
    end

    if incomplete(http)
        # Error if Message is not complete...
        close(http.stream)
        throw(EOFError())
    elseif hasheader(http.message, "Connection", "close")
        # Close conncetion if server sent "Connection: close"...
        @debug 1 "✋  \"Connection: close\": $(http.stream)"
        close(http.stream)
    elseif isreadable(http.stream)
        closeread(http.stream)
    end

    return http.message
end

function IOExtras.closeread(http::Stream{Request})
    if incomplete(http)
        # Error if Message is not complete...
        close(http.stream)
        throw(EOFError())
    end
    if isreadable(http)
        closeread(http.stream)
    end
end

end #module Streams
