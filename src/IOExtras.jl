"""
This module defines extensions to the `Base.IO` interface to support:
 - an `unread!` function for pushing excess bytes back into a stream,
 - `startwrite`, `closewrite`, `startread` and `closeread` for streams
    with transactional semantics.
"""

module IOExtras

export bytes, CodeUnits, IOError, isioerror,
       unread!,
       startwrite, closewrite, startread, closeread,
       tcpsocket, localport, peerport


"""
    bytes(s::String)

Get a `Vector{UInt8}`, a vector of bytes of a string.
"""
function bytes end
bytes(s::SubArray{UInt8}) = unsafe_wrap(Array, pointer(s), length(s))
if !isdefined(Base, :CodeUnits)
    const CodeUnits = Vector{UInt8}
    bytes(s::String) = Vector{UInt8}(s)
    bytes(s::SubString{String}) = unsafe_wrap(Array, pointer(s), length(s))
else
    const CodeUnits = Union{Vector{UInt8}, Base.CodeUnits}
    bytes(s::Base.CodeUnits) = bytes(String(s))
    bytes(s::String) = codeunits(s)
    bytes(s::SubString{String}) = codeunits(s)
end
bytes(s::Vector{UInt8}) = s

"""
    isioerror(exception)

Is `exception` caused by a possibly recoverable IO error.
"""

isioerror(e) = false
isioerror(::Base.EOFError) = true
isioerror(::Base.UVError) = true
isioerror(e::ArgumentError) = e.msg == "stream is closed or unusable"


"""
The request terminated with due to an IO-related error.

Fields:
 - `e`, the error.
"""

struct IOError <: Exception
    e
    message
end

Base.show(io::IO, e::IOError) = print(io, "IOError(", e.e, " ", e.message, ")\n")


"""
    unread!(::IO, bytes)

Push bytes back into a connection (to be returned by the next read).
"""


function unread!(io::IOBuffer, bytes)
    l = length(bytes)
    if l == 0
        return
    end

    @assert bytes == io.data[io.ptr - l:io.ptr-1]

    if io.seekable
        seek(io, io.ptr - (l + 1))
        return
    end

    println("WARNING: Can't unread! non-seekable IOBuffer")
    println("         Discarding $(length(bytes)) bytes!")
    @assert false
    return
end


function unread!(io, bytes)
    if length(bytes) == 0
        return
    end
    println("WARNING: No unread! method for $(typeof(io))!")
    println("         Discarding $(length(bytes)) bytes!")
    return
end



start_close_read_write_doc = """
    startwrite(::IO)
    closewrite(::IO)
    startread(::IO)
    closeread(::IO)

Signal start/end of write or read operations.
"""

@doc start_close_read_write_doc -> startwrite(io) = nothing
@doc start_close_read_write_doc -> closewrite(io) = nothing
@doc start_close_read_write_doc -> startread(io) = nothing
@doc start_close_read_write_doc -> closeread(io) = nothing


using MbedTLS: SSLContext
tcpsocket(io::SSLContext)::TCPSocket = io.bio
tcpsocket(io::TCPSocket)::TCPSocket = io

localport(io) = try !isopen(tcpsocket(io)) ? 0 :
                    VERSION > v"0.7.0-DEV" ?
                    getsockname(tcpsocket(io))[2] :
                    Base._sockname(tcpsocket(io), true)[2]
                catch
                    0
                end

peerport(io) = try !isopen(tcpsocket(io)) ? 0 :
                  VERSION > v"0.7.0-DEV" ?
                  getpeername(tcpsocket(io))[2] :
                  Base._sockname(tcpsocket(io), false)[2]
               catch
                   0
               end

end
