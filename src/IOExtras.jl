"""
    IOExtras

This module defines extensions to the `Base.IO` interface to support:
 - `startwrite`, `closewrite`, `startread` and `closeread` for streams
    with transactional semantics.
"""
module IOExtras

using Sockets
using MbedTLS: SSLContext, MbedException
using OpenSSL: SSLStream

export bytes, isbytes, nbytes, nobytes,
       startwrite, closewrite, startread, closeread, readuntil,
       tcpsocket, localport, safe_getpeername

"""
    bytes(x)

If `x` is "castable" to an `AbstractVector{UInt8}`, then an
`AbstractVector{UInt8}` is returned; otherwise `x` is returned.
"""
function bytes end
bytes(s::AbstractVector{UInt8}) = s
bytes(s::AbstractString) = codeunits(s)
bytes(x) = x

"""whether `x` is "castable" to an `AbstractVector{UInt8}`; i.e. you can call `bytes(x)` if `isbytes(x)` === true"""
isbytes(x) = x isa AbstractVector{UInt8} || x isa AbstractString

"""
    nbytes(x) -> Int

Length in bytes of `x` if `x` is `isbytes(x)`.
"""
function nbytes end
nbytes(x) = nothing
nbytes(x::AbstractVector{UInt8}) = length(x)
nbytes(x::AbstractString) = sizeof(x)
nbytes(x::Vector{T}) where T <: AbstractString = sum(sizeof, x)
nbytes(x::Vector{T}) where T <: AbstractVector{UInt8} = sum(length, x)
nbytes(x::IOBuffer) = bytesavailable(x)
nbytes(x::Vector{IOBuffer}) = sum(bytesavailable, x)

_doc = """
    startwrite(::IO)
    closewrite(::IO)
    startread(::IO)
    closeread(::IO)

Signal start/end of write or read operations.
"""
@static if isdefined(Base, :startwrite)
    "$_doc"
    Base.startwrite(io) = nothing
else
    "$_doc"
    startwrite(io) = nothing
end

@static if isdefined(Base, :closewrite)
    "$_doc"
    Base.closewrite(io) = nothing
else
    "$_doc"
    closewrite(io) = nothing
end

@static if isdefined(Base, :startread)
    "$_doc"
    Base.startread(io) = nothing
else
    "$_doc"
    startread(io) = nothing
end

@static if isdefined(Base, :closeread)
    "$_doc"
    Base.closeread(io) = nothing
else
    "$_doc"
    closeread(io) = nothing
end

tcpsocket(io::SSLContext)::TCPSocket = io.bio
tcpsocket(io::SSLStream)::TCPSocket = io.io
tcpsocket(io::TCPSocket)::TCPSocket = io

localport(io) = try !isopen(tcpsocket(io)) ? 0 :
                    Sockets.getsockname(tcpsocket(io))[2]
                catch
                    0
                end

function safe_getpeername(io)
    try
        if isopen(tcpsocket(io))
            return Sockets.getpeername(tcpsocket(io))
        end
    catch
    end
    return IPv4(0), UInt16(0)
end


const nobytes = view(UInt8[], 1:0)

readuntil(args...) = Base.readuntil(args...)

"""
Read from an `IO` stream until `find_delimiter(bytes)` returns non-zero.
Return view of bytes up to the delimiter.
"""
function readuntil(buf::IOBuffer,
                   find_delimiter::F #= Vector{UInt8} -> Int =#
                   ) where {F <: Function}
    l = find_delimiter(view(buf.data, buf.ptr:buf.size))
    if l == 0
        return nobytes
    end
    bytes = view(buf.data, buf.ptr:buf.ptr + l - 1)
    buf.ptr += l
    return bytes
end

end
