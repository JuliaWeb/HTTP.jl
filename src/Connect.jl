module Connect

export getconnection, readresponse!, unread!, closeread, closewrite

using MbedTLS: SSLConfig, SSLContext, setup!, associate!, hostname!, handshake!

import ..@debug


"""
    getconnection(type, host, port) -> IO

Create a new `TCPSocket` or `SSLContext` connection.

Note: this `Connect` module creates simple unadorned connection objects
and provides stubs for the `unread!` `closewrite` and `closeread` functions.
The `Connections` module has the same interface but supports connection
reuse and request interleaving.
"""

function getconnection(::Type{TCPSocket}, host::String, port::UInt)
    @debug 2 "TCP connect: $host:$port..."
    connect(getaddrinfo(host), port)
end

function getconnection(::Type{SSLContext}, host::String, port::UInt)
    @debug 2 "SSL connect: $host:$port..."
    io = SSLContext()
    setup!(io, SSLConfig(false))
    associate!(io, getconnection(TCPSocket, host, port))
    hostname!(io, host)
    handshake!(io)
    return io
end


"""
    unread!(::Connection, bytes)

Push bytes back into a connection (to be returned by the next read).
"""

function unread!(io, bytes)
    println("WARNING: No unread! method for $(typeof(io))!")
    println("         Discarding $(length(bytes)) bytes!")
end


"""
    closewrite(::Connection)
    closeread(::Connection)

Signal end of write or read operations.
"""

closewrite(io) = nothing
closeread(io) = close(io)



end # module Connect
