module Connect

export getconnection

using MbedTLS: SSLConfig, SSLContext, setup!, associate!, hostname!, handshake!

import ..@debug


"""
    getconnection(type, host, port) -> IO

Create a new `TCPSocket` or `SSLContext` connection.

Note: this `Connect` module creates simple unadorned connection objects.
The `Connections` module has the same interface but supports connection
reuse and request interleaving.
"""

function getconnection(::Type{TCPSocket}, host::AbstractString, port::UInt)::TCPSocket
    @debug 2 "TCP connect: $host:$port..."
    connect(getaddrinfo(host), port)
end

function getconnection(::Type{SSLContext}, host::AbstractString, port::UInt)::SSLContext
    @debug 2 "SSL connect: $host:$port..."
    io = SSLContext()
    setup!(io, SSLConfig(false))
    associate!(io, getconnection(TCPSocket, host, port))
    hostname!(io, host)
    handshake!(io)
    return io
end


end # module Connect
