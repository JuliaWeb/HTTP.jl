"""
The `HTTP.Servers` module provides HTTP server functionality.

The main entry point is `HTTP.listen(f, host, port; kw...)` which takes
a `f(::HTTP.Stream)::Nothing` function argument, a `host`, a `port` and
optional keyword arguments.  For full details, see `?HTTP.listen`.

For server functionality operating on full requests, see `?HTTP.Handlers`
module and `?HTTP.serve` function.
"""
module Servers

export listen

using ..IOExtras
using ..Streams
using ..Messages
using ..Parsers
using ..ConnectionPool
using Sockets, Logging
using MbedTLS: SSLContext, SSLConfig
import MbedTLS

using Dates

import ..@debug, ..@debugshow, ..DEBUG_LEVEL, ..taskid, ..access_threaded

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
    if rl.allowance > rate_limit
        rl.allowance = rate_limit
    end
    return nothing
end

const RATE_LIMITS = Dict{IPAddr, RateLimit}[]
check_rate_limit(tcp::Base.PipeEndpoint, rate_limit::Rational{Int}) = true
check_rate_limit(tcp, ::Nothing) = true

"""
`check_rate_limit` takes a new connection (socket), and checks in
the global RATE_LIMITS store for the last time a connection was
seen for the same ip address. If the new connection has come too
soon, it is closed and discarded, otherwise, the timestamp for the
ip address is updated in the global cache.
"""
function check_rate_limit(tcp, rate_limit::Rational{Int})
    ip = Sockets.getpeername(tcp)[1]
    rl_d = access_threaded(Dict{IPAddr, RateLimit}, RATE_LIMITS)
    rl = get!(rl_d, ip, RateLimit(rate_limit, Dates.DateTime(0)))
    update!(rl, rate_limit)
    if rl.allowance < 1.0
        @warn "discarding connection from $ip due to rate limiting"
        return false
    else
        rl.allowance -= 1.0
    end
    return true
end

"Convenience object for passing around server details"
struct Server{S <: Union{SSLConfig, Nothing}, I <: Base.IOServer}
    ssl::S
    server::I
    hostname::String
    hostport::String
    on_shutdown::Any
    access_log::Union{Function,Nothing}
end
Server(ssl, server, hostname, hostport, on_shutdown) =
    Server(ssl, server, hostname, hostport, on_shutdown, nothing)

Base.isopen(s::Server) = isopen(s.server)
Base.close(s::Server) = (shutdown(s.on_shutdown); close(s.server))

"""
    shutdown(fns::Vector{<:Function})
    shutdown(fn::Function)
    shutdown(::Nothing)

Runs function(s) in `on_shutdown` field of `Server` when
`Server` is closed.
"""
shutdown(fns::Vector{<:Function}) = foreach(shutdown, fns)
shutdown(::Nothing) = nothing
function shutdown(fn::Function)
    try
        fn()
    catch e
        @error "shutdown function $fn failed" exception=(e, catch_backtrace())
    end
end

Sockets.accept(s::Server{Nothing}) = accept(s.server)::TCPSocket
Sockets.accept(s::Server{SSLConfig}) = getsslcontext(accept(s.server), s.ssl)

function getsslcontext(tcp, sslconfig)
    try
        ssl = MbedTLS.SSLContext()
        MbedTLS.setup!(ssl, sslconfig)
        MbedTLS.associate!(ssl, tcp)
        MbedTLS.handshake!(ssl)
        return ssl
    catch e
        return nothing
    end
end

"""
    HTTP.listen([host=Sockets.localhost[, port=8081]]; kw...) do http::HTTP.Stream
        ...
    end

Listen for HTTP connections and execute the `do` function for each request.

The `do` function should be of the form `f(::HTTP.Stream)::Nothing`, and should
at the minimum set a status via `setstatus()` and call `startwrite()` either
explicitly or implicitly by writing out a response via `write()`.  Failure to
do this will result in an HTTP 500 error being transmitted to the client.

Optional keyword arguments:
 - `sslconfig=nothing`, Provide an `MbedTLS.SSLConfig` object to handle ssl
    connections. Pass `sslconfig=MbedTLS.SSLConfig(false)` to disable ssl
    verification (useful for testing).
 - `reuse_limit = nolimit`, number of times a connection is allowed to be
   reused after the first request.
 - `tcpisvalid = tcp->true`, function `f(::TCPSocket)::Bool` to, check accepted
    connection before processing requests. e.g. to do source IP filtering.
 - `readtimeout::Int=0`, close the connection if no data is received for this
    many seconds. Use readtimeout = 0 to disable.
 - `reuseaddr::Bool=false`, allow multiple servers to listen on the same port.
 - `server::Base.IOServer=nothing`, provide an `IOServer` object to listen on;
    allows closing the server.
 - `connection_count::Ref{Int}`, reference to track the number of currently
    open connections.
 - `rate_limit::Rational{Int}=nothing"`, number of `connections//second`
    allowed per client IP address; excess connections are immediately closed.
    e.g. 5//1.
 - `verbose::Bool=false`, log connection information to `stdout`.
 - `access_log::Function`, function for formatting access log messages. The
    function should accept two arguments, `io::IO` to which the messages should
    be written, and `http::HTTP.Stream` which can be used to query information
    from. See also [`@logfmt_str`](@ref).
 - `on_shutdown::Union{Function, Vector{<:Function}, Nothing}=nothing`, one or
    more functions to be run if the server is closed (for example by an
    `InterruptException`). Note, shutdown function(s) will not run if an
    `IOServer` object is supplied to the `server` keyword argument and closed
    by `close(server)`.

e.g.
```julia
HTTP.listen("127.0.0.1", 8081) do http
    HTTP.setheader(http, "Content-Type" => "text/html")
    write(http, "target uri: \$(http.message.target)<BR>")
    write(http, "request body:<BR><PRE>")
    write(http, read(http))
    write(http, "</PRE>")
    return
end

HTTP.listen("127.0.0.1", 8081) do http
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
end
```

The `server=` option can be used to pass an already listening socket to
`HTTP.listen`. This allows manual control of server shutdown.

e.g.
```julia
using Sockets
server = Sockets.listen(Sockets.InetAddr(parse(IPAddr, host), port))
@async HTTP.listen(f, host, port; server=server)

# Closing server will stop HTTP.listen.
close(server)
```

To run the following HTTP chat example, open two Julia REPL windows and paste
the example code into both of them. Then in one window run `chat_server()` and
in the other run `chat_client()`, then type `hello` and press return.
Whatever you type on the client will be displayed on the server and vis-versa.

```
using HTTP

function chat(io::HTTP.Stream)
    @async while !eof(io)
        write(stdout, readavailable(io), "\\n")
    end
    while isopen(io)
        write(io, readline(stdin))
    end
end

chat_server() = HTTP.listen("127.0.0.1", 8087) do io
    write(io, "HTTP.jl Chat Server. Welcome!")
    chat(io)
end

chat_client() = HTTP.open("POST", "http://127.0.0.1:8087") do io
    chat(io)
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
                sslconfig::Union{MbedTLS.SSLConfig, Nothing}=nothing,
                tcpisvalid::Function=tcp->true,
                server::Union{Base.IOServer, Nothing}=nothing,
                reuseaddr::Bool=false,
                max_connections::Int=nolimit,
                connection_count::Ref{Int}=Ref(0),
                rate_limit::Union{Rational{Int}, Nothing}=nothing,
                reuse_limit::Int=nolimit,
                readtimeout::Int=0,
                verbose::Bool=false,
                access_log::Union{Function,Nothing}=nothing,
                on_shutdown::Union{Function, Vector{<:Function}, Nothing}=nothing)

    inet = getinet(host, port)
    if server !== nothing
        tcpserver = server
        host, port = getsockname(server)
    elseif reuseaddr
        tcpserver = Sockets.TCPServer(; delay=false)
        if Sys.isunix()
            if Sys.isapple()
                verbose && @warn "note that `reuseaddr=true` allows multiple processes to bind to the same addr/port, but only one process will accept new connections (if that process exits, another process listening will start accepting)"
            end
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

    tcpisvalid = let f=tcpisvalid
        x -> f(x) && check_rate_limit(x, rate_limit)
    end

    s = Server(sslconfig, tcpserver, string(host), string(port), on_shutdown, access_log)
    return listenloop(f, s, tcpisvalid, connection_count, max_connections,
                         reuse_limit, readtimeout, verbose)
end

""""
Main server loop.
Accepts new tcp connections and spawns async tasks to handle them."
"""
function listenloop(f, server, tcpisvalid, connection_count,
                       max_connections, reuse_limit, readtimeout, verbose)
    sem = Base.Semaphore(max_connections)
    count = 1
    while isopen(server)
        try
            Base.acquire(sem)
            io = accept(server)
            if io === nothing
                verbose && @warn "unable to accept new connection"
                continue
            elseif !tcpisvalid(io)
                verbose && @info "Accept-Reject:  $io"
                close(io)
                continue
            end
            connection_count[] += 1
            conn = Connection(io)
            conn.host, conn.port = server.hostname, server.hostport
            @async try
                # verbose && @info "Accept ($count):  $conn"
                handle_connection(f, conn, server, reuse_limit, readtimeout)
                # verbose && @info "Closed ($count):  $conn"
            catch e
                if e isa Base.IOError &&
                    (e.code == -54 || e.code == -4077 || e.code == -104 || e.code == -131 || e.code == -232)
                    verbose && @warn "connection reset by peer (ECONNRESET)"
                else
                    @error "" exception=(e, stacktrace(catch_backtrace()))
                end
            finally
                connection_count[] -= 1
                Base.release(sem)
                # handle_connection is in charge of closing the underlying io
            end
        catch e
            close(server)
            if e isa InterruptException
                @warn "Interrupted: listen($server)"
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
Start a `check_readtimeout` task to close the `Connection` if it is inactive.
Create a `Transaction` object for each HTTP Request received.
After `reuse_limit + 1` transactions, signal `final_transaction` to the
transaction handler.
"""
function handle_connection(f, c::Connection, server, reuse_limit, readtimeout)
    if readtimeout > 0
        wait_for_timeout = Ref{Bool}(true)
        @async check_readtimeout(c, readtimeout, wait_for_timeout)
    end
    try
        count = 0
        # if the connection socket or original server close, we stop taking requests
        while isopen(c) && isopen(server) && count <= reuse_limit
            handle_transaction(f, c, server;
                               final_transaction=(count == reuse_limit))
            count += 1
        end
    finally
        if readtimeout > 0
            wait_for_timeout[] = false
        end
    end
    return
end

"""
If `c` is inactive for a more than `readtimeout` then close the `c`."
"""
function check_readtimeout(c, readtimeout, wait_for_timeout)
    while wait_for_timeout[]
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
Create a `HTTP.Stream` and parse the Request headers from a `HTTP.Transaction`
(by calling `startread(::Stream`).
If there is a parse error, send an error Response.
Otherwise, execute stream processing function `f`.
If `f` throws an exception, send an error Response and close the connection.
"""
function handle_transaction(f, c::Connection, server; final_transaction::Bool=false)
    request = Request()
    http = Stream(request, c)

    try
        @debug 2 "server startread"
        startread(http)
        if !isopen(server)
            close(c)
            return
        end
    catch e
        if e isa EOFError && isempty(request.method)
            return
        elseif e isa ParseError
            status = e.code == :HEADER_SIZE_EXCEEDS_LIMIT  ? 413 : 400
            write(c, Response(status, body = string(e.code)))
            close(c)
            return
        else
            rethrow(e)
        end
    end

    request.response.status = 200
    if final_transaction || hasheader(request, "Connection", "close")
        setheader(request.response, "Connection" => "close")
    end

    try
        f(http)
        # If `startwrite()` was never called, throw an error so we send a 500 and log this
        if isopen(http) && !iswritable(http)
            error("Server never wrote a response")
        end
        @debug 2 "server closeread"
        closeread(http)
        @debug 2 "server closewrite"
        closewrite(http)
    catch e
        # The remote can close the stream whenever it wants to, but there's nothing
        # anyone can do about it on this side. No reason to log an error in that case.
        level = e isa Base.IOError && !isopen(http) ? Logging.Debug : Logging.Error
        @logmsg level "error handling request" exception=(e, stacktrace(catch_backtrace()))

        if isopen(http) && !iswritable(http)
            http.message.response.status = 500
            startwrite(http)
            write(http, sprint(showerror, e))
            closewrite(http)
        end
        final_transaction = true
    finally
        if server.access_log !== nothing
            try; @info sprint(server.access_log, http) _group=:access; catch; end
        end
        final_transaction && close(c.io)
    end
    return
end

function __init__()
    resize!(empty!(RATE_LIMITS), Threads.nthreads())
    return
end

end # module
