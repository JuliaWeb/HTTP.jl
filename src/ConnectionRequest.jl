module ConnectionRequest

import ..Layer, ..RequestStack.request
using ..URIs
using ..Messages
using ..Connect
using MbedTLS.SSLContext


abstract type ConnectionLayer{Connection, Next <: Layer} <: Layer end
export ConnectionLayer


"""
    request(ConnectionLayer{Connection, Next}, ::URI, ::Request, ::Response)

Get a `Connection` for a `URI`, send a `Request` and fill in a `Response`.
"""

function request(::Type{ConnectionLayer{Connection, Next}},
                 uri::URI, req::Request, res::Response;
                 kw...) where Next where Connection

    Socket = uri.scheme == "https" ? SSLContext : TCPSocket

    io = getconnection(Connection{Socket}, uri.host, uri.port; kw...)

    return request(Next, io, req, res)
end

# If no `Connection` wrapper type is provided, `Union` acts as a no-op.
request(::Type{ConnectionLayer{Next}}, a...; kw...) where Next <: Layer = 
    request(ConnectionLayer{Union, Next}, a...; kw...)


end # module ConnectionRequest
