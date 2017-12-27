module HTTPStreams

export HTTPStream, readheaders

using ..IOExtras
using ..Parsers
using ..Messages


struct HTTPStream{T <: Message} <: IO
    stream::IO
    message::T
    parser::Parser
    writechunked::Bool
end

function HTTPStream(io::IO, request::Request, parser::Parser)
    writechunked = header(request, "Transfer-Encoding") == "chunked"
    HTTPStream{Response}(io, request.response, parser, writechunked)
end


function Base.unsafe_write(http::HTTPStream, p::Ptr{UInt8}, n::UInt)
    if !http.writechunked
        return unsafe_write(http.stream, p, n) 
    end
    return write(http.stream, hex(n), "\r\n") +
           unsafe_write(http.stream, p, n) + 
           write(http.stream, "\r\n")
end


writeend(http) = http.writechunked ? write(http.stream, "0\r\n\r\n") : 0


function Messages.readheaders(http::HTTPStream)
    writeend(http)
    closewrite(http.stream)
    configure_parser(http)
    return readheaders(http.stream, http.parser, http.message)
end


function configure_parser(http::HTTPStream{Response})
    reset!(http.parser)
    if http.message.request.method in ("HEAD", "CONNECT")
        setnobody(http.parser)
    end
end

configure_parser(http::HTTPStream{Request}) = reset!(http.parser)


function Base.eof(http::HTTPStream)
    if !headerscomplete(http.message)
        readheaders(http)
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
    if !headerscomplete(http.message)
        throw(ArgumentError("headers must be read before body\n$http\n"))
    end
    if bodycomplete(http.parser)
        throw(ArgumentError("message body already complete\n$http\n"))
    end
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


function Base.close(http::HTTPStream{Response})
    while !eof(http)
        readavailable(http)
    end

    if bodycomplete(http.parser) && !messagecomplete(http.parser)
        readtrailers(http.stream, http.parser, http.message)
    end

    if !messagecomplete(http.parser)
        close(http.stream)
        throw(EOFError())
    end

    if connectionclosed(http.parser)
        close(http.stream)
    else
        closeread(http.stream)
    end
    return http.message
end


end #module HTTPStreams
