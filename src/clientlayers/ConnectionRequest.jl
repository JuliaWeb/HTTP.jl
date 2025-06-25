module ConnectionRequest

using URIs, Sockets, Base64, ConcurrentUtilities, ExceptionUnwrapping
import MbedTLS
import OpenSSL
using ..Messages, ..IOExtras, ..Connections, ..Streams, ..Exceptions, ..Tunnel
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

const CLOSE_IMMEDIATELY = Ref{Bool}(false)

"""
    connectionlayer(handler) -> handler

Retrieve an `IO` connection from the Connections.

Close the connection if the request throws an exception.
Otherwise leave it open so that it can be reused.
"""
function connectionlayer(handler)
    return function connections(req; proxy=getproxy(req.url.scheme, req.url.host), socket_type::Type=TCPSocket, socket_type_tls::Union{Nothing, Type}=nothing, readtimeout::Int=0, connect_timeout::Int=30, logerrors::Bool=false, logtag=nothing, closeimmediately::Bool=CLOSE_IMMEDIATELY[], kw...)
        local io, stream
        if proxy !== nothing
            target_url = req.url
            url = URI(proxy)
            if target_url.scheme == "http"
                req.target = string(target_url)
            end

            userinfo = unescapeuri(url.userinfo)
            if !isempty(userinfo) && !hasheader(req.headers, "Proxy-Authorization")
                @debug "Adding Proxy-Authorization: Basic header."
                setheader(req.headers, "Proxy-Authorization" => "Basic $(base64encode(userinfo))")
            end
        else
            url = target_url = req.url
        end

        connect_timeout = connect_timeout == 0 && readtimeout > 0 ? readtimeout : connect_timeout
        IOType = sockettype(url, socket_type, socket_type_tls, get(kw, :sslconfig, nothing))
        start_time = time()
        try
            if !isnothing(proxy) && req.url.scheme in ("https", "wss", "ws")
                target_IOType = sockettype(target_url, socket_type, socket_type_tls, get(kw, :sslconfig, nothing))

                io = newtunnelconnection(;
                    target_type=target_IOType,
                    target_host=target_url.host,
                    target_port=target_url.port,
                    proxy_type=IOType,
                    proxy_host=url.host,
                    proxy_port=url.port,
                    proxy_auth=header(req, "Proxy-Authorization"),
                    connect_timeout,
                    readtimeout,
                    kw...
                )

                req.headers = filter(x->x.first != "Proxy-Authorization", req.headers)
            else
                io = newconnection(IOType, url.host, url.port; readtimeout=readtimeout, connect_timeout=connect_timeout, kw...)
            end
        catch e
            if e isa StatusError
                return e.response
            end

            if logerrors
                @error current_exceptions_to_string() type=Symbol("HTTP.ConnectError") method=req.method url=req.url context=req.context logtag=logtag
            end
            req.context[:connect_errors] = get(req.context, :connect_errors, 0) + 1
            throw(ConnectError(string(url), e))
        finally
            req.context[:connect_duration_ms] = get(req.context, :connect_duration_ms, 0.0) +  (time() - start_time) * 1000
        end

        shouldreuse = !(target_url.scheme in ("ws", "wss")) && !closeimmediately
        try
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
            @debug "❗️  ConnectionLayer $root_err. Closing: $io"
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

function sockettype(url::URI, socket_type_tcp, socket_type_tls, sslconfig)
    if url.scheme in ("wss", "https")
        tls_socket_type(socket_type_tls, sslconfig)
    else
        socket_type_tcp
    end
end

"""
    tls_socket_type(socket_type_tls, sslconfig)::Type

Find the best TLS socket type, given the values of these keyword arguments.

If both are `nothing` then we use the global default: `HTTP.SOCKET_TYPE_TLS[]`.
If both are not `nothing` then they must agree:
`sslconfig` must be of the right type to configure `socket_type_tls` or we throw an `ArgumentError`.
"""
function tls_socket_type(socket_type_tls::Union{Nothing, Type},
                         sslconfig::Union{Nothing, MbedTLS.SSLConfig, OpenSSL.SSLContext}
                         )::Type

    socket_type_matching_sslconfig =
        if sslconfig isa MbedTLS.SSLConfig
            MbedTLS.SSLContext
        elseif sslconfig isa OpenSSL.SSLContext
            OpenSSL.SSLStream
        else
            nothing
        end

    if socket_type_tls === socket_type_matching_sslconfig
        # Use the global default TLS socket if they're both nothing, or use
        # what they both specify if they're not nothing.
        isnothing(socket_type_tls) ? SOCKET_TYPE_TLS[] : socket_type_tls
    # If either is nothing, use the other one.
    elseif isnothing(socket_type_tls)
        socket_type_matching_sslconfig
    elseif isnothing(socket_type_matching_sslconfig)
        socket_type_tls
    else
        # If they specify contradictory types, throw an error.
        # Error thrown in noinline closure to avoid speed penalty in common case
        @noinline function err(socket_type_tls, sslconfig)
            msg = """
                Incompatible values for keyword args `socket_type_tls` and `sslconfig`:
                    socket_type_tls=$socket_type_tls
                    typeof(sslconfig)=$(typeof(sslconfig))

                Make them match or provide only one of them.
                - the socket type MbedTLS.SSLContext is configured by MbedTLS.SSLConfig
                - the socket type OpenSSL.SSLStream is configured by OpenSSL.SSLContext"""
            throw(ArgumentError(msg))
        end
        err(socket_type_tls, sslconfig)
    end
end

end # module ConnectionRequest
