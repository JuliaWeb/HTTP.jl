"""
The `HTTP.Servers` module provides server-side http functionality in pure Julia.

The main entry point is `HTTP.listen(handler, host, port; kw...)` which takes a `handler` argument (see `?HTTP.Handlers`),
a `host` and `port` and optional keyword arguments. For full details, see `?HTTP.listen`.
"""
module Servers

export listen

using ..IOExtras
using ..Streams
using ..Messages
using ..Parsers
using ..ConnectionPool
using Sockets
using MbedTLS
using Dates


# rate limiting
mutable struct RateLimit
    allowance::Float64
    lastcheck::Dates.DateTime
end

function update!(rl::RateLimit, ratelimit)
    current = Dates.now()
    timepassed = float(Dates.value(current - rl.lastcheck)) / 1000.0
    rl.lastcheck = current
    rl.allowance += timepassed * ratelimit
    return nothing
end

const RATE_LIMITS = Dict{IPAddr, RateLimit}()
check_rate_limit(tcp::Base.PipeEndpoint; kw...) = true

"""
`check_rate_limit` takes a new connection (socket), and checks in the global RATE_LIMITS
store for the last time a connection was seen for the same ip address. If the new 
connection has come too soon, it is closed and discarded, otherwise, the timestamp for
the ip address is updated in the global cache.
"""
function check_rate_limit(tcp, ratelimit::Rational{Int})
    ip = Sockets.getsockname(tcp)[1]
    rate = Float64(ratelimit.num)
    rl = get!(RATE_LIMITS, ip, RateLimit(rate, Dates.now()))
    update!(rl, ratelimit)
    if rl.allowance > rate
        @warn "throttling $ip"
        rl.allowance = rate
    end
    if rl.allowance < 1.0
        @warn "discarding connection from $ip due to rate limiting"
        return false
    else
        rl.allowance -= 1.0
    end
    return true
end

# deprecated
function serve(host, port=8081; handler=req->HTTP.Response(200, "Hello World!"),
    ssl::Bool=false, require_ssl_verification::Bool=true, kw...)
    Base.depwarn("`HTTP.serve` is deprecated, use `HTTP.listen(f_or_handler, host, port; kw...)` instead", nothing)
    sslconfig = ssl ? MbedTLS.SSLConfig(require_ssl_verification) : nothing
    return listen(handler, host, port; sslconfig=sslconfig, kw...)
end

"Convenience object for passing around server details"
struct Server2{S, I}
    ssl::S # Union{SSLConfig, Nothing}; Nothing if non-SSL
    server::I
    hostname::String
    hostport::String
end

Base.isopen(s::Server2) = isopen(s.server)
Base.close(s::Server2) = close(s.server)

Sockets.accept(s::Server2{Nothing, S}) where {S} = Sockets.accept(s.server)
Sockets.accept(s::Server2) = getsslcontext(accept(s.server), s.ssl)


function getsslcontext(tcp, sslconfig)
    ssl = MbedTLS.SSLContext()
    MbedTLS.setup!(ssl, sslconfig)
    MbedTLS.associate!(ssl, tcp)
    MbedTLS.handshake!(ssl)
    return ssl
end

"""
    HTTP.listen([host=Sockets.localhost[, port=8081]]; kw...) do req
        ...
    end
    HTTP.listen(handler::HTTP.Handler, host=Sockets.localhost, port=8081; kw...)

Listen for HTTP connections and either execute the `do` function for each request, or dispatch to the
provided `handler`. Both the function or `handler` can accept an `HTTP.Request` object, or a raw
`HTTP.Stream` connection to read & write from directly; for the latter, pass the `stream=true`
keyword argument to operate on the `HTTP.Stream` directly.

Optional keyword arguments:
 - `sslconfig=nothing`: Provide an `MbedTLS.SSLConfig` object to handle ssl connections
 - `reuse_limit = nolimit`, number of times a connection is allowed to be reused
                            after the first request.
 - `tcpisvalid::Function (::TCPSocket) -> Bool`, check accepted connection before
    processing requests. e.g. to implement source IP filtering, rate-limiting,
    etc.
 - `readtimeout::Int=0`: # of seconds to wait on an incoming request before closing a connection
 - `reuseaddr::Bool=false`: whether multiple servers should be allowed to listen on the same port
 - `tcpref::Ref{Base.IOServer}`, this reference is set to the underlying
                                 `IOServer`. e.g. to allow closing the server.
 - `connectioncounter::Ref{Int}`: a `Ref{Int}` that can be used to track the # of currently open (i.e
        currently being handled) connections for a server
 - `ratelimit`: a `Rational{Int}` of the form `5//1` indicating how many `messages//second`
        should be allowed per client IP address; requests exceeding the rate limit will be auto-closed
 - `stream::Bool=false`: whether the handler should operate on an `HTTP.Stream` to read & write directly
 - `verbose::Bool=false`: whether simple logging should print to stdout for connections handled

e.g.
```
    HTTP.listen(; stream=true) do http::HTTP.Stream
        @show http.message
        @show HTTP.header(http, "Content-Type")
        while !eof(http)
            println("body data: ", String(readavailable(http)))
        end
        setstatus(http, 404)
        setheader(http, "Foo-Header" => "bar")
        startwrite(http)
        write(http, "response body")
        write(http, "more response body")
        return
    end

    HTTP.listen() do request::HTTP.Request
        @show HTTP.header(request, "Content-Type")
        @show HTTP.payload(request, String)
        return HTTP.Response(404)
    end
```
"""
function listen end

getinet(host::String, port::Integer) = Sockets.InetAddr(parse(IPAddr, host), port)
getinet(host::IPAddr, port::Integer) = Sockets.InetAddr(host, port)

function listen(h,
                host::Union{IPAddr, String}=Sockets.localhost,
                port::Integer=8081
                ;
                stream::Bool=false,
                sslconfig::Union{MbedTLS.SSLConfig, Nothing}=nothing,
                tcpisvalid::Union{Function, Nothing}=nothing,
                tcpref::Union{Ref, Nothing}=nothing,
                reuseaddr::Bool=false,
                connectioncounter::Ref{Int}=Ref(0),
                ratelimit::Union{Rational{Int}, Nothing}=nothing,
                reuse_limit::Int=1, readtimeout::Int=0,
                verbose::Bool=false)

    # If `h` does not accept a stream wrap it with the stream handling function.
    if !stream
        h = let f = h; http::Stream -> handle(f, http) end
    end

    inet = getinet(host, port)
    if tcpref !== nothing
        tcpserver = tcpref[]
    elseif reuseaddr
        tcpserver = Sockets.TCPServer(; delay=false)
        if Sys.isunix()
            rc = ccall(:jl_tcp_reuseport, Int32, (Ptr{Cvoid},), tcpserver.handle)
            Sockets.bind(tcpserver, inet.host, inet.port; reuseaddr=true)
        else
            @warn "reuseaddr=true may not be supported on this platform: $(Sys.KERNEL)"
            Sockets.bind(tcpserver, inet.host, inet.port; reuseaddr=true)
        end
        Sockets.listen(tcpserver)
    else
        tcpserver = Sockets.listen(inet)
    end
    verbose && @info "Listening on: $host:$port"

    if tcpisvalid === nothing
        tcpisvalid = ratelimit === nothing ? x->true : x->check_rate_limit(x, ratelimit)
    end

    return listenloop(h, Server2(sslconfig, tcpserver, string(host), string(port)), tcpisvalid,
        connectioncounter, reuse_limit, readtimeout, verbose)
end

"main server loop that accepts new tcp connections and spawns async threads to handle them"
function listenloop(h, server,
    tcpisvalid=x->true, connectioncounter=Ref(0),
    reuse_limit::Int=1, readtimeout::Int=0, verbose::Bool=false)
    count = 1
    while isopen(server)
        try
            io = accept(server)
            io === nothing && continue
            if !tcpisvalid(io)
                verbose && @info "Accept-Reject:  $io"
                close(io)
                continue
            end
            connectioncounter[] += 1
            conn = Connection(server.hostname, server.hostport, 0, 0, true, io)
            let io=io, count=count
                @async begin
                    try
                        verbose && @info "Accept ($count):  $conn"
                        handle(h, conn, reuse_limit, readtimeout)
                        verbose && @info "Closed ($count):  $conn"
                    catch e
                        @error exception=(e, stacktrace(catch_backtrace()))
                    finally
                        connectioncounter[] -= 1
                        close(io)
                        verbose && @info "Closed ($count):  $conn"
                    end
                end
            end
        catch e
            if e isa InterruptException
                @warn "Interrupted: listen($server)"
                close(server)
                break
            end
            @error exception=(e, stacktrace(catch_backtrace()))
        end
        count += 1
    end
    return
end

"""
Connection handler: starts an async readtimeout thread if needed, then creates
Transactions to be handled as long as the Connection stays open. Only reuse_limit + 1
# of Transactions will be allowed during the lifetime of the Connection.
"""
function handle(h, c::Connection,
                reuse_limit::Int=10,
                readtimeout::Int=0)

    wait_for_timeout = Ref{Bool}(true)
    readtimeout > 0 && check_readtimeout(c, readtimeout, wait_for_timeout)
    try
        count = 0
        while isopen(c)
            handle(h, Transaction(c), count == reuse_limit)
            count += 1
        end
    finally
        wait_for_timeout[] = false
    end
    return
end

"creates an async thread that waits a specified amount of time before closing the connection"
function check_readtimeout(c, readtimeout, wait_for_timeout)
    @async while wait_for_timeout[]
        if inactiveseconds(c) > readtimeout
            @warn "Connection Timeout: $c"
            try
                writeheaders(c.io, Response(408, ["Connection" => "close"]))
            finally
                close(c)
            end
            break
        end
        sleep(8 + rand() * 4)
    end
    return
end

"""
Transaction handler: creates a new Stream for the Transaction, calls startread on it,
then dispatches the stream to the user-provided handler function. Catches errors on all
IO operations and closes gracefully if encountered.
"""
function handle(h, t::Transaction, last::Bool=false)
    request = Request()
    http = Stream(request, t)

    try
        startread(http)
    catch e
        if e isa EOFError && isempty(request.method)
            return
        elseif e isa ParseError
            status = e.code == :HEADER_SIZE_EXCEEDS_LIMIT  ? 413 : 400
            write(t, Response(status, body = string(e.code)))
            close(t)
            return
        elseif e isa Base.IOError && e.code == -54
            # read: connection reset by peer (ECONNRESET)
            return
        else
            rethrow(e)
        end
    end

    request.response.status = 200
    if last || hasheader(request, "Connection", "close")
        setheader(request.response, "Connection" => "close")
    end

    try
        h(http)
        closeread(http)
        closewrite(http)
    catch e
        @error "error handling request" exception=(e, stacktrace(catch_backtrace()))
        if isopen(http) && !iswritable(http)
            http.message.response.status = 500
            startwrite(http)
            write(http, sprint(showerror, e))
        end
        last = true
    finally
        last && close(t.c.io)
    end
    return
end

"For request handlers, read a full request from a stream, pass to the handler, then write out the response"
function handle(h, http::Stream)
    request::Request = http.message
    request.body = read(http)
    request.response::Response = h(request)
    request.response.request = request
    startwrite(http)
    write(http, request.response.body)
    return
end

end # module
