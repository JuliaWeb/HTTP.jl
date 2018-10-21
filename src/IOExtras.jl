"""
This module defines extensions to the `Base.IO` interface to support:
 - an `unread!` function for pushing excess bytes back into a stream,
 - `startwrite`, `closewrite`, `startread` and `closeread` for streams
    with transactional semantics.
"""
module IOExtras

using ..Sockets
using MbedTLS: MbedException

export bytes, ByteView, CodeUnits, IOError, isioerror,
       unread!,
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

end


const ByteView = typeof(view(UInt8[], 1:0))

const readuntil_block_size = 4096

"""
Read from an `IO` stream until `find_delimiter(bytes)` returns non-zero.
Return view of bytes up to the delimiter.
"""
function Base.readuntil(io::IO,
                        find_delimiter::Function #= Vector{UInt8} -> Int =#
                       )::ByteView

    # Fast path, buffer already contains delimiter...
    if !eof(io)
        bytes = read(io, readuntil_block_size)
        if (l = find_delimiter(bytes)) > 0
            if l < length(bytes)
                unread!(io, view(bytes, l+1:length(bytes)))
            end
            return view(bytes, 1:l)
        end

        # Otherwise, wait for delimiter...
        buf = Vector{UInt8}(bytes)
        while !eof(io)
            bytes = read(io, readuntil_block_size)
            append!(buf, bytes)
            if (l = find_delimiter(buf)) > 0
                if l < length(buf)
                    n = length(buf) - l
                    bl = length(bytes)
                    unread!(io, view(bytes, 1+bl-n:bl))
                end
                return view(buf, 1:l)
            end
        end
    end

    throw(EOFError())
end
