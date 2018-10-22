"""
This module defines extensions to the `Base.IO` interface to support:
 - `startwrite`, `closewrite`, `startread` and `closeread` for streams
    with transactional semantics.
"""
module IOExtras

using ..Sockets
using MbedTLS: MbedException

export bytes, ByteView, nobytes, CodeUnits, IOError, isioerror,
       startwrite, closewrite, startread, closeread,
       tcpsocket, localport, peerport


"""
    bytes(s::String)

Get a `Vector{UInt8}`, a vector of bytes of a string.
"""
function bytes end
bytes(s::SubArray{UInt8}) = unsafe_wrap(Array, pointer(s), length(s))

const CodeUnits = Union{Vector{UInt8}, Base.CodeUnits}
bytes(s::Base.CodeUnits) = bytes(String(s))
bytes(s::String) = codeunits(s)
bytes(s::SubString{String}) = codeunits(s)

bytes(s::Vector{UInt8}) = s

"""
    isioerror(exception)

Is `exception` caused by a possibly recoverable IO error.
"""
isioerror(e) = false
isioerror(::Base.EOFError) = true
isioerror(::Base.IOError) = true
isioerror(e::ArgumentError) = e.msg == "stream is closed or unusable"
isioerror(::MbedException) = true


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


_doc = """
    startwrite(::IO)
    closewrite(::IO)
    startread(::IO)
    closeread(::IO)

Signal start/end of write or read operations.
"""
"$_doc"
startwrite(io) = nothing
"$_doc"
closewrite(io) = nothing
"$_doc"
startread(io) = nothing
"$_doc"
closeread(io) = nothing

using MbedTLS: SSLContext
tcpsocket(io::SSLContext)::TCPSocket = io.bio
tcpsocket(io::TCPSocket)::TCPSocket = io

localport(io) = try !isopen(tcpsocket(io)) ? 0 :
                    Sockets.getsockname(tcpsocket(io))[2]
                catch
                    0
                end

peerport(io) = try !isopen(tcpsocket(io)) ? 0 :
                  Sockets.getpeername(tcpsocket(io))[2]
               catch
                   0
               end


const ByteView = typeof(view(UInt8[], 1:0))
const nobytes = view(UInt8[], 1:0)

"""
Read from an `IO` stream until `find_delimiter(bytes)` returns non-zero.
Return view of bytes up to the delimiter.
"""
function Base.readuntil(buf::IOBuffer,
                    find_delimiter::Function #= Vector{UInt8} -> Int =#
                   )::ByteView

    l = find_delimiter(view(buf.data, buf.ptr:buf.size))
    if l == 0
        return nobytes
    end
    bytes = view(buf.data, buf.ptr:buf.ptr + l - 1)
    buf.ptr += l
    return bytes
end

end
