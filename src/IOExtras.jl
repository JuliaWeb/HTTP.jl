module IOExtras

export unread!, startwrite, closewrite, startread, closeread,
       tcpsocket, localport, peerport

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

function unread!(io::BufferStream, bytes)
    if length(bytes) == 0
        return
    end
    if nb_available(io) > 0
        buf = readavailable(io)
        write(io, bytes)
        write(io, buf)
    else
        write(io, bytes)
    end
    return
end

function unread!(io, bytes)
    if length(bytes) == 0
        return
    end
    println("WARNING: No unread! method for $(typeof(io))!")
    println("         Discarding $(length(bytes)) bytes!")
end



"""
    startwrite(::IO)
    closewrite(::IO)
    startread(::IO)
    closeread(::IO)

Signal start/end of write or read operations.
"""

startwrite(io) = nothing
closewrite(io) = nothing
startread(io) = nothing
closeread(io) = nothing


using MbedTLS.SSLContext
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
