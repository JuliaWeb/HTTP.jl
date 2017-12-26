module HTTPStreams

export HTTPStream, readheaders, readtrailers

using ..IOExtras
using ..Parsers
using ..Messages


struct HTTPStream{T <: Message} <: IO
    stream::IO
    message::T
    parser::Parser
    chunked::Bool
end

function HTTPStream(io::IO, request::Request, parser::Parser)
    chunked = header(request, "Transfer-Encoding") == "chunked"
    HTTPStream{Response}(io, request.response, parser, chunked)
end


function Base.unsafe_write(http::HTTPStream, p::Ptr{UInt8}, n::UInt)
    if !http.chunked
        return unsafe_write(http.stream, p, n) 
    end
    return write(http.stream, hex(n), "\r\n") +
           unsafe_write(http.stream, p, n) + 
           write(http.stream, "\r\n")
end


writeend(http) = http.chunked ? write(http.stream, "0\r\n\r\n") : 0


function Messages.readheaders(http::HTTPStream)
    writeend(http)
    closewrite(http.stream)
    configure_parser(http)
    return readheaders(http.stream, http.parser, http.message)
end


function configure_parser(http::HTTPStream{Response})
    reset!(http.parser)
    if http.message.request.method in ("HEAD", "CONNECT") # FIXME Why CONNECT?
        setheadresponse(http.parser)
    end
end

configure_parser(http::HTTPStream{Request}) = reset!(http.parser)


readheadersdone(http::HTTPStream) = http.message.status != 0


function Base.eof(http::HTTPStream)
    if !readheadersdone(http)
        readheaders(http)
        @assert readheadersdone(http)
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
    if !headerscomplete(http.parser)
        throw(ArgumentError("headers must be read before body\n$http\n"))
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
    readtrailers(http.stream, http.parser, http.message)

    if !messagecomplete(http.parser)
        @show http.parser
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
