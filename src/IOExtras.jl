"""
This module defines extensions to the `Base.IO` interface to support:
 - an `unread!` function for pushing excess bytes back into a stream,
 - `startwrite`, `closewrite`, `startread` and `closeread` for streams
    with transactional semantics.
"""

module IOExtras

export IOError, isioerror,
       unread!,
       startwrite, closewrite, startread, closeread,
       tcpsocket, localport, peerport

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

struct IOError
    e
end

Base.show(io::IO, e::IOError) = show(io, e.e)


"""
    unread!(::IO, bytes)

Push bytes back into a connection (to be returned by the next read).
"""

function unread!(io, bytes)
    if length(bytes) == 0
        return
    end
    println("WARNING: No unread! method for $(typeof(io))!")
    println("         Discarding $(length(bytes)) bytes!")
    return
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
