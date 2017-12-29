module ConnectionRequest

import ..Layer, ..request
using ..URIs
using ..Messages
using ..ConnectionPool
using MbedTLS.SSLContext
import ..@debug, ..DEBUG_LEVEL


abstract type ConnectionPoolLayer{Next <: Layer} <: Layer end
export ConnectionPoolLayer


sockettype(uri::URI) = uri.scheme == "https" ? SSLContext : TCPSocket


"""
    request(ConnectionLayer{Connection, Next}, ::URI, ::Request, ::Response)

Get a `Connection` for a `URI`, send a `Request` and fill in a `Response`.
"""

function request(::Type{ConnectionPoolLayer{Next}}, uri::URI, req, body;
                 connectionpool::Bool=true, kw...) where Next

    Connection = sockettype(uri)
    if connectionpool
        Connection = ConnectionPool.Connection{Connection}
    end
    io = getconnection(Connection, uri.host, uri.port; kw...)

    try
        return request(Next, io, req, body; kw...)
    catch e
        @debug 1 "❗️  ConnectionLayer $e. Closing: $io"
        close(io)
        rethrow(e)
    end
end


end # module ConnectionRequest
