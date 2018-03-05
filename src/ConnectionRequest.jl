module ConnectionRequest

import ..Layer, ..request
using ..URIs, ..Sockets
using ..Messages
using ..IOExtras
using ..ConnectionPool
using MbedTLS: SSLContext
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

function request(::Type{ConnectionPoolLayer{Next}}, url::URI, req, body;
                 socket_type::Type=TCPSocket, kw...) where Next

    IOType = ConnectionPool.Transaction{sockettype(url, socket_type)}
    io = getconnection(IOType, url.host, url.port; kw...)

    try
        return request(Next, io, req, body; kw...)
    catch e
        @debug 1 "❗️  ConnectionLayer $e. Closing: $io"
        close(io)
        rethrow(isioerror(e) ? IOError(e, "during request($url)") : e)
    end
end

sockettype(url::URI, default) = url.scheme in ("wss", "https") ? SSLContext : default

end # module ConnectionRequest
