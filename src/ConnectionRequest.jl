module ConnectionRequest

import ..Layer, ..request
using ..URIs
using ..Messages
using ..IOExtras
using ..ConnectionPool
using MbedTLS.SSLContext
import ..@debug, ..DEBUG_LEVEL


"""
    request(ConnectionPoolLayer, ::URI, ::Request, body) -> HTTP.Response

Retrieve an `IO` connection from the [`ConnectionPool`](@ref).

Close the connection if the request throws an exception.
Otherwise leave it open so that it can be reused.

`IO` related exceptions from `Base` are wrapped in `HTTP.IOError`.
See [`isioerror`](@ref).
"""

abstract type ConnectionPoolLayer{Next <: Layer} <: Layer end
export ConnectionPoolLayer

function request(::Type{ConnectionPoolLayer{Next}}, uri::URI, req, body;
                 socket_type::Type=TCPSocket, kw...) where Next

    IOType = ConnectionPool.Transaction{sockettype(uri, socket_type)}
    io = getconnection(IOType, uri.host, uri.port; kw...)

    try
        r = request(Next, io, req, body; kw...)
        return r
    catch e
        @debug 1 "❗️  ConnectionLayer $e. Closing: $io"
        close(io)
        rethrow(isioerror(e) ? IOError(e) : e)
    end
end


sockettype(uri::URI, default) = uri.scheme in ("wss", "https") ? SSLContext :
                                                                 default


end # module ConnectionRequest
