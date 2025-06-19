module Nitrogen

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
objects as inputs and returns the, potentially modified, `Response`. `logger` indicates where logging output should be directed.
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

    Server{T, H}(handler::H, logger::IO=STDOUT, ch=Channel(1), ch2=Channel(1), options=ServerOptions()) where {T, H} = new{T, H}(handler, logger, ch, ch2, options)
end

backtrace() = sprint(Base.show_backtrace, catch_backtrace())

function process!(server::Server{T, H}, parser, request, i, tcp, rl, starttime, verbose) where {T, H}
    handler, logger, options = server.handler, server.logger, server.options
    startedprocessingrequest = error = shouldclose = alreadysent100continue = false
    rate = Float64(server.options.ratelimit.num)
    rl.allowance += 1.0 # because it was just decremented right before we got here
    HTTP.@log "processing on connection i=$i..."
    try
        tsk = @async begin
            while isopen(tcp)
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
                    HTTP.@log "reading request bytes with readtimeout=$(options.readtimeout)"
                    # EH:
                    buffer = try
                        readavailable(tcp)
                    catch e
                        UInt8[]
                    end
                    length(buffer) > 0 || break
                    starttime[] = time() # reset the timeout while still receiving bytes
                    err = HTTP.@catcherr HTTP.ParsingError HTTP.parse!(parser, buffer)
                    startedprocessingrequest = true
                    if err != nothing
                        # error in parsing the http request
                        HTTP.@log "error parsing request on connection i=$i: $(HTTP.ParsingErrorCodeMap[err.code])"
                        if err.code == HTTP.HPE_INVALID_VERSION
                            response = HTTP.Response(505)
                        elseif err.code == HTTP.HPE_HEADER_OVERFLOW
                            response = HTTP.Response(431)
                        elseif err.code == HTTP.HPE_URI_OVERFLOW
                            response = HTTP.Response(414)
                        elseif err.code == HTTP.HPE_BODY_OVERFLOW
                            response = HTTP.Response(413)
                        elseif err.code == HTTP.HPE_INVALID_METHOD
                            response = HTTP.Response(405)
                        else
                            response = HTTP.Response(400)
                        end
                        error = true
                    elseif HTTP.headerscomplete(parser) && Base.get(HTTP.headers(request), "Expect", "") == "100-continue" && !alreadysent100continue
                        if options.support100continue
                            HTTP.@log "sending 100 Continue response to get request body"
                            # EH:
                            try
                                write(tcp, HTTP.Response(100), options)
                            catch e
                                HTTP.@log e
                                error = true
                            end
                            parser.state = HTTP.s_body_identity
                            alreadysent100continue = true
                            continue
                        else
                            response = HTTP.Response(417)
                            error = true
                        end
                    elseif HTTP.upgrade(parser)
                        @show String(collect(HTTP.extra(parser)))
                        HTTP.@log "received upgrade request on connection i=$i"
                        response = HTTP.Response(501, "upgrade requests are not currently supported")
                        error = true
                    elseif HTTP.messagecomplete(parser)
                        HTTP.@log "received request on connection i=$i"

                        request.method = parser.method
                        request.uri = parser.url
                        request.major = parser.major
                        request.minor = parser.minor

                        verbose && (show(logger, request); println(logger, ""))
                        try
                            response = Handlers.handle(handler, request, HTTP.Response())
                        catch e
                            response = HTTP.Response(500)
                            error = true
                            showerror(logger, e)
                            println(logger, backtrace())
                        end
                        if HTTP.http_should_keep_alive(parser) && !error
                            if !any(x->x[1] == "Connection", response.headers)
                                push!(response.headers, "Connection" => "keep-alive")
                            end
                            HTTP.reset!(parser)
                            request = HTTP.Request()
                            parser.onbodyfragment = x->write(request.body, x)
                            parser.onheader = x->HTTP.appendheader(request, x)
                        else
                            if !any(x->x[1] == "Connection", response.headers)
                                push!(response.headers, "Connection" => "close")
                            end
                            shouldclose = true
                        end
                        if !error
                            HTTP.@log "responding with response on connection i=$i"
                            verbose && (show(logger, response); println(logger, ""))

                            try
                                write(tcp, response, options)
                            catch e
                                HTTP.@log e
                                error = true
                            end
                        end
                        (error || shouldclose) && break
                        startedprocessingrequest = alreadysent100continue = false
                    end
                end
            end
        end
        timeout = options.readtimeout
        while !istaskdone(tsk) && (time() - starttime[] < timeout)
            sleep(0.001)
        end
        if !istaskdone(tsk)
            HTTP.@log "connection i=$i timed out waiting for request bytes"
            startedprocessingrequest && write(tcp, HTTP.Response(408), options)
        end
    finally
        close(tcp)
    end
    HTTP.@log "finished processing on connection i=$i"
    return nothing
end

initTLS!(::Type{http}, tcp, tlsconfig) = return tcp
function initTLS!(::Type{https}, tcp, tlsconfig)
    try
        tls = HTTP.MbedTLS.SSLContext()
        HTTP.MbedTLS.setup!(tls, tlsconfig)
        HTTP.MbedTLS.associate!(tls, tcp)
        HTTP.MbedTLS.handshake!(tls)
        return tls
    catch e
        close(tcp)
        error("Error establishing SSL connection: $e")
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

function serve(server::Server{T, H}, host, port, verbose) where {T, H}
    logger = server.logger
    HTTP.@log "starting server to listen on: $(host):$(port)"
    tcpserver = listen(host, port)
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
        p = HTTP.Parser()
        request = HTTP.Request()
        p.onbodyfragment = x->write(request.body, x)
        p.onheader = x->HTTP.appendheader(request, x)

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
                let server=server, p=p, request=request, i=i, tcp=tcp, rl=rl
                    @async process!(server, p, request, i, initTLS!(T, tcp, server.options.tlsconfig::HTTP.MbedTLS.SSLConfig), rl, Ref{Float64}(time()), verbose)
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

serve(server::Server, host=IPv4(127,0,0,1), port=8081; verbose::Bool=true) = serve(server, host, port, verbose)
function serve(host::IPAddr, port::Int,
                   handler=(req, rep) -> HTTP.Response("Hello World!"),
                   logger::I=STDOUT;
                   cert::String="",
                   key::String="",
                   verbose::Bool=true,
                   args...) where {I}
    server = Server(handler, logger; cert=cert, key=key, args...)
    return serve(server, host, port, verbose)
end
serve(; host::IPAddr=IPv4(127,0,0,1),
        port::Int=8081,
        handler=(req, rep) -> HTTP.Response("Hello World!"),
        logger::IO=STDOUT,
        cert::String="",
        key::String="",
        verbose::Bool=true,
        args...) =
    serve(host, port, handler, logger; cert=cert, key=key, verbose=verbose, args...)

#= Does the parser need to see an EOF to find the end of the message? =#
function http_message_needs_eof(parser)
    #= See RFC 2616 section 4.4 =#
    if (isrequest(parser) || # FIXME request never needs EOF ??
        div(parser.status, 100) == 1 || #= 1xx e.g. Continue =#
        parser.status == 204 ||     #= No Content =#
        parser.status == 304 ||     #= Not Modified =#
        parser.isheadresponse)       #= response to a HEAD request =#
        return false
    end

    if (parser.flags & F_CHUNKED > 0) || parser.content_length != ULLONG_MAX
        return false
    end

    return true
end

function http_should_keep_alive(parser)
    if parser.major > 0 && parser.minor > 0
        #= HTTP/1.1 =#
        if parser.flags & F_CONNECTION_CLOSE > 0
            return false
        end
    else
        #= HTTP/1.0 or earlier =#
        if !(parser.flags & F_CONNECTION_KEEP_ALIVE > 0)
            return false
        end
    end

  return !http_message_needs_eof(parser)
end


end # module
