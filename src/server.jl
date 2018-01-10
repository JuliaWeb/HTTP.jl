module Nitrogen

using ..IOExtras
using ..Streams
using ..Messages
using ..Parsers
using ..ConnectionPool
import ..@debug, ..@debugshow, ..DEBUG_LEVEL

if !isdefined(Base, :Nothing)
    const Nothing = Void
    const Cvoid = Void
end

if VERSION < v"0.7.0-DEV.2575"
    const Dates = Base.Dates
else
    import Dates
end
@static if !isdefined(Base, :Distributed)
    using Distributed
end

using ..HTTP, ..Handlers

export Server, ServerOptions, serve
#TODO:
 # add in "events" handling
 # dealing w/ cookies
 # reverse proxy?
 # auto-compression
 # health report of server
 # http authentication subrequests?
 # ip access control lists?
 # JWT authentication?
 # live activity monitoring
 # live reconfigure?
 # memory/performance profiling for thousands of concurrent requests?
 # fault tolerance?
 # handle IPv6?
 # flv & mp4 streaming?
 # URL rewriting?
 # bandwidth throttling
 # IP address-based geolocation
 # user-tracking
 # WebDAV
 # FastCGI
 # default handler:
   # handle all common http requests/etc.
   # just map straight to filesystem
 # special case OPTIONS method like go?
 # buffer re-use for server/client wire-reading
 # easter egg (response 418)
mutable struct ServerOptions
    tlsconfig::HTTP.MbedTLS.SSLConfig
    readtimeout::Float64
    ratelimit::Rational{Int}
    support100continue::Bool
    chunksize::Union{Nothing, Int}
    logbody::Bool
end

abstract type Scheme end
struct http <: Scheme end
struct https <: Scheme end

ServerOptions(; tlsconfig::HTTP.MbedTLS.SSLConfig=HTTP.MbedTLS.SSLConfig(true),
                readtimeout::Float64=180.0,
                ratelimit::Rational{Int64}=Int64(5)//Int64(1),
                support100continue::Bool=true,
                chunksize::Union{Nothing, Int}=nothing,
                logbody::Bool=true) =
    ServerOptions(tlsconfig, readtimeout, ratelimit, support100continue, chunksize, logbody)

"""
    Server(handler, logger::IO=STDOUT; kwargs...)

An http/https server. Supports listening on a `host` and `port` via the `HTTP.serve(server, host, port)` function.
`handler` is a function of the form `f(::Request, ::Response) -> HTTP.Response`, i.e. it takes both a `Request` and pre-built `Response`
objects as inputs and returns the, potentially modified, `Respose`. `logger` indicates where logging output should be directed.
When `HTTP.serve` is called, it aims to "never die", catching and recovering from all internal errors. To forcefully stop, one can obviously
kill the julia process, interrupt (ctrl/cmd+c) if main task, or send the kill signal over a server in channel like:
`put!(server.in, HTTP.KILL)`.

Supported keyword arguments include:
  * `cert`: if https, the cert file to use, as passed to `HTTP.MbedTLS.SSLConfig(cert, key)`
  * `key`: if https, the key file to use, as passed to `HTTP.MbedTLS.SSLConfig(cert, key)`
  * `tlsconfig`: pass in an already-constructed `HTTP.MbedTLS.SSLConfig` instance
  * `readtimeout`: how long a client connection will be left open without receiving any bytes
  * `ratelimit`: a `Rational{Int}` of the form `5//1` indicating how many `messages//second` should be allowed per client IP address; requests exceeding the rate limit will be dropped
  * `support100continue`: a `Bool` indicating whether `Expect: 100-continue` headers should be supported for delayed request body sending; default = `true`
  * `logbody`: whether the Response body should be logged when `verbose=true` logging is enabled; default = `true`
"""
mutable struct Server{T <: Scheme, H <: HTTP.Handler}
    handler::H
    logger::IO
    in::Channel{Any}
    out::Channel{Any}
    options::ServerOptions

    Server{T, H}(handler::H, logger::IO=STDOUT, ch=Channel(1), ch2=Channel(1),
                 options=ServerOptions()) where {T, H} =
        new{T, H}(handler, logger, ch, ch2, options)
end

backtrace() = sprint(Base.show_backtrace, catch_backtrace())


function handle_request(f, server, io, i, verbose=true)

    logger = server.logger

    request = HTTP.Request()
    http = Streams.Stream(request, ConnectionPool.getparser(io), io)
    response = request.response
    response.status = 200

    try
        startread(http)

        if header(request, "Expect") == "100-continue"
            if server.options.support100continue
                response.status = 100
                startwrite(http)
                response.status = 200
            else
                response.status = 417
            end
        end

        if http.parser.message.upgrade
            HTTP.@log "received upgrade request on connection i=$i"
            response.status = 501
            response.body =
                Vector{UInt8}("upgrade requests are not currently supported")
        end

    catch e
        if e isa HTTP.ParsingError
            HTTP.@log "error parsing request on connection i=$i: " *
                      HTTP.ParsingErrorCodeMap[err.code]
            response.status = e.code == Parsers.HPE_INVALID_VERSION ? 505 :
                              e.code == Parsers.HPE_INVALID_METHOD ? 405 : 400
            response.body = HTTP.ParsingErrorCodeMap[err.code]
        else
            close(io)
            rethrow(e)
        end
    end

    if iserror(response)
        startwrite(http)
        write(http, response.body)
        close(io)
        return
    end

    HTTP.@log "received request on connection i=$i"
    verbose && (show(logger, request); println(logger, ""))

    @async try

        try
            f(http)
        catch e
            if !iswritable(io)
                showerror(logger, e)
                println(logger, backtrace())
                response.status = 500
                startwrite(http)
                write(http, sprint(showerror, e))
            else
                rethrow(e)
            end
        end

        closeread(http)
        closewrite(http)

    catch e
        close(io)
        rethrow(e)
    end
end



function handle_connection(f, server::Server{T, H}, i, io::Connection{ST}, rl, verbose) where {T, H, ST}
    logger = server.logger
    rate = Float64(server.options.ratelimit.num)
    rl.allowance += 1.0 # because it was just decremented right before we got here
    HTTP.@log "processing on connection i=$i..."
    while isopen(io)
        update!(rl, server.options.ratelimit)
        if rl.allowance > rate
            HTTP.@log "throttling on connection i=$i"
            rl.allowance = rate
        end
        if rl.allowance < 1.0
            HTTP.@log "sleeping on connection i=$i due to rate limiting"
            sleep(1.0)
        else
            rl.allowance -= 1.0
        end
        handle_request(f, server, ConnectionPool.Transaction{ST}(io), i)
    end
end


init_connection(::Server{http}, tcp) = tcp

function init_connection(server::Server{https}, tcp)
    tls_config = server.options.tlsconfig::HTTP.MbedTLS.SSLConfig
    try
        tls = HTTP.MbedTLS.SSLContext()
        HTTP.MbedTLS.setup!(tls, tls_config)
        HTTP.MbedTLS.associate!(tls, tcp)
        HTTP.MbedTLS.handshake!(tls)
        return tls
    catch e
        close(tcp)
        error("Error establishing SSL connection: $e")
        rethrow(e)
    end
end

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

@enum Signals KILL

function serve(f, server::Server{T, H}, host, port, verbose) where {T, H}
    logger = server.logger
    HTTP.@log "starting server to listen on: $(host):$(port)"
    tcpserver = Base.listen(host, port)
    ratelimits = Dict{IPAddr, RateLimit}()
    rate = Float64(server.options.ratelimit.num)
    i = 0
    @async begin
        while true
            val = take!(server.in)
            val == KILL && close(tcpserver)
        end
    end
    while true
        try
            # accept blocks until a new connection is detected
            tcp = accept(tcpserver)
            ip = getsockname(tcp)[1]
            rl = get!(ratelimits, ip, RateLimit(rate, Dates.now()))
            update!(rl, server.options.ratelimit)
            if rl.allowance > rate
                HTTP.@log "throttling $ip"
                rl.allowance = rate
            end
            if rl.allowance < 1.0
                HTTP.@log "discarding connection from $ip due to rate limiting"
                close(tcp)
            else
                rl.allowance -= 1.0
                HTTP.@log "new tcp connection accepted, reading request..."
                tcp = init_connection(server, tcp)
                SocketType = T == https ? HTTP.MbedTLS.SSLContext : TCPSocket
                c = Connection{SocketType}(tcp)
                let server=server, i=i, c=c, rl=rl
                    wait_for_timeout = Ref{Bool}(true)
                    readtimeout = server.options.readtimeout
                    @async while wait_for_timeout[]
                        if inactiveseconds(c) > readtimeout

                            # FIXME send a 408 ?

                            close(io)
                            HTTP.@log "Connection timeout i=$i"
                            break
                        end
                        sleep(8 + rand() * 4)
                    end
                    @async try
                        handle_connection(f, server, i, c, rl, verbose)
                    catch e
                        if e isa EOFError
                            HTTP.@log "connection i=$i: $e"
                        else
                            rethrow(e)
                        end
                    finally
                        HTTP.@log "finished processing on connection i=$i"
                        wait_for_timeout[] = false
                        close(c)
                    end
                end
                i += 1
            end
        catch e
            if typeof(e) <: InterruptException
                HTTP.@log "interrupt detected, shutting down..."
                interrupt()
                break
            else
                if !isopen(tcpserver)
                    HTTP.@log "server TCPServer is closed, shutting down..."
                    # Server was closed while waiting to accept client. Exit gracefully.
                    interrupt()
                    break
                end
                HTTP.@log "error encountered: $e"
                HTTP.@log "resuming serving..."
            end
        end
    end
    close(tcpserver)
    return
end

Server(h::Function, l::IO=STDOUT; cert::String="", key::String="", args...) = Server(HTTP.HandlerFunction(h), l; cert=cert, key=key, args...)
function Server(handler::H=HTTP.HandlerFunction((req, rep) -> HTTP.Response("Hello World!")),
               logger::IO=STDOUT;
               cert::String="",
               key::String="",
               args...) where {H <: HTTP.Handler}
    if cert != "" && key != ""
        server = Server{https, H}(handler, logger, Channel(1), Channel(1), ServerOptions(; tlsconfig=HTTP.MbedTLS.SSLConfig(cert, key), args...))
    else
        server = Server{http, H}(handler, logger, Channel(1), Channel(1), ServerOptions(; args...))
    end
    return server
end

"""
    HTTP.serve([server,] host::IPAddr, port::Int; verbose::Bool=true, kwargs...)

Start a server listening on the provided `host` and `port`. `verbose` indicates whether server activity should be logged.
Optional keyword arguments allow construction of `Server` on the fly if the `server` argument isn't provided directly.
See `?HTTP.Server` for more details on server construction and supported keyword arguments.
By default, `HTTP.serve` aims to "never die", catching and recovering from all internal errors. Two methods for stopping
`HTTP.serve` include interrupting (ctrl/cmd+c) if blocking on the main task, or sending the kill signal via the server's in channel
(`put!(server.in, HTTP.KILL)`).
"""
function serve end

serve(f, server::Server, host=IPv4(127,0,0,1), port=8081; verbose::Bool=true) = serve(f, server, host, port, verbose)
function serve(f, host::IPAddr, port::Int,
                   handler=(req, rep) -> HTTP.Response("Hello World!"),
                   logger::I=STDOUT;
                   cert::String="",
                   key::String="",
                   verbose::Bool=true,
                   args...) where {I}
    server = Server(handler, logger; cert=cert, key=key, args...)
    return serve(f, server, host, port, verbose)
end
serve(f, ; host::IPAddr=IPv4(127,0,0,1),
        port::Int=8081,
        handler=(req, rep) -> HTTP.Response("Hello World!"),
        logger::IO=STDOUT,
        cert::String="",
        key::String="",
        verbose::Bool=true,
        args...) =
    serve(f, host, port, handler, logger; cert=cert, key=key, verbose=verbose, args...)

function listen(f)
    HTTP.serve(f, HTTP.Server((x,y)->()))
end

end # module
