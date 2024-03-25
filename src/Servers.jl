"""
The `HTTP.Servers` module provides core HTTP server functionality.

The main entry point is `HTTP.listen(f, host, port; kw...)` which takes
a `f(::HTTP.Stream)::Nothing` function argument, a `host`, a `port` and
optional keyword arguments.  For full details, see `?HTTP.listen`.

For server functionality operating on full requests, see the `?HTTP.serve` function.
"""
module Servers

export listen, listen!, Server, forceclose, port

using Sockets, Logging, LoggingExtras, MbedTLS, Dates
using MbedTLS: SSLContext, SSLConfig
using ..IOExtras, ..Streams, ..Messages, ..Parsers, ..Connections, ..Exceptions
import ..access_threaded, ..SOCKET_TYPE_TLS, ..@logfmt_str

TRUE(x) = true
getinet(host::String, port::Integer) = Sockets.InetAddr(parse(IPAddr, host), port)
getinet(host::IPAddr, port::Integer) = Sockets.InetAddr(host, port)

struct Listener{S <: Union{SSLConfig, Nothing}, I <: Base.IOServer}
    addr::Sockets.InetAddr
    hostname::String
    hostport::String
    ssl::S
    server::I
end

function Listener(server::Base.IOServer; sslconfig::Union{MbedTLS.SSLConfig, Nothing}=nothing, kw...)
    host, port = getsockname(server)
    addr = getinet(host, port)
    return Listener(addr, string(host), string(port), sslconfig, server)
end

supportsreuseaddr() = ccall(:jl_has_so_reuseport, Int32, ()) == 1

function Listener(addr::Sockets.InetAddr, host::String, port::String;
    sslconfig::Union{MbedTLS.SSLConfig, Nothing}=nothing,
    reuseaddr::Bool=false,
    backlog::Integer=Sockets.BACKLOG_DEFAULT,
    server::Union{Nothing, Base.IOServer}=nothing, # for backwards compat
    listenany::Bool=false,
    kw...)
    if server !== nothing
        return Listener(server; sslconfig=sslconfig)
    end
    if listenany
        p, server = Sockets.listenany(addr.host, addr.port)
        addr = getinet(addr.host, p)
        port = string(p)
    elseif reuseaddr
        if !supportsreuseaddr()
            @warn "reuseaddr=true not supported on this platform: $(Sys.KERNEL)"
            @goto fallback
        end
        server = Sockets.TCPServer(delay = false)
        rc = ccall(:jl_tcp_reuseport, Int32, (Ptr{Cvoid},), server.handle)
        if rc < 0
            close(server)
            @warn "reuseaddr=true failed; falling back to regular listen: $(Sys.KERNEL)"
            @goto fallback
        end
        Sockets.bind(server, addr.host, addr.port; reuseaddr=true)
        Sockets.listen(server; backlog=backlog)
    else
@label fallback
        server = Sockets.listen(addr; backlog=backlog)
    end
    return Listener(addr, host, port, sslconfig, server)
end

Listener(host::Union{IPAddr, String}, port::Integer; kw...) = Listener(getinet(host, port), string(host), string(port); kw...)
Listener(port::Integer; kw...) = Listener(Sockets.localhost, port; kw...)
Listener(; kw...) = Listener(Sockets.localhost, 8081; kw...)

Base.isopen(l::Listener) = isopen(l.server)
Base.close(l::Listener) = close(l.server)

accept(s::Listener{Nothing}) = Sockets.accept(s.server)::TCPSocket
accept(s::Listener{SSLConfig}) = getsslcontext(Sockets.accept(s.server), s.ssl)

function getsslcontext(tcp, sslconfig)
    try
        ssl = MbedTLS.SSLContext()
        MbedTLS.setup!(ssl, sslconfig)
        MbedTLS.associate!(ssl, tcp)
        MbedTLS.handshake!(ssl)
        return ssl
    catch e
        @try Base.IOError close(tcp)
        e isa Base.IOError && return nothing
        e isa MbedTLS.MbedException && return nothing
        rethrow(e)
    end
end

"""
    HTTP.Server

Returned from `HTTP.listen!`/`HTTP.serve!` once a server is up listening
and ready to accept connections. Internally keeps track of active connections.
Also holds reference to any `on_shutdown` functions to be called when the server
is closed. Also holds a reference to the listening loop `Task` that can be
waited on via `wait(server)`, which provides similar functionality to `HTTP.listen`/
`HTTP.serve`. Can initiate a graceful shutdown where active connections are allowed
to finish being handled by calling `close(server)`. For a more forceful and immediate
shutdown, use `HTTP.forceclose(server)`.
"""
struct Server{L <: Listener}
    # listener socket + details
    listener::L
    # optional function or vector of functions
    # to call when closing server
    on_shutdown::Any
    # list of currently acctive connections
    connections::Set{Connection}
    # server listenandserve loop task
    task::Task
    # Protects the connections Set which is mutated in the listenloop
    # while potentially being accessed by the close method at the same time
    connections_lock::ReentrantLock
end

port(s::Server) = Int(s.listener.addr.port)
Base.isopen(s::Server) = isopen(s.listener)
Base.wait(s::Server) = wait(s.task)

function forceclose(s::Server)
    shutdown(s.on_shutdown)
    close(s.listener)
    Base.@lock s.connections_lock begin
        for c in s.connections
            close(c)
        end
    end
    return wait(s.task)
end

"""
    ConnectionState

When a connection is first made, it immediately goes into IDLE state.
Once startread(stream) returns, it's marked as ACTIVE.
Once closewrite(stream) returns, it's put back in IDLE,
unless it's been given the CLOSING state, then
it will close(c) itself and mark itself as CLOSED.
"""
@enum ConnectionState IDLE ACTIVE CLOSING CLOSED
closedorclosing(st) = st == CLOSING || st == CLOSED

function requestclose!(c::Connection)
    if c.state == IDLE
        c.state = CLOSED
        close(c)
    else
        c.state = CLOSING
    end
    return
end

function closeconnection(c::Connection)
    c.state = CLOSED
    close(c)
    return
end

# graceful shutdown that waits for active connectiosn to finish being handled
function Base.close(s::Server)
    shutdown(s.on_shutdown)
    close(s.listener)
    # first pass to mark or request connections to close
    Base.@lock s.connections_lock begin
        for c in s.connections
            requestclose!(c)
        end
    end
    # second pass to wait for connections to close
    # we wait for connections to empty because as
    # connections close themselves, they are removed
    # from our connections Set
    while true
        Base.@lock s.connections_lock begin
            isempty(s.connections) && break
        end
        sleep(0.5 + rand() * 0.1)
    end
    return wait(s.task)
end

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
    catch
        @error begin
            msg = current_exceptions_to_string()
            "shutdown function $fn failed. $msg"
        end
    end
end

"""
    HTTP.listen(handler, host=Sockets.localhost, port=8081; kw...)
    HTTP.listen(handler, port::Integer=8081; kw...)
    HTTP.listen(handler, server::Base.IOServer; kw...)
    HTTP.listen!(args...; kw...) -> HTTP.Server

Listen for HTTP connections and execute the `handler` function for each request.
Listening details can be passed as `host`/`port` pair, a single `port` (`host` will
default to `localhost`), or an already listening `server` object, as returned from
`Sockets.listen`. To open up a server to external requests, the `host` argument is
typically `"0.0.0.0"`.

The `HTTP.listen!` form is non-blocking and returns an `HTTP.Server` object which can be
`wait(server)`ed on manually, or `close(server)`ed to gracefully shut down the server.
Calling `HTTP.forceclose(server)` will immediately force close the server and all active
connections. `HTTP.listen` will block on the server listening loop until interrupted or
and an irrecoverable error occurs.

The `handler` function should be of the form `f(::HTTP.Stream)::Nothing`, and should
at the minimum set a status via `setstatus()` and call `startwrite()` either
explicitly or implicitly by writing out a response via `write()`. Failure to
do this will result in an HTTP 500 error being transmitted to the client.

Optional keyword arguments:
 - `sslconfig=nothing`, Provide an `MbedTLS.SSLConfig` object to handle ssl
    connections. Pass `sslconfig=MbedTLS.SSLConfig(false)` to disable ssl
    verification (useful for testing). Construct a custom `SSLConfig` object
    with `MbedTLS.SSLConfig(certfile, keyfile)`.
 - `tcpisvalid = tcp->true`, function `f(::TCPSocket)::Bool` to check if accepted
    connections are valid before processing requests. e.g. to do source IP filtering.
 - `readtimeout::Int=0`, close the connection if no data is received for this
    many seconds. Use readtimeout = 0 to disable.
 - `reuseaddr::Bool=false`, allow multiple servers to listen on the same port.
    Not supported on some OS platforms. Can check `HTTP.Servers.supportsreuseaddr()`.
 - `server::Base.IOServer=nothing`, provide an `IOServer` object to listen on;
    allows manually closing or configuring the server socket.
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
# start a blocking server
HTTP.listen("127.0.0.1", 8081) do http
    HTTP.setheader(http, "Content-Type" => "text/html")
    write(http, "target uri: \$(http.message.target)<BR>")
    write(http, "request body:<BR><PRE>")
    write(http, read(http))
    write(http, "</PRE>")
    return
end

# non-blocking server
server = HTTP.listen!("127.0.0.1", 8081) do http
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
# can gracefully close server manually
close(server)
```

To run the following HTTP chat example, open two Julia REPL windows and paste
the example code into both of them. Then in one window run `chat_server()` and
in the other run `chat_client()`, then type `hello` and press return.
Whatever you type on the client will be displayed on the server and vis-versa.

```
using HTTP

function chat(io::HTTP.Stream)
    Threads.@spawn while !eof(io)
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

"""
    HTTP.listen!(args...; kw...) -> HTTP.Server

Non-blocking version of [`HTTP.listen`](@ref); see that function for details.
"""
function listen! end

listen(f, args...; kw...) = listen(f, Listener(args...; kw...); kw...)
listen!(f, args...; kw...) = listen!(f, Listener(args...; kw...); kw...)

function listen(f, listener::Listener; kw...)
    server = listen!(f, listener; kw...)
    # block on server task
    try
        wait(server)
    finally
        # try to gracefully close
        close(server)
    end
    return server
end

# compat for `Threads.@spawn :interactive expr`
@static if hasmethod(getfield(Threads, Symbol("@spawn")), Tuple{LineNumberNode, Module, Symbol, Expr})
    macro _spawn_interactive(ex)
        esc(:(Threads.@spawn :interactive $ex))
    end
else
    macro _spawn_interactive(ex)
        esc(:(@async $ex))
    end
end

function listen!(f, listener::Listener;
    on_shutdown=nothing,
    tcpisvalid=TRUE,
    max_connections::Integer=typemax(Int),
    readtimeout::Integer=0,
    access_log::Union{Function,Nothing}=nothing,
    verbose=false, kw...)
    conns = Set{Connection}()
    conns_lock = ReentrantLock()
    ready_to_accept = Threads.Event()
    if verbose > 0
        tsk = @_spawn_interactive LoggingExtras.withlevel(Logging.Debug; verbosity=verbose) do
            listenloop(f, listener, conns, tcpisvalid, max_connections, readtimeout, access_log, ready_to_accept, conns_lock, verbose)
        end
    else
        tsk = @_spawn_interactive listenloop(f, listener, conns, tcpisvalid, max_connections, readtimeout, access_log, ready_to_accept, conns_lock, verbose)
    end
    # wait until the listenloop enters the loop
    wait(ready_to_accept)
    return Server(listener, on_shutdown, conns, tsk, conns_lock)
end

""""
Main server loop.
Accepts new tcp connections and spawns async tasks to handle them."
"""
function listenloop(
    f, listener, conns, tcpisvalid, max_connections, readtimeout, access_log, ready_to_accept,
    conns_lock, verbose
)
    sem = Base.Semaphore(max_connections)
    verbose >= 0 && @infov 1 "Listening on: $(listener.hostname):$(listener.hostport), thread id: $(Threads.threadid())"
    notify(ready_to_accept)
    while isopen(listener)
        try
            Base.acquire(sem)
            io = accept(listener)
            if io === nothing
                @warnv 1 "unable to accept new connection"
                continue
            elseif !tcpisvalid(io)
                @warnv 1 "!tcpisvalid: $io"
                close(io)
                continue
            end
            conn = Connection(io)
            conn.state = IDLE
            Base.@lock conns_lock push!(conns, conn)
            conn.host, conn.port = listener.hostname, listener.hostport
            @async try
                handle_connection(f, conn, listener, readtimeout, access_log)
            finally
                # handle_connection is in charge of closing the underlying io
                Base.@lock conns_lock delete!(conns, conn)
                Base.release(sem)
            end
        catch e
            if e isa Base.IOError && e.code == Base.UV_ECONNABORTED
                verbose >= 0 && @infov 1 "Server on $(listener.hostname):$(listener.hostport) closing"
            else
                @errorv 2 begin
                    msg = current_exceptions_to_string()
                    "Server on $(listener.hostname):$(listener.hostport) errored. $msg"
                end
                # quick little sleep in case there's a temporary
                # local error accepting and this might help avoid quickly re-erroring
                sleep(0.05 + rand() * 0.05)
            end
        end
    end
    return
end

"""
Start a `check_readtimeout` task to close the `Connection` if it is inactive.
Passes the `Connection` object to handle a single request/response transaction
for each HTTP Request received.
After `reuse_limit + 1` transactions, signal `final_transaction` to the
transaction handler, which will close the connection.
"""
function handle_connection(f, c::Connection, listener, readtimeout, access_log)
    wait_for_timeout = Ref{Bool}(true)
    if readtimeout > 0
        @async check_readtimeout(c, readtimeout, wait_for_timeout)
    end
    try
        # if the connection socket or listener close, we stop taking requests
        while isopen(c) && !closedorclosing(c.state) && isopen(listener)
            # create new Request to be populated by parsing code
            request = Request()
            # wrap Request in Stream w/ Connection for request reading/response writing
            http = Stream(request, c)
            # attempt to read request line and headers
            try
                startread(http)
                @debugv 1 "startread called"
                c.state = ACTIVE # once we've started reading, set ACTIVE state
            catch e
                # for ParserErrors, try to inform client of the problem
                if e isa ParseError
                    write(c, Response(e.code == :HEADER_SIZE_EXCEEDS_LIMIT ? 431 : 400, string(e.code)))
                end
                @debugv 1 begin
                    msg = current_exceptions_to_string()
                    "handle_connection startread error. $msg"
                end
                break
            end

            if hasheader(request, "Connection", "close")
                c.state = CLOSING # set CLOSING so no more requests are read
                setheader(request.response, "Connection" => "close")
            end
            request.response.status = 200

            try
                # invokelatest becuase the perf is negligible, but this makes live-editing handlers more Revise friendly
                @debugv 1 "invoking handler"
                Base.invokelatest(f, http)
                # If `startwrite()` was never called, throw an error so we send a 500 and log this
                if isopen(http) && !iswritable(http)
                    error("Server never wrote a response")
                end
                @debugv 1 "closeread"
                closeread(http)
                @debugv 1 "closewrite"
                closewrite(http)
                c.state = IDLE
            catch e
                # The remote can close the stream whenever it wants to, but there's nothing
                # anyone can do about it on this side. No reason to log an error in that case.
                level = e isa Base.IOError && !isopen(c) ? Logging.Debug : Logging.Error
                @logmsgv 1 level begin
                    msg = current_exceptions_to_string()
                    "handle_connection handler error. $msg"
                end

                if isopen(http) && !iswritable(http)
                    request.response.status = 500
                    startwrite(http)
                    closewrite(http)
                end
                c.state = CLOSING
            finally
                if access_log !== nothing
                    @try(Any, @info sprint(access_log, http) _group=:access)
                end
            end
        end
    catch
        # we should be catching everything inside the while loop, but just in case
        @errorv 1 begin
            msg = current_exceptions_to_string()
            "error while handling connection. $msg"
        end
    finally
        if readtimeout > 0
            wait_for_timeout[] = false
        end
        # when we're done w/ the connection, ensure it's closed and state is properly set
        closeconnection(c)
    end
    return
end

"""
If `c` is inactive for a more than `readtimeout` then close the `c`."
"""
function check_readtimeout(c, readtimeout, wait_for_timeout)
    while wait_for_timeout[]
        if inactiveseconds(c) > readtimeout
            @warnv 2 "Connection Timeout: $c"
            try
                writeheaders(c, Response(408, ["Connection" => "close"]))
            finally
                closeconnection(c)
            end
            break
        end
        sleep(readtimeout + rand() * readtimeout)
    end
    return
end

end # module
