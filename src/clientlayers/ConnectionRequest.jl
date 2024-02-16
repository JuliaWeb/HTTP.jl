module ConnectionRequest

using URIs, Sockets, Base64, LoggingExtras, ConcurrentUtilities, ExceptionUnwrapping
using MbedTLS: SSLContext, SSLConfig
using OpenSSL: SSLStream
using ..Messages, ..IOExtras, ..Connections, ..Streams, ..Exceptions
import ..SOCKET_TYPE_TLS

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

Retrieve an `IO` connection from the Connections.

Close the connection if the request throws an exception.
Otherwise leave it open so that it can be reused.
"""
function connectionlayer(handler)
    return function connections(req; proxy=getproxy(req.url.scheme, req.url.host), socket_type::Type=TCPSocket, socket_type_tls::Type=SOCKET_TYPE_TLS[], readtimeout::Int=0, connect_timeout::Int=30, logerrors::Bool=false, logtag=nothing, kw...)
        local io, stream
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
            url = target_url = req.url
        end

        connect_timeout = connect_timeout == 0 && readtimeout > 0 ? readtimeout : connect_timeout
        IOType = sockettype(url, socket_type, socket_type_tls)
        start_time = time()
        try
            io = newconnection(IOType, url.host, url.port; readtimeout=readtimeout, connect_timeout=connect_timeout, kw...)
        catch e
            if logerrors
                @error current_exceptions_to_string() type=Symbol("HTTP.ConnectError") method=req.method url=req.url context=req.context logtag=logtag
            end
            req.context[:connect_errors] = get(req.context, :connect_errors, 0) + 1
            throw(ConnectError(string(url), e))
        finally
            req.context[:connect_duration_ms] = get(req.context, :connect_duration_ms, 0.0) +  (time() - start_time) * 1000
        end

        shouldreuse = !(target_url.scheme in ("ws", "wss"))
        try
            if proxy !== nothing && target_url.scheme in ("https", "wss", "ws")
                shouldreuse = false
                # tunnel request
                if target_url.scheme in ("https", "wss")
                    target_url = URI(target_url, port=443)
                elseif target_url.scheme in ("ws", ) && target_url.port == ""
                    target_url = URI(target_url, port=80) # if there is no port info, connect_tunnel will fail
                end
                r = if readtimeout > 0
                    try_with_timeout(readtimeout) do _
                        connect_tunnel(io, target_url, req)
                    end
                else
                    connect_tunnel(io, target_url, req)
                end
                if r.status != 200
                    close(io)
                    return r
                end
                if target_url.scheme in ("https", "wss")
                    io = Connections.sslupgrade(socket_type_tls, io, target_url.host; readtimeout=readtimeout, kw...)
                end
                req.headers = filter(x->x.first != "Proxy-Authorization", req.headers)
            end

            stream = Stream(req.response, io)
            return handler(stream; readtimeout=readtimeout, logerrors=logerrors, logtag=logtag, kw...)
        catch e
            shouldreuse = false
            # manually unwrap CompositeException since it's not defined as a "wrapper" exception by ExceptionUnwrapping
            while e isa CompositeException
                e = e.exceptions[1]
            end
            root_err = ExceptionUnwrapping.unwrap_exception_to_root(e)
            # don't log if it's an HTTPError since we should have already logged it
            if logerrors && root_err isa StatusError
                @error current_exceptions_to_string() type=Symbol("HTTP.StatusError") method=req.method url=req.url context=req.context logtag=logtag
            end
            if logerrors && !ExceptionUnwrapping.has_wrapped_exception(e, HTTPError)
                @error current_exceptions_to_string() type=Symbol("HTTP.ConnectionRequest") method=req.method url=req.url context=req.context logtag=logtag
            end
            @debugv 1 "❗️  ConnectionLayer $root_err. Closing: $io"
            if @isdefined(stream) && stream.nwritten == -1
                # we didn't write anything, so don't need to worry about
                # idempotency of the request
                req.context[:nothingwritten] = true
            end
            root_err isa HTTPError || throw(RequestError(req, root_err))
            throw(root_err)
        finally
            releaseconnection(io, shouldreuse; kw...)
            if !shouldreuse
                @try Base.IOError close(io)
            end
        end
    end
end

sockettype(url::URI, tcp, tls) = url.scheme in ("wss", "https") ? tls : tcp

function connect_tunnel(io, target_url, req)
    target = "$(URIs.hoststring(target_url.host)):$(target_url.port)"
    @debugv 1 "📡  CONNECT HTTPS tunnel to $target"
    headers = Dict("Host" => target)
    if (auth = header(req, "Proxy-Authorization"); !isempty(auth))
        headers["Proxy-Authorization"] = auth
    end
    request = Request("CONNECT", target, headers)
    # @debugv 2 "connect_tunnel: writing headers"
    writeheaders(io, request)
    # @debugv 2 "connect_tunnel: reading headers"
    readheaders(io, request.response)
    # @debugv 2 "connect_tunnel: done reading headers"
    return request.response
end

end # module ConnectionRequest
