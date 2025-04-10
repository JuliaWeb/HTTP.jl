module Tunnel

export newtunnelconnection

using Sockets, LoggingExtras, NetworkOptions, URIs
using ConcurrentUtilities: acquire, try_with_timeout

using ..Connections, ..Messages, ..Exceptions
using ..Connections: connection_limit_warning, getpool, getconnection, sslconnection, connectionkey, connection_isvalid

function newtunnelconnection(;
        target_type::Type{<:IO},
        target_host::AbstractString,
        target_port::AbstractString,
        proxy_type::Type{<:IO},
        proxy_host::AbstractString,
        proxy_port::AbstractString,
        proxy_auth::AbstractString="",
        pool::Union{Nothing, Pool}=nothing,
        connection_limit=nothing,
        forcenew::Bool=false,
        idle_timeout=typemax(Int),
        connect_timeout::Int=30,
        readtimeout::Int=30,
        keepalive::Bool=true,
        kw...)
    connection_limit_warning(connection_limit)

    if isempty(target_port)
        target_port = istcptype(target_type) ? "80" : "443"
    end

    require_ssl_verification = get(kw, :require_ssl_verification, NetworkOptions.verify_host(target_host, "SSL"))
    host_key = proxy_host * "/" * target_host
    port_key = proxy_port * "/" * target_port
    key = (host_key, port_key, require_ssl_verification, keepalive, true)

    return acquire(
            getpool(pool, target_type),
            key;
            forcenew=forcenew,
            isvalid=c->connection_isvalid(c, Int(idle_timeout))) do

        conn = Connection(host_key, port_key, idle_timeout, require_ssl_verification, keepalive,
            try_with_timeout0(connect_timeout) do _
                getconnection(proxy_type, proxy_host, proxy_port; keepalive, kw...)
            end
        )
        try
            try_with_timeout0(readtimeout) do _
                connect_tunnel(conn, target_host, target_port, proxy_auth)
            end

            if !istcptype(target_type)
                tls = try_with_timeout0(readtimeout) do _
                    sslconnection(target_type, conn.io, target_host; keepalive, kw...)
                end

                # success, now we turn it into a new Connection
                conn = Connection(host_key, port_key, idle_timeout, require_ssl_verification, keepalive, tls)
            end

            @assert connectionkey(conn) === key

            conn
        catch ex
            close(conn)
            rethrow()
        end
    end
end

function connect_tunnel(io, target_host, target_port, proxy_auth)
    target = "$(URIs.hoststring(target_host)):$(target_port)"
    @debug "📡  CONNECT HTTPS tunnel to $target"
    headers = Dict("Host" => target)
    if (!isempty(proxy_auth))
        headers["Proxy-Authorization"] = proxy_auth
    end
    request = Request("CONNECT", target, headers)
    # @debug "connect_tunnel: writing headers"
    writeheaders(io, request)
    # @debug "connect_tunnel: reading headers"
    readheaders(io, request.response)
    # @debug "connect_tunnel: done reading headers"
    if request.response.status != 200
        throw(StatusError(request.response.status,
              request.method, request.target, request.response))
    end
end

"""
Wrapper to try_with_timeout that optionally disables the timeout if given a non-positive duration.
"""
function try_with_timeout0(f, timeout, ::Type{T}=Any) where {T}
    if timeout > 0
        try_with_timeout(f, timeout, T)
    else
        f(Ref(false)) # `f` may check its argument to see if the timeout was reached.
    end
end

istcptype(::Type{TCPSocket}) = true
istcptype(::Type{<:IO}) = false

end # module Tunnel
