module ConnectionRequest

using ..Layers
using URIs, ..Sockets
using ..Messages
using ..IOExtras
using ..ConnectionPool
using MbedTLS: SSLContext, SSLConfig
using ..Pairs: getkv, setkv
using Base64: base64encode
import ..@debug, ..DEBUG_LEVEL

const nosslconfig = SSLConfig()

# hasdotsuffix reports whether s ends in "."+suffix.
hasdotsuffix(s, suffix) = endswith(s, "." * suffix)

function isnoproxy(host)
    for x in NO_PROXY
        (hasdotsuffix(host, x) || (host == x)) && return true
    end
    return false
end

const NO_PROXY = String[]

function __init__()
    # check for no_proxy environment variable
    if haskey(ENV, "no_proxy")
        for x in split(ENV["no_proxy"], ","; keepempty=false)
            push!(NO_PROXY, startswith(x, ".") ? x[2:end] : x)
        end
    end
    return
end

function getproxy(scheme, host)
    isnoproxy(host) && return nothing
    if scheme == "http" && (p = get(ENV, "http_proxy", ""); !isempty(p))
        return p
    elseif scheme == "http" && (p = get(ENV, "HTTP_PROXY", ""); !isempty(p))
        return p
    elseif scheme == "https" && (p = get(ENV, "https_proxy", ""); !isempty(p))
        return p
    elseif scheme == "https" && (p = get(ENV, "HTTPS_PROXY", ""); !isempty(p))
        return p
    end
    return nothing
end

"""
    Layers.request(ConnectionPoolLayer, ::URI, ::Request, body) -> HTTP.Response

Retrieve an `IO` connection from the [`ConnectionPool`](@ref).

Close the connection if the request throws an exception.
Otherwise leave it open so that it can be reused.

`IO` related exceptions from `Base` are wrapped in `HTTP.IOError`.
See [`isioerror`](@ref).
"""
struct ConnectionPoolLayer{Next <: Layer} <: RequestLayer
    next::Next
    proxy::String
    socket_type::Any
    kw
end
export ConnectionPoolLayer
ConnectionPoolLayer(next;
    proxy="",
    socket_type::Type=TCPSocket,
    kw...) = ConnectionPoolLayer(next, proxy, socket_type, kw)

function Layers.request(layer::ConnectionPoolLayer, ctx, req, body)
    proxy = layer.proxy != "" ? layer.proxy : getproxy(req.url.scheme, req.url.host)
    socket_type = layer.socket_type
    if proxy !== nothing
        target_url = req.url
        url = URI(proxy)
        if target_url.scheme == "http"
            req.target = string(target_url)
        end

        userinfo = unescapeuri(url.userinfo)
        if !isempty(userinfo) && getkv(req.headers, "Proxy-Authorization", "") == ""
            @debug 1 "Adding Proxy-Authorization: Basic header."
            setkv(req.headers, "Proxy-Authorization", "Basic $(base64encode(userinfo))")
        end
    else
        url = req.url
    end

    IOType = sockettype(url, socket_type)
    local io
    try
        io = newconnection(IOType, url.host, url.port; layer.kw...)
    catch e
        rethrow(isioerror(e) ? IOError(e, "during request($url)") : e)
    end

    try
        if proxy !== nothing && target_url.scheme == "https"
            # tunnel request
            target_url = URI(target_url, port=443)
            r = connect_tunnel(io, target_url, req)
            if r.status != 200
                close(io)
                return r
            end
            io = ConnectionPool.sslupgrade(io, target_url.host; layer.kw...)
            req.headers = filter(x->x.first != "Proxy-Authorization", req.headers)
        end

        r =  Layers.request(layer.next, ctx, io, req, body)

        if proxy !== nothing && target_url.scheme == "https"
            close(io)
        end

        return r
    catch e
        @debug 1 "❗️  ConnectionLayer $e. Closing: $io"
        try; close(io); catch; end
        rethrow(isioerror(e) ? IOError(e, "during request($url)") : e)
    end

end

sockettype(url::URI, default) = url.scheme in ("wss", "https") ? SSLContext : default

function connect_tunnel(io, target_url, req)
    target = "$(URIs.hoststring(target_url.host)):$(target_url.port)"
    @debug 1 "📡  CONNECT HTTPS tunnel to $target"
    headers = Dict("Host" => target)
    if (auth = header(req, "Proxy-Authorization"); !isempty(auth))
        headers["Proxy-Authorization"] = auth
    end
    request = Request("CONNECT", target, headers)
    writeheaders(io, request)
    readheaders(io, request.response)
    return request.response
end

end # module ConnectionRequest
