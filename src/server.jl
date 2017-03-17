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
type ServerOptions
    tlsconfig::TLS.SSLConfig
    readtimeout::Float64
    ratelimit::Rational{Int}
    maxuri::Int64
    maxheader::Int64
    maxbody::Int64
    support100continue::Bool
end

ServerOptions(; tlsconfig::TLS.SSLConfig=TLS.SSLConfig(true),
                readtimeout::Float64=180.0,
                ratelimit::Rational{Int64}=Int64(5)//Int64(1),
                maxuri::Int64=DEFAULT_MAX_URI,
                maxheader::Int64=DEFAULT_MAX_HEADER,
                maxbody::Int64=DEFAULT_MAX_BODY,
                support100continue::Bool=true) =
    ServerOptions(tlsconfig, readtimeout, ratelimit, maxbody, maxuri, maxheader, support100continue)

"""
    Server(handler, logger::IO=STDOUT; kwargs...)

An http/https server. Supports listening on a `host` and `port` via the `HTTP.serve(server, host, port)` function.
`handler` is a function of the form `f(::Request, ::Response) -> Response`, i.e. it takes both a `Request` and pre-built `Response`
objects as inputs and returns the, potentially modified, `Response`. `logger` indicates where logging output should be directed.
When `HTTP.serve` is called, it aims to "never die", catching and recovering from all internal errors. To forcefully stop, one can obviously
kill the julia process, interrupt (ctrl/cmd+c) if main task, or send the kill signal over a server in channel like:
`put!(server.in, HTTP.KILL)`.

Supported keyword arguments include:
  * `cert`: if https, the cert file to use, as passed to `TLS.SSLConfig(cert, key)`
  * `key`: if https, the key file to use, as passed to `TLS.SSLConfig(cert, key)`
  * `tlsconfig`: pass in an already-constructed `TLS.SSLConfig` instance
  * `readtimeout`: how long a client connection will be left open without receiving any bytes
  * `ratelimit`: a `Rational{Int}` of the form `5//1` indicating how many `messages//second` should be allowed per client IP address; requests exceeding the rate limit will be dropped
  * `maxuri`: the maximum size in bytes that a request uri can be; default 8000
  * `maxheader`: the maximum size in bytes that request headers can be; default 8kb
  * `maxbody`: the maximum size in bytes that a request body can be; default 4gb
  * `support100continue`: a `Bool` indicating whether `Expect: 100-continue` headers should be supported for delayed request body sending; default = `true`
"""
type Server{T <: Scheme, I <: IO}
    handler::Function
    logger::I
    in::Channel{Any}
    out::Channel{Any}
    options::ServerOptions

    (::Type{Server{T, I}}){T, I}(handler::Function, logger::I, ch=Channel(1), ch2=Channel(1), options=ServerOptions()) = new{T, I}(handler, logger, ch, ch2, options)
end

function process!{T, I}(server::Server{T, I}, parser, request, i, tcp, rl, starttime, verbose)
    handler, logger, options = server.handler, server.logger, server.options
    startedprocessingrequest = error = alreadysent100continue = false
    rate = Float64(server.options.ratelimit.num)
    rl.allowance += 1.0 # because it was just decremented right before we got here
    response = Response()
    @log(verbose, logger, "processing on connection i=$i...")
    try
        tsk = @async begin
            request.body.task = current_task()
            while isopen(tcp)
                update!(rl, server.options.ratelimit)
                if rl.allowance > rate
                    @log(verbose, server.logger, "throttling on connection i=$i")
                    rl.allowance = rate
                end
                if rl.allowance < 1.0
                    @log(verbose, server.logger, "sleeping on connection i=$i due to rate limiting")
                    sleep(1.0)
                else
                    rl.allowance -= 1.0
                    @log(verbose, server.logger, "reading request bytes with readtimeout=$(options.readtimeout)")
                    buffer = readavailable(tcp)
                    length(buffer) > 0 || break
                    starttime[] = time() # reset the timeout while still receiving bytes
                    errno, headerscomplete, messagecomplete, upgrade = HTTP.parse!(request, parser, buffer)
                    startedprocessingrequest = true
                    if errno != HPE_OK
                        # error in parsing the http request
                        @log(verbose, logger, "error parsing request on connection i=$i: $(ParsingErrorCodeMap[errno])")
                        if errno == HPE_INVALID_VERSION
                            response.status = 505
                        elseif errno == HPE_HEADER_OVERFLOW
                            response.status = 431
                        elseif errno == HPE_URI_OVERFLOW
                            response.status = 414
                        elseif errno == HPE_BODY_OVERFLOW
                            response.status = 413
                        elseif errno == HPE_INVALID_METHOD
                            response.status = 405
                        else
                            response.status = 400
                        end
                        error = true
                    elseif headerscomplete && Base.get(HTTP.headers(request), "Expect", "") == "100-continue" && !alreadysent100continue
                        if options.support100continue
                            @log(verbose, logger, "sending 100 Continue response to get request body")
                            write(tcp, Response(100), options)
                            parser.state = s_body_identity
                            alreadysent100continue = true
                            continue
                        else
                            response.status = 417
                            error = true
                        end
                    elseif length(upgrade) > 0
                        @log(verbose, logger, "received upgrade request on connection i=$i")
                        response.status = 501
                        response.body = FIFOBuffer("upgrade requests are not currently supported")
                        error = true
                    elseif messagecomplete
                        @log(verbose, logger, "received request on connection i=$i")
                        verbose && (show(logger, request, RequestOptions()); println(logger))
                        try
                            response = handler(request, response)
                        catch e
                            response.status = 500
                            error = true
                            @log(verbose, logger, e)
                        end
                        if http_should_keep_alive(parser, request) && !error
                            get!(HTTP.headers(response), "Connection", "keep-alive")
                            reset!(parser)
                            request = Request()
                        else
                            get!(HTTP.headers(response), "Connection", "close")
                            close(tcp)
                        end
                        @log(verbose, logger, "responding with response on connection i=$i")
                        verbose && (show(logger, response, options); println(logger))
                        write(tcp, response, options)
                        error && break
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
            @log(verbose, logger, "connection i=$i timed out waiting for request bytes")
            startedprocessingrequest && write(tcp, Response(408), options)
        end
    finally
        close(tcp)
    end
    @log(verbose, logger, "finished processing on connection i=$i")
    return nothing
end

initTLS!(::Type{http}, tcp, tlsconfig) = return tcp
function initTLS!(::Type{https}, tcp, tlsconfig)
    try
        tls = TLS.SSLContext()
        TLS.setup!(tls, tlsconfig)
        TLS.associate!(tls, tcp)
        TLS.handshake!(tls)
        return tls
    catch e
        close(tcp)
        error("Error establishing SSL connection: $e")
    end
end

type RateLimit
    allowance::Float64
    lastcheck::DateTime
end

function update!(rl::RateLimit, ratelimit)
    current = now()
    timepassed = float(Dates.value(current - rl.lastcheck)) / 1000.0
    rl.lastcheck = current
    rl.allowance += timepassed * ratelimit
    return nothing
end

@enum Signals KILL

function serve{T, I}(server::Server{T, I}, host, port, verbose)
    @log(verbose, server.logger, "starting server to listen on: $(host):$(port)")
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
        p = Parser()
        request = Request()
        try
            # accept blocks until a new connection is detected
            tcp = accept(tcpserver)
            ip = getsockname(tcp)[1]
            rl = get!(ratelimits, ip, RateLimit(rate, now()))
            update!(rl, server.options.ratelimit)
            if rl.allowance > rate
                @log(verbose, server.logger, "throttling $ip")
                rl.allowance = rate
            end
            if rl.allowance < 1.0
                @log(verbose, server.logger, "discarding connection from $ip due to rate limiting")
                close(tcp)
            else
                rl.allowance -= 1.0
                @log(verbose, server.logger, "new tcp connection accepted, reading request...")
                let server=server, p=p, request=request, i=i, tcp=tcp, rl=rl
                    @async process!(server, p, request, i, initTLS!(T, tcp, server.options.tlsconfig::TLS.SSLConfig), rl, Ref{Float64}(time()), verbose)
                end
                i += 1
            end
        catch e
            if typeof(e) <: InterruptException
                @log(verbose, server.logger, "interrupt detected, shutting down...")
                interrupt()
                break
            else
                if !isopen(tcpserver)
                    @log(verbose, server.logger, "server TCPServer is closed, shutting down...")
                    # Server was closed while waiting to accept client. Exit gracefully.
                    interrupt()
                    break
                end
                @log(verbose, server.logger, "error encountered: $e")
                @log(verbose, server.logger, "resuming serving...")
            end
        end
    end
    close(tcpserver)
    return
end

function Server{I}(handler=(req, rep) -> Response("Hello World!"),
               logger::I=STDOUT;
               cert::String="",
               key::String="",
               args...)
    if cert != "" && key != ""
        server = Server{https, I}(handler, logger, Channel(1), Channel(1), ServerOptions(; tlsconfig=TLS.SSLConfig(cert, key), args...))
    else
        server = Server{http, I}(handler, logger, Channel(1), Channel(1), ServerOptions(args...))
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
function serve{I}(host::IPAddr, port::Int,
                   handler=(req, rep) -> Response("Hello World!"),
                   logger::I=STDOUT;
                   cert::String="",
                   key::String="",
                   verbose::Bool=true,
                   args...)
    server = Server(handler, logger; cert=cert, key=key, args...)
    return serve(server, host, port, verbose)
end
serve(; host::IPAddr=IPv4(127,0,0,1),
        port::Int=8081,
        handler::Function=(req, rep) -> Response("Hello World!"),
        logger::IO=STDOUT,
        cert::String="",
        key::String="",
        verbose::Bool=true,
        args...) =
    serve(host, port, handler, logger; cert=cert, key=key, verbose=verbose, args...)
