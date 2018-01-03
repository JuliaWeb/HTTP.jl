module Connect

export getconnection, getparser, inactiveseconds, getrawstream

using MbedTLS: SSLConfig, SSLContext, setup!, associate!, hostname!, handshake!

import ..Parsers.Parser
import ..@debug, ..DEBUG_LEVEL


"""
    getconnection(type, host, port) -> IO

Create a new `TCPSocket` or `SSLContext` connection.

Note: this `Connect` module creates simple unadorned connection objects.
The `Connections` module has the same interface but supports connection
reuse and request interleaving.
"""

function getconnection(::Type{TCPSocket},
                       host::AbstractString,
                       port::AbstractString;
                       kw...)::TCPSocket

    p::UInt = isempty(port) ? UInt(80) : parse(UInt, port)
    @debug 2 "TCP connect: $host:$p..."
    connect(getaddrinfo(host), p)
end

function getconnection(::Type{SSLContext},
                       host::AbstractString,
                       port::AbstractString;
                       require_ssl_verification::Bool=false,
                       sslconfig::SSLConfig=SSLConfig(require_ssl_verification),
                       kw...)::SSLContext

    port = isempty(port) ? "443" : port
    @debug 2 "SSL connect: $host:$port..."
    io = SSLContext()
    setup!(io, sslconfig)
    associate!(io, getconnection(TCPSocket, host, port))
    hostname!(io, host)
    handshake!(io)
    return io
end

getparser(::IO) = Parser()

getrawstream(io::IO) = io

inactiveseconds(::IO)= Float64(0)

end # module Connect
