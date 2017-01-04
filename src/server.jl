#TODO:
 # allow limits on header sizes/body sizes?
 # server send 505 for unsupported HTTP versions: https://tools.ietf.org/html/rfc7230#section-2.6
 # reject requests w/ empty HOST: https://tools.ietf.org/html/rfc7230#section-2.7.1
 # ignore "userinfo" in URI: https://tools.ietf.org/html/rfc7230#section-2.7.1
 # http_parser handles URI decoding?
 # A recipient that receives whitespace between the start-line and the first header field MUST reject the message: https://tools.ietf.org/html/rfc7230#section-3
 # reject a received response: https://tools.ietf.org/html/rfc7230#section-3.1
 # invalid request line should respond w/ 400: https://tools.ietf.org/html/rfc7230#section-3.1.1
 # allow limits on uri size, default = 8000, return 414: https://tools.ietf.org/html/rfc7230#section-3.1.1
 # request/response timeout abilities
 # add in "events" handling
 # dealing w/ cookies
 # reverse proxy?
 # keepalive offload?
 # auto-caching?
 # auto-compression?
 # rate-limiting?
 # advanced load-balancing?
 # session persistence?
 # health report of server?
 # http authentication subrequests?
 # ip access control lists?
 # JWT authentication?
 # live activity monitoring
 # live reoconfigure?
 # handle "many slow client connections?"
 # memory/performance profiling for thousands of concurrent requests?
 # fault tolerance?
 # handle IPv6?
 # flv & mp4 streaming?
 # URL rewriting?
 # bandwidth throttling
 # server-side includes?
 # IP address-based geolocation
 # user-tracking
 # WebDAV
 # FastCGI
 # default handler:
   # handle all common http requests/etc.
   # just map straight to filesystem
 # appropriate size limits/timeouts for different parts of request messages
 # handle Expect 100 Continue
 # special case OPTIONS method like go?
 # handle redirects
   # read through RFCs, writing tests
 # support auto-decompress, deflate, gunzip
 # buffer re-use for server/client wire-reading

type Server{T <: Scheme}
    handler::Function
    logger::IO
    queue::RemoteChannel{Channel{TCPSocket}}
    tlsconfig::TLS.SSLConfig

    function Server(handler::Function, logger::IO, maxconn::Int, tlsconfig::TLS.SSLConfig=TLS.SSLConfig())
        new{T}(handler, logger, RemoteChannel(()->Channel{TCPSocket}(maxconn)), tlsconfig)
    end
end

function process!{T}(p, conn, logger, socket::T, handler, parser::Parser{RequestParser})
    println(logger, "Processing on ServerWorker=$p, conn=$conn...")
    try
        while isopen(socket)
            # if no data after 10 seconds, break out
            # allow this as server setting
            buffer = @timeout 180 readavailable(socket) begin
                println(logger, "Connection timed out waiting for request on ServerWorker=$p, conn=$conn")
                break
            end
            http_parser_execute(parser, DEFAULT_REQUEST_PARSER_SETTINGS, buffer, length(buffer))
            if errno(parser) != 0
                # error in parsing the http request
                println(logger, "http-parser error on ServerWorker=$p, conn=$conn...")
                break
            elseif parser.data.messagecomplete
                request = parser.data.val
                response = Response()
                println(logger, "Received request on ServerWorker=$p, conn=$conn\n")
                show(logger, request)
                try
                    response = handler(request, response)
                catch e
                    response = Response(500)
                    println(logger, e)
                end
                response.headers["Connection"] = request.keepalive ? "keep-alive" : "close"
                println(logger, "Responding with response on ServerWorker=$p, conn=$conn\n")
                show(logger, response)
                println(logger)
                write(socket, response)
                request.keepalive || close(socket)
            end
        end
    finally
        close(socket)
    end
    println(logger, "Finished processing on ServerWorker=$p, conn=$conn")
    return nothing
end

function ServerWorker{T <: Scheme}(p::Int, ::Type{T}, queue, handler, tlsconfig)
    logger = STDOUT
    println(logger, "ServerWorker=$p initialized...")
    conn = 1
    while true
        try
            parser = Parser(Request)
            tcp = take!(queue)
            println(logger, "Took TCPSocket off the server queue on ServerWorker=$p...")
            if T == http
                let conn=conn, tcp=tcp, parser=parser
                    @async process!(p, conn, logger, tcp, handler, parser)
                end
            else
                let conn=conn, tcp=tcp, parser=parser
                    @async process!(p, conn, logger, initTLS!(T, tcp, tlsconfig), handler, parser)
                end
            end
        catch e
            println(logger, "Error encountered on ServerWorker=$p")
            println(logger, e)
            continue
        end
        conn += 1
    end
    println(logger, "ServerWorker=$p shutting down...")
    return
end

function initTLS!(::Type{https}, tcp, tlsconfig)
    try
        tls = TLS.SSLContext()
        TLS.setup!(tls, tlsconfig)
        TLS.associate!(tls, tcp)
        TLS.handshake!(tls)
    catch e
        println("Error establishing SSL connection: ", e)
        close(tcp)
    end
    return tls
end

# main process event loop; listens on host:port, starts ServerWorkers to process requests
# accepts new TCP connections and puts them in server.queue to be processed
function serve{T}(server::Server{T}, host, port)
    println(server.logger, "Starting workers for request processing...")
    workers = Future[@spawnat(p, ServerWorker(p, T, server.queue, server.handler, server.tlsconfig)) for p in procs()]
    println(server.logger, "Starting server to listen on: $(host):$(port)")
    tcpserver = listen(host, port)
    while true
        tcp = TCPSocket()
        try
            # accept blocks until a new connection is detected
            println("going to accept...")
            accept(tcpserver, tcp)
            println("accepted...")
            println(server.logger, "New tcp connection accepted, queuing...")
            put!(server.queue, tcp)
        catch e
            if typeof(e) <: InterruptException
                println(server.logger, "Interrupt detected, shutting down...")
                interrupt()
                break
            else
                if !isopen(tcpserver)
                    println(server.logger, "Server TCPServer is closed, shutting down...")
                    # Server was closed while waiting to accept client. Exit gracefully.
                    interrupt()
                    break
                end
                println(server.logger, "Error encountered: $e")
                println(server.logger, "Resuming serving...")
            end
        end
    end
    close(tcpserver)
    return
end

const DEFAULT_MAX_CONNECTIONS = 10000

function serve(host::IPAddr, port::Int,
               handler=(req, rep) -> Response("Hello World!"),
               logger=STDOUT;
               cert::String="",
               key::String="",
               maxconn::Int=DEFAULT_MAX_CONNECTIONS)
    if cert != "" && key != ""
        server = Server{https}(handler, logger, maxconn, TLS.SSLConfig(cert, key))
    else
        server = Server{http}(handler, logger, maxconn)
    end

    return serve(server, host, port)
end
serve(; host::IPAddr=IPv4(127,0,0,1),
        port::Int=8081,
        handler::Function=(req, rep) -> Response("Hello World!"),
        logger::IO=STDOUT,
        cert::String="",
        key::String="",
        maxconn::Int=DEFAULT_MAX_CONNECTIONS) =
    serve(host, port, handler, logger; cert=cert, key=key, maxconn=maxconn)
