module Servers

using ..IOExtras
using ..Streams
using ..Messages
using ..Parsers
using ..ConnectionPool
using ..Sockets
import ..@info, ..@warn, ..@error, ..@debug, ..@debugshow, ..DEBUG_LEVEL, ..compat_stdout
using MbedTLS: SSLConfig, SSLContext, setup!, associate!, hostname!, handshake!

if !isdefined(Base, :Nothing)
    const Nothing = Void
    const Cvoid = Void
end

import ..Dates

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
    sslconfig::HTTP.MbedTLS.SSLConfig
    readtimeout::Float64
    ratelimit::Rational{Int}
    support100continue::Bool
    chunksize::Union{Nothing, Int}
    logbody::Bool
end

abstract type Scheme end
struct http <: Scheme end
struct https <: Scheme end

ServerOptions(; sslconfig::HTTP.MbedTLS.SSLConfig=HTTP.MbedTLS.SSLConfig(true),
                readtimeout::Float64=180.0,
                ratelimit::Rational{Int}=Int(5)//Int(1),
                support100continue::Bool=true,
                chunksize::Union{Nothing, Int}=nothing,
                logbody::Bool=true) =
    ServerOptions(sslconfig, readtimeout, ratelimit, support100continue, chunksize, logbody)

"""
    Server(handler, logger::IO=stdout; kwargs...)

An http/https server. Supports listening on a `host` and `port` via the `HTTP.serve(server, host, port)` function.
`handler` is a function of the form `f(::Request, ::Response) -> HTTP.Response`, i.e. it takes both a `Request` and pre-built `Response`
objects as inputs and returns the, potentially modified, `Response`. `logger` indicates where logging output should be directed.
When `HTTP.serve` is called, it aims to "never die", catching and recovering from all internal errors. To forcefully stop, one can obviously
kill the julia process, interrupt (ctrl/cmd+c) if main task, or send the kill signal over a server in channel like:
`put!(server.in, HTTP.Servers.KILL)`.

Supported keyword arguments include:
  * `cert`: if https, the cert file to use, as passed to `HTTP.MbedTLS.SSLConfig(cert, key)`
  * `key`: if https, the key file to use, as passed to `HTTP.MbedTLS.SSLConfig(cert, key)`
  * `sslconfig`: pass in an already-constructed `HTTP.MbedTLS.SSLConfig` instance
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

    Server{T, H}(handler::H, logger::IO=compat_stdout(), ch=Channel(1), ch2=Channel(1),
                 options=ServerOptions()) where {T, H} =
        new{T, H}(handler, logger, ch, ch2, options)
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

check_rate_limit(tcp::Base.PipeEndpoint; kw...) = true
function check_rate_limit(tcp;
                          ratelimits=nothing,
                          ratelimit::Rational{Int}=Int(10)//Int(1), kw...)
    ip = Sockets.getsockname(tcp)[1]
    rate = Float64(ratelimit.num)
    rl = get!(ratelimits, ip, RateLimit(rate, Dates.now()))
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


@enum Signals KILL

serve(server::Server, host::IPAddr, port::Integer, verbose::Bool) = serve(server, Sockets.InetAddr(host, port), verbose)
serve(server::Server, host::AbstractString, port::Integer, verbose::Bool) = serve(server, parse(IPAddr, host), port, verbose)
serve(server::Server{T, H}, host::AbstractString, verbose::Bool) where {T, H} = serve(server, String(host), verbose)
function serve(server::Server{T, H}, host::Union{Sockets.InetAddr, String}, verbose::Bool) where {T, H}

    tcpserver = Ref{Base.IOServer}()

    @async begin
        while !isassigned(tcpserver)
            sleep(1)
        end
        while true
            val = take!(server.in)
            val == KILL && close(tcpserver[])
        end
    end

    listen(host;
           tcpref=tcpserver,
           ssl=(T == https),
           sslconfig=server.options.sslconfig,
           verbose=verbose,
           tcpisvalid=server.options.ratelimit > 0 ? check_rate_limit :
                                                     (tcp; kw...) -> true,
           ratelimits=Dict{IPAddr, RateLimit}(),
           ratelimit=server.options.ratelimit) do request::HTTP.Request

        handle(server.handler, request)
    end

    return
end

serve(server::Server, host::IPAddr=Sockets.localhost, port::Integer=8081; verbose::Bool=true) =
    serve(server, Sockets.InetAddr(host, port), verbose)
serve(server::Server, host::AbstractString, port::Integer; verbose::Bool=true) =
    serve(server, Sockets.InetAddr(parse(IPAddr, host), port), verbose)
serve(server::Server, host::Union{Sockets.InetAddr, AbstractString}; verbose::Bool=true) =
    serve(server, host, verbose)

Server(h::Function, l::IO=compat_stdout(); cert::String="", key::String="", args...) = Server(HTTP.HandlerFunction(h), l; cert=cert, key=key, args...)
function Server(handler::H=HTTP.HandlerFunction(req -> HTTP.Response(200, "Hello World!")),
                logger::IO=compat_stdout(),
                ;
                cert::String="",
                key::String="",
                args...) where {H <: HTTP.Handler}
    if cert != "" && key != ""
        server = Server{https, H}(handler, logger, Channel(1), Channel(1), ServerOptions(; sslconfig=HTTP.MbedTLS.SSLConfig(cert, key), args...))
    else
        server = Server{http, H}(handler, logger, Channel(1), Channel(1), ServerOptions(; args...))
    end
    return server
end

"""
    HTTP.serve([server,] host::Union{IPAddr, String}, port::Integer; verbose::Bool=true, kwargs...)
    HTTP.serve([server,] host::InetAddr; verbose::Bool=true, kwargs...)
    HTTP.serve([server,] host::String; verbose::Bool=true, kwargs...)

Start a server listening on the provided `host:port`. `verbose` indicates whether server activity should be logged.
Optional keyword arguments allow construction of `Server` on the fly if the `server` argument isn't provided directly.
See `?HTTP.Server` for more details on server construction and supported keyword arguments.
By default, `HTTP.serve` aims to "never die", catching and recovering from all internal errors. Two methods for stopping
`HTTP.serve` include interrupting (ctrl/cmd+c) if blocking on the main task, or sending the kill signal via the server's in channel
(`put!(server.in, HTTP.Servers.KILL)`).
"""
function serve end

serve(host::IPAddr, port::Integer, args...; kwargs...) = serve(Sockets.InetAddr(host, port), args...; kwargs...)
serve(host::AbstractString, port::Integer, args...; kwargs...) = serve(parse(IPAddr, host), port, args...; kwargs...)
serve(host::AbstractString, args...; kwargs...) = serve(String(host), args...; kwargs...)
function serve(host::Union{Sockets.InetAddr, String},
               handler=req -> HTTP.Response(200, "Hello World!"),
               logger::IO=compat_stdout(),
               ;
               verbose::Bool=true,
               args...)
    server = Server(handler, logger; cert="", key="", args...)
    return serve(server, host, verbose)
end
serve(; host::IPAddr=Sockets.localhost,
        port::Integer=8081,
        handler=req -> HTTP.Response(200, "Hello World!"),
        logger::IO=compat_stdout(),
        args...) =
    serve(host, port, handler, logger; args...)

function getsslcontext(tcp, sslconfig)
    ssl = SSLContext()
    setup!(ssl, sslconfig)
    associate!(ssl, tcp)
    handshake!(ssl)
    return ssl
end

const nosslconfig = SSLConfig()
const nolimit = typemax(Int)

"""
    HTTP.listen([host=Sockets.localhost[, port=8081]]; <keyword arguments>) do http
        ...
    end

Listen for HTTP connections and execute the `do` function for each request.

Optional keyword arguments:
 - `ssl::Bool = false`, use https.
 - `require_ssl_verification = true`, pass `MBEDTLS_SSL_VERIFY_REQUIRED` to
   the mbed TLS library.
   ["... peer must present a valid certificate, handshake is aborted if
     verification failed."](https://tls.mbed.org/api/ssl_8h.html#a5695285c9dbfefec295012b566290f37)
 - `sslconfig = SSLConfig(require_ssl_verification)`
 - `pipeline_limit = 16`, number of concurrent requests per connection.
 - `reuse_limit = nolimit`, number of times a connection is allowed to be reused
                            after the first request.
 - `tcpisvalid::Function (::TCPSocket) -> Bool`, check accepted connection before
    processing requests. e.g. to implement source IP filtering, rate-limiting,
    etc.
 - `tcpref::Ref{Base.IOServer}`, this reference is set to the underlying
                                 `IOServer`. e.g. to allow closing the server.

e.g.
```
    HTTP.listen() do http::HTTP.Stream
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
    end

    HTTP.listen() do request::HTTP.Request
        @show HTTP.header(request, "Content-Type")
        @show HTTP.payload(request)
        return HTTP.Response(404)
    end
```
"""
listen(f, host::IPAddr=Sockets.localhost, port::Integer=8081; kw...) = listen(f, Sockets.InetAddr(host, port); kw...)
listen(f, host::AbstractString, port::Integer; kw...) = listen(f, parse(IPAddr, host), port; kw...)
listen(f, host::AbstractString; kw...) = listen(f, string(host); kw...)

function listen(f::Function,
                host::Union{Sockets.InetAddr, String},
                ;
                ssl::Bool=false,
                require_ssl_verification::Bool=true,
                sslconfig::SSLConfig=nosslconfig,
                pipeline_limit::Int=ConnectionPool.default_pipeline_limit,
                tcpisvalid::Function=(tcp; kw...)->true,
                tcpref::Ref=Ref{Base.IOServer}(),
                reuseaddr::Bool=false,
                kw...)

    if sslconfig === nosslconfig
        sslconfig = SSLConfig(require_ssl_verification)
    end

    @info "Listening on: $host"
    if isassigned(tcpref)
        tcpserver = tcpref[]
    elseif reuseaddr
        @static if VERSION < v"0.7.0-alpha.0"
            tcpserver = Sockets.TCPServer(Base.Libc.malloc(Base._sizeof_uv_tcp), Base.StatusUninit)
            err = ccall(:uv_tcp_init_ex, Cint, (Ptr{Cvoid}, Ptr{Cvoid}, Cuint),
                        Base.eventloop(), tcpserver.handle, 2)
            Base.uv_error("failed to create tcpserver server", err)
            tcpserver.status = Base.StatusInit
            if Sys.KERNEL == :Linux || Sys.KERNEL in (:Darwin, :Apple)
                rc = ccall(:jl_tcp_reuseport, Int32, (Ptr{Cvoid},), tcpserver.handle)
                Sockets.bind(tcpserver, host.host, host.port; reuseaddr=true)
            else
                @warn "reuseaddr=true may not be supported on this platform: $(Sys.KERNEL)"
                Sockets.bind(tcpserver, host.host, host.port; reuseaddr=true)
            end
        else
            tcpserver = Sockets.TCPServer(; delay=false)
            if Sys.islinux() || Sys.isapple()
                rc = ccall(:jl_tcp_reuseport, Int32, (Ptr{Cvoid},), tcpserver.handle)
                Sockets.bind(tcpserver, host.host, host.port; reuseaddr=true)
            else
                @warn "reuseaddr=true may not be supported on this platform: $(Sys.KERNEL)"
                Sockets.bind(tcpserver, host.host, host.port; reuseaddr=true)
            end
        end
        Sockets.listen(tcpserver)
    else
        tcpserver = Sockets.listen(host)
        tcpref[] = tcpserver
    end

    try
        while isopen(tcpserver)
            try
                io = accept(tcpserver)
            catch e
                if e isa Base.UVError
                    @warn "$e"
                    break
                else
                    rethrow(e)
                end
            end
            if !tcpisvalid(io; kw...)
                @info "Accept-Reject:  $io"
                close(io)
                continue
            end
            io = ssl ? getsslcontext(io, sslconfig) : io
            if host isa Sockets.InetAddr # build debugging info
                hostname = string(host.host)
                hostport = string(host.port)
            else
                hostname = string(host)
                hostport = ""
            end
            let io = Connection(hostname, hostport, pipeline_limit, 0, io)
                @info "Accept:  $io"
                @async try
                    handle_connection(f, io; kw...)
                catch e
                    @error "Error:   $io" e catch_stacktrace()
                finally
                    close(io)
                    @info "Closed:  $io"
                end
            end
        end
    catch e
        if typeof(e) <: InterruptException
            @warn "Interrupted: listen($host)"
        else
            rethrow(e)
        end
    finally
        close(tcpserver)
    end

    return
end


"""
Start a timeout monitor task to close the `Connection` if it is inactive.
Create a `Transaction` object for each HTTP Request received.
"""
function handle_connection(f::Function, c::Connection;
                           reuse_limit::Int=nolimit,
                           readtimeout::Int=0, kw...)

    wait_for_timeout = Ref{Bool}(true)
    if readtimeout > 0
        @async while wait_for_timeout[]
            @show inactiveseconds(c)
            if inactiveseconds(c) > readtimeout
                @warn "Timeout: $c"
                writeheaders(c.io, Response(408, ["Connection" => "close"]))
                close(c)
                break
            end
            sleep(8 + rand() * 4)
        end
    end

    try
        count = 0
        while isopen(c)
            io = Transaction(c)
            handle_transaction(f, io; final_transaction=(count == reuse_limit),
                                      kw...)
            if count == reuse_limit
                close(c)
            end
            count += 1
        end
    finally
        wait_for_timeout[] = false
    end
    return
end


"""
Create a `HTTP.Stream` and parse the Request headers from a `HTTP.Transaction`.
If there is a parse error, send an error Response.
Otherwise, execute stream processing function `f`.
"""
function handle_transaction(f::Function, t::Transaction;
                            final_transaction::Bool=false,
                            verbose::Bool=false, kw...)

    request = HTTP.Request()
    http = Streams.Stream(request, t)

    try
        startread(http)
    catch e
        # @show typeof(e)
        # @show fieldnames(e)
        if e isa EOFError && isempty(request.method)
            return
# FIXME https://github.com/JuliaWeb/HTTP.jl/pull/178#pullrequestreview-92547066
#        elseif !isopen(http)
#            @warn "Connection closed"
#            return
        elseif e isa HTTP.ParseError
            @error e
            status = e.code == :HEADER_SIZE_EXCEEDS_LIMIT  ? 413 : 400
            write(t, Response(status, body = string(e.code)))
            close(t)
            return
        else
            rethrow(e)
        end
    end

    if verbose
        @info http.message
    end

    response = request.response
    response.status = 200
    if final_transaction || hasheader(request, "Connection", "close")
        setheader(response, "Connection" => "close")
    end

    @async try
        handle_stream(f, http)
    catch e
        if isioerror(e)
            @warn e
        else
            @error e catch_stacktrace()
        end
        close(t)
    end
    return
end

"""
Execute stream processing function `f`.
If there is an error and the stream is still open,
send a 500 response with the error message.

Close the `Stream` for read and write (in case `f` has not already done so).
"""
function handle_stream(f::Function, http::Stream)

    try
        if applicable(f, http)
            f(http)
        else
            handle_request(f, http)
        end
    catch e
        if isopen(http) && !iswritable(http)
            @error e catch_stacktrace()
            http.message.response.status = 500
            startwrite(http)
            write(http, sprint(showerror, e))
        else
            rethrow(e)
        end
    end

    closeread(http)
    closewrite(http)
    return
end

"""
Execute Request processing function `f(::HTTP.Request) -> HTTP.Response`.
"""
function handle_request(f::Function, http::Stream)
    request::HTTP.Request = http.message
    request.body = read(http)
    request.response::HTTP.Response = f(request)
    startwrite(http)
    write(http, request.response.body)
    return
end

end # module
