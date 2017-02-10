#TODO:
 # add in "events" handling
 # dealing w/ cookies
 # reverse proxy?
 # auto-compression
 # rate-limiting
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
 # allow disabling Expect: 100-continue support (return 417 response instead)
 # special case OPTIONS method like go?
 # buffer re-use for server/client wire-reading
 # allow setting max request body size accepted (response 413)
 # allow setting max uri size (response 414)
 # easter egg (response 418)
type ServerOptions
    tlsconfig::TLS.SSLConfig
    readtimeout::Float64
    ratelimit::Rational{Int}
    maxbody::Int
    maxuri::Int
    maxheader::Int
    support100continue::Bool
end

ServerOptions(; tlsconfig::TLS.SSLConfig=TLS.SSLConfig(true),
                readtimeout::Float64=180.0,
                ratelimit::Rational{Int}=5//1,
                maxbody::Int=2^32,
                maxuri::Int=8000,
                maxheader::Int=80 * 1024,
                support100continue::Bool=true) =
    ServerOptions(tlsconfig, readtimeout, ratelimit, maxbody, maxuri, maxheader, support100continue)

type Server{T <: Scheme, I <: IO}
    handler::Function
    logger::I
    options::ServerOptions

    Server(handler::Function, logger::I,options=ServerOptions()) = new{T, I}(handler, logger, options)
end

function process!{T, I}(server::Server{T, I}, parser, request, i, tcp, rl)
    handler, logger, options = server.handler, server.logger, server.options
    startedprocessingrequest = error = false
    rate = Float64(server.options.ratelimit.num)
    rl.allowance += 1.0 # because it was just decremented right before we got here
    response = Response()
    @log(true, logger, "processing on connection i=$i...")
    try
        while isopen(tcp)
            update!(rl)
            @log(true, server.logger, """
                Rate-Limiting = $rl:
                lastcheck: $(rl.lastcheck)
                  current: $current
               timepassed: $timepassed
        current allowance: $(rl.allowance)
            """)
            if rl.allowance > rate
                @log(true, server.logger, "throttling on connection i=$i")
                rl.allowance = rate
            end
            if rl.allowance < 1.0
                @log(true, server.logger, "sleeping on connection i=$i due to rate limiting")
                sleep(1.0)
            else
                rl.allowance -= 1.0
                @log(true, server.logger, "reading request bytes with readtimeout=$(options.readtimeout)")
                buffer = @timeout options.readtimeout readavailable(tcp) begin
                    @log(true, logger, "connection i=$i timed out waiting for request bytes")
                    startedprocessingrequest || break
                    error = true
                    response.status = 408
                end
                errno, headerscomplete, messagecomplete, upgrade = HTTP.parse!(request, parser, buffer)
                startedprocessingrequest = true
                if errno != HPE_OK
                    # error in parsing the http request
                    @log(true, logger, "error parsing request on connection i=$i: $(ParsingErrorCodeMap[errno])")
                    if errno == HPE_INVALID_VERSION
                        reponse.status = 505
                    elseif errno == HPE_HEADER_OVERFLOW
                        reponse.status = 431
                    elseif errno == HPE_INVALID_METHOD
                        reponse.status = 405
                    else
                        reponse.status = 400
                    end
                    error = true
                elseif headerscomplete && Base.get(HTTP.headers(request), "Expect", "") == "100-continue"
                    if options.support100continue
                        @log(true, logger, "sending 100 Continue response to get request body")
                        write(tcp, Response(100), options)
                        continue
                    else
                        response.status = 417
                        error = true
                    end
                elseif length(upgrade) > 0
                    @log(true, logger, "received upgrade request on connection i=$i")
                    response.status = 501
                    response.body = FIFOBuffer("upgrade requests are not currently supported")
                    error = true
                elseif messagecomplete
                    @log(true, logger, "received request on connection i=$i")
                    # show(logger, request)
                    try
                        response = handler(request, response)
                    catch e
                        response.status = 500
                        error = true
                        @log(true, logger, e)
                    end
                    if http_should_keep_alive(parser, request) && !error
                        get!(HTTP.headers(response), "Connection", "keep-alive")
                        reset!(parser)
                        request = Request()
                    else
                        get!(HTTP.headers(response), "Connection", "close")
                        close(tcp)
                    end
                    @log(true, logger, "responding with response on connection i=$i")
                    # show(logger, response)
                    write(tcp, response, options)
                    error && break
                    startedprocessingrequest = false
                end
            end
        end
    finally
        close(tcp)
    end
    @log(true, logger, "finished processing on connection i=$i")
    return nothing
end

initTLS!(::Type{http}, tcp, tlsconfig) = return tcp
function initTLS!(::Type{https}, tcp, tlsconfig)
    try
        tls = TLS.SSLContext()
        TLS.setup!(tls, tlsconfig)
        TLS.associate!(tls, tcp)
        TLS.handshake!(tls)
    catch e
        close(tcp)
        error("Error establishing SSL connection: $e")
    end
    return tls
end

type RateLimit
    allowance::Float64
    lastcheck::DateTime
end

function update!(rl::RateLimit)
    current = now()
    timepassed = float(Dates.value(current - rl.lastcheck)) / 1000.0
    rl.lastcheck = current
    rl.allowance += timepassed * server.options.ratelimit
    return nothing
end

function serve{T, I}(server::Server{T, I}, host, port)
    @log(true, server.logger, "starting server to listen on: $(host):$(port)")
    tcpserver = listen(host, port)
    ratelimits = Dict{IPAddr, RateLimit}()
    rate = Float64(server.options.ratelimit.num)
    i = 0
    while true
        p = Parser()
        request = Request()
        try
            # accept blocks until a new connection is detected
            tcp = accept(tcpserver)
            ip = getsockname(tcp)[1]
            rl = get!(ratelimits, ip, RateLimit(rate, now()))
            update!(rl)
            @log(true, server.logger, """
                Rate-Limiting = $rl:
                   tcp ip: $ip
                lastcheck: $(rl.lastcheck)
                  current: $current
               timepassed: $timepassed
        current allowance: $(rl.allowance)
            """)
            if rl.allowance > rate
                @log(true, server.logger, "throttling $ip")
                rl.allowance = rate
            end
            if rl.allowance < 1.0
                @log(true, server.logger, "discarding connection from $ip due to rate limiting")
                close(tcp)
            else
                rl.allowance -= 1.0
                @log(true, server.logger, "new tcp connection accepted, reading request...")
                let p=p, request=request, i=i, tcp=tcp, rl=rl
                    @async process!(server, p, request, i, initTLS!(T, tcp, server.options.tlsconfig::TLS.SSLConfig), rl)
                end
                i += 1
            end
        catch e
            if typeof(e) <: InterruptException
                @log(true, server.logger, "interrupt detected, shutting down...")
                interrupt()
                break
            else
                if !isopen(tcpserver)
                    @log(true, server.logger, "server TCPServer is closed, shutting down...")
                    # Server was closed while waiting to accept client. Exit gracefully.
                    interrupt()
                    break
                end
                @log(true, server.logger, "error encountered: $e")
                @log(true, server.logger, "resuming serving...")
            end
        end
    end
    close(tcpserver)
    return
end

function serve{I}(host::IPAddr, port::Int,
               handler=(req, rep) -> Response("Hello World!"),
               logger::I=STDOUT;
               cert::String="",
               key::String="",
               args...)
    if cert != "" && key != ""
        server = Server{https, I}(handler, logger, ServerOptions(tlsconfig=TLS.SSLConfig(cert, key), args...))
    else
        server = Server{http, I}(handler, logger, ServerOptions(args...))
    end
    return serve(server, host, port)
end
serve(; host::IPAddr=IPv4(127,0,0,1),
        port::Int=8081,
        handler::Function=(req, rep) -> Response("Hello World!"),
        logger::IO=STDOUT,
        cert::String="",
        key::String="",
        args...) =
    serve(host, port, handler, logger; cert=cert, key=key, args...)
