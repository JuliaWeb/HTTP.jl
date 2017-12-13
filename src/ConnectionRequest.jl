module ConnectionRequest

import ..Layer, ..RequestStack.request
using ..URIs
using ..Messages
using ..ConnectionPool
using MbedTLS.SSLContext


abstract type ConnectionPoolLayer{Next <: Layer} <: Layer end
export ConnectionPoolLayer


sockettype(uri::URI) = uri.scheme == "https" ? SSLContext : TCPSocket


"""
    request(ConnectionLayer{Connection, Next}, ::URI, ::Request, ::Response)

Get a `Connection` for a `URI`, send a `Request` and fill in a `Response`.
"""

function request(::Type{ConnectionPoolLayer{Next}},
                 uri::URI, req::Request, res::Response; kw...) where Next

    Connection = ConnectionPool.Connection{sockettype(uri)}
    io = getconnection(Connection, uri.host, uri.port; kw...)

    return request(Next, io, req, res)
end


abstract type ConnectLayer{Next <: Layer} <: Layer end
export ConnectLayer

function request(::Type{ConnectLayer{Next}},
                 uri::URI, req::Request, res::Response; kw...) where Next

    io = getconnection(sockettype(uri), uri.host, uri.port; kw...)

    return request(Next, io, req, res)
end


end # module ConnectionRequest
