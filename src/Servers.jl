"""
The `HTTP.Servers` module provides server-side http functionality in pure Julia.

The main entry point is `HTTP.listen(handler, host, port; kw...)` which takes a `handler` argument (see `?HTTP.Handlers`),
a `host` and `port` and optional keyword arguments. For full details, see `?HTTP.listen`.
"""
module Servers

export listen, handle, Handler, RequestHandler, StreamHandler

using ..IOExtras
using ..Streams
using ..Messages
using ..Parsers
using ..ConnectionPool
using Sockets
using MbedTLS
using Dates

"""
HTTP.handle(handler::HTTP.RequestHandler, ::HTTP.Request) => HTTP.Response
HTTP.handle(handler::HTTP.StreamHandler, ::HTTP.Stream)

Dispatch function used to handle incoming requests to a server. Can be
overloaded by custom `HTTP.Handler` subtypes to implement custom "handling"
behavior.
"""
function handle end

abstract type Handler end

"""
Abstract type representing objects that handle `HTTP.Request` and return `HTTP.Response` objects.

See `?HTTP.RequestHandlerFunction` for an example of a concrete implementation.
"""
abstract type RequestHandler <: Handler end

"""
Abstract type representing objects that handle `HTTP.Stream` objects directly.

See `?HTTP.StreamHandlerFunction` for an example of a concrete implementation.
"""
abstract type StreamHandler <: Handler end

"""
RequestHandlerFunction(f)

A function-wrapper type that is a subtype of `RequestHandler`. Takes a single function as an argument
that should be of the form `f(::HTTP.Request) => HTTP.Response`
"""
struct RequestHandlerFunction{F} <: RequestHandler
    func::F # func(req)
end

handle(h::RequestHandlerFunction, req::Request) = h.func(req)

"""
StreamHandlerFunction(f)

A function-wrapper type that is a subtype of `StreamHandler`. Takes a single function as an argument
that should be of the form `f(::HTTP.Stream) => Nothing`, i.e. it accepts a raw `HTTP.Stream`,
handles the incoming request, writes a response back out to the stream directly, then returns.
"""
struct StreamHandlerFunction{F} <: StreamHandler
    func::F # func(stream)
end

handle(h::StreamHandlerFunction, stream::Stream) = h.func(stream)

# rate limiting
mutable struct RateLimit
    allowance::Float64
    lastcheck::Dates.DateTime
end

function update!(rl::RateLimit, rate_limit)
    current = Dates.now()
    timepassed = float(Dates.value(current - rl.lastcheck)) / 1000.0
    rl.lastcheck = current
    rl.allowance += timepassed * rate_limit
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
function check_rate_limit(tcp, rate_limit::Rational{Int})
    ip = Sockets.getsockname(tcp)[1]
    rate = Float64(rate_limit.num)
    rl = get!(RATE_LIMITS, ip, RateLimit(rate, Dates.now()))
    update!(rl, rate_limit)
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
 - `sslconfig=nothing`, Provide an `MbedTLS.SSLConfig` object to handle ssl connections.
 - `reuse_limit = nolimit`, number of times a connection is allowed to be reused
                            after the first request.
 - `tcpisvalid::Function (::TCPSocket) -> Bool`, check accepted connection before
    processing requests. e.g. to implement source IP filtering, rate-limiting, etc.
 - `readtimeout::Int=60`, close the connection if no data is recieved for this
    many seconds. Use readtimeout = 0 to disable.
 - `reuseaddr::Bool=false`, allow multiple servers to listen on the same port.
 - `server::Base.IOServer=nothing`, provide an `IOServer` object to listen on;
    allows closing the server.
 - `connection_count::Ref{Int}`, reference to track the # of currently open connections.
 - `rate_limit::Rational{Int}=nothing"`, number of `connections//second` allowed
    per client IP address; excess connections are immediately closed. e.g. 5//1.
 - `stream::Bool=false`, pass a HTTP.Stream to the handler function
    (instead of a HTTP.Request).
 - `verbose::Bool=false`, log connection information to `stdout`.

e.g.
```
    HTTP.listen(; stream=true) do http::HTTP.Stream
        @show http.message
        @show HTTP.header(http, "Content-Type")
        while !eof(http)
            println("body data: ", String(readavailable(http)))
        end
        HTTP.setstatus(http, 404)
        HTTP.setheader(http, "Foo-Header" => "bar")
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

const nolimit = typemax(Int)

getinet(host::String, port::Integer) = Sockets.InetAddr(parse(IPAddr, host), port)
getinet(host::IPAddr, port::Integer) = Sockets.InetAddr(host, port)

function listen(f,
                host::Union{IPAddr, String}=Sockets.localhost,
                port::Integer=8081
                ;
                stream::Bool=false,
                sslconfig::Union{MbedTLS.SSLConfig, Nothing}=nothing,
                tcpisvalid::Union{Function, Nothing}=nothing,
                server::Union{Base.IOServer, Nothing}=nothing,
                reuseaddr::Bool=false,
                connection_count::Ref{Int}=Ref(0),
                rate_limit::Union{Rational{Int}, Nothing}=nothing,
                reuse_limit::Int=nolimit,
                readtimeout::Int=60,
                verbose::Bool=false)

    handler = f isa Handler ? f : stream ? StreamHandlerFunction(f) : RequestHandlerFunction(f)

    inet = getinet(host, port)
    if server !== nothing
        tcpserver = server
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
        tcpisvalid = rate_limit === nothing ? x->true : x->check_rate_limit(x, rate_limit)
    elseif rate_limit !== nothing
        tcpisvalid = let f=tcpisvalid
            x -> f(x) && check_rate_limit(x, rate_limit)
        end
    end

    return listenloop(handler, Server2(sslconfig, tcpserver, string(host), string(port)), tcpisvalid,
        connection_count, reuse_limit, readtimeout, verbose)
end

"main server loop that accepts new tcp connections and spawns async threads to handle them"
function listenloop(h, server, tcpisvalid, connection_count, reuse_limit, readtimeout, verbose)
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
            connection_count[] += 1
            conn = Connection(io)
            conn.host, conn.port = server.hostname, server.hostport
            let io=io, count=count
                @async try
                    verbose && @info "Accept ($count):  $conn"
                    handle_connection(h, conn, reuse_limit, readtimeout)
                    verbose && @info "Closed ($count):  $conn"
                catch e
                    if e isa Base.IOError && e.code == -54
                        verbose && @warn "connection reset by peer (ECONNRESET)"
                    else
                        @error exception=(e, stacktrace(catch_backtrace()))
                    end
                finally
                    connection_count[] -= 1
                    close(io)
                    verbose && @info "Closed ($count):  $conn"
                end
            end
        catch e
            if e isa InterruptException
                @warn "Interrupted: listen($server)"
                close(server)
                break
            else
                rethrow(e)
            end
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
function handle_connection(h, c::Connection, reuse_limit, readtimeout)
    wait_for_timeout = Ref{Bool}(true)
    readtimeout > 0 && check_readtimeout(c, readtimeout, wait_for_timeout)
    try
        count = 0
        while isopen(c)
            handle_transaction(h, Transaction(c); final_transaction=count == reuse_limit)
            count += 1
        end
    finally
        wait_for_timeout[] = false
    end
    return
end

"creates an async task that waits a specified amount of time before closing the connection"
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
function handle_transaction(h, t::Transaction; final_transaction::Bool=false)
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
        else
            rethrow(e)
        end
    end

    request.response.status = 200
    if final_transaction || hasheader(request, "Connection", "close")
        setheader(request.response, "Connection" => "close")
    end

    @async try
        handle(h, http)
        closeread(http)
        closewrite(http)
    catch e
        @error "error handling request" exception=(e, stacktrace(catch_backtrace()))
        if isopen(http) && !iswritable(http)
            http.message.response.status = 500
            startwrite(http)
            write(http, sprint(showerror, e))
        end
        final_transaction = true
    finally
        final_transaction && close(t.c.io)
    end
    return
end

"For request handlers, read a full request from a stream, pass to the handler, then write out the response"
function handle(h::RequestHandler, http::Stream)
    request::Request = http.message
    request.body = read(http)
    closeread(http)
    request.response::Response = handle(h, request)
    request.response.request = request
    startwrite(http)
    write(http, request.response.body)
    return
end

end # module
