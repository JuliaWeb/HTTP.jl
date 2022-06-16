module ConnectionRequest

using URIs, Sockets, Base64, LoggingExtras
using MbedTLS: SSLContext, SSLConfig
using ..Messages, ..IOExtras, ..ConnectionPool, ..Streams, ..Exceptions

islocalhost(host::AbstractString) = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0000:0000:0000:0000:0000:0000:0000:0001" || host == "0:0:0:0:0:0:0:1"

# hasdotsuffix reports whether s ends in "."+suffix.
hasdotsuffix(s, suffix) = endswith(s, "." * suffix)

function isnoproxy(host::AbstractString)
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
    (isnoproxy(host) || islocalhost(host)) && return nothing
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

export connectionlayer

"""
    connectionlayer(handler) -> handler

Retrieve an `IO` connection from the [`ConnectionPool`](@ref).

Close the connection if the request throws an exception.
Otherwise leave it open so that it can be reused.
"""
function connectionlayer(handler)
    return function(req; proxy=getproxy(req.url.scheme, req.url.host), socket_type::Type=TCPSocket, kw...)
        if proxy !== nothing
            target_url = req.url
            url = URI(proxy)
            if target_url.scheme == "http"
                req.target = string(target_url)
            end

            userinfo = unescapeuri(url.userinfo)
            if !isempty(userinfo) && !hasheader(req.headers, "Proxy-Authorization")
                @debugv 1 "Adding Proxy-Authorization: Basic header."
                setheader(req.headers, "Proxy-Authorization" => "Basic $(base64encode(userinfo))")
            end
        else
            url = req.url
        end

        IOType = sockettype(url, socket_type)
        local io
        try
            io = newconnection(IOType, url.host, url.port; kw...)
        catch e
            throw(ConnectError(string(url), e))
        end

        try
            if proxy !== nothing && target_url.scheme in ("https", "wss", "ws")
                # tunnel request
                if target_url.scheme in ("https", "wss")
                    target_url = merge(target_url, port=443)
                elseif target_url.scheme in ("ws", ) && target_url.port == ""
                    target_url = merge(target_url, port=80) # if there is no port info, connect_tunnel will fail
                end
                r = connect_tunnel(io, target_url, req)
                if r.status != 200
                    close(io)
                    return r
                end
                if target_url.scheme in ("https", "wss")
                    io = ConnectionPool.sslupgrade(io, target_url.host; kw...)
                end
                req.headers = filter(x->x.first != "Proxy-Authorization", req.headers)
            end

            stream = Stream(req.response, io)
            resp = handler(stream; kw...)

            if proxy !== nothing && target_url.scheme in ("https", "wss")
                close(io)
            end

            return resp
        catch e
            @debugv 1 "❗️  ConnectionLayer $e. Closing: $io"
            @try close(io)
            e isa HTTPError || throw(RequestError(req, e))
            rethrow(e)
        end
    end
end

sockettype(url::URI, default) = url.scheme in ("wss", "https") ? SSLContext : default

function connect_tunnel(io, target_url, req)
    target = "$(URIs.hoststring(target_url.host)):$(target_url.port)"
    @debugv 1 "📡  CONNECT HTTPS tunnel to $target"
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
