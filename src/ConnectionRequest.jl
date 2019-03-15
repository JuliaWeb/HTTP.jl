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
                 proxy=nothing,
                 socket_type::Type=TCPSocket,
                 reuse_limit::Int=ConnectionPool.nolimit, kw...) where Next

    if proxy !== nothing
        target_url = url
        url = URI(proxy)
        if target_url.scheme == "http"
            req.target = string(target_url)
        end
    end

    IOType = ConnectionPool.Transaction{sockettype(url, socket_type)}
    local io
    try
        io = getconnection(IOType, url.host, url.port;
                           reuse_limit=reuse_limit, kw...)
    catch e
        rethrow(isioerror(e) ? IOError(e, "during request($url)") : e)
    end

    if io.sequence >= reuse_limit
        defaultheader!(req, "Connection" => "close")
    end

    try
        if proxy !== nothing && target_url.scheme == "https"
            return tunnel_request(Next, io, target_url, req, body; kw...)
        end

        return request(Next, io, req, body; kw...)

    catch e
        @debug 1 "❗️  ConnectionLayer $e. Closing: $io"
        close(io)
        rethrow(isioerror(e) ? IOError(e, "during request($url)") : e)
    finally
        if (io.sequence >= reuse_limit
        || (proxy !== nothing && target_url.scheme == "https"))
            close(io)
        end
    end

end

sockettype(url::URI, default) = url.scheme in ("wss", "https") ? SSLContext :
                                                                 default

function tunnel_request(Next, io, target_url, req, body; kw...)
    r = connect_tunnel(io, target_url, req)
    if r.status != 200
        return r
    end
    io = ConnectionPool.sslupgrade(io, target_url.host; kw...)
    req.headers = filter(x->x.first != "Proxy-Authorization", req.headers)
    return request(Next, io, req, body; kw...)
end

function connect_tunnel(io, target_url, req)
    target = "$(URIs.hoststring(target_url.host)):$(target_url.port)"
    @debug 1 "📡  CONNECT HTTPS tunnel to $target"
    headers = Dict(filter(x->x.first == "Proxy-Authorization", req.headers))
    request = Request("CONNECT", target, headers)
    writeheaders(io, request)
    startread(io)
    readheaders(io, request.response)
    return request.response
end


end # module ConnectionRequest
