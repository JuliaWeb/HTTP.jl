# High-level
 # Bind TCPServer and listen to host:port
 # Outer event loop:
    # accept TCPSocket connections
    # @async the connection off into it's own green thread
      # initialize a new HTTP Parser for this new TCPSocket connection
      # continue reading data off connection and passing it thru to our parser
      # as parser detects "checkpoints", callback functions will be called
        # on_url: choose appropriate resource handler from those "registered"
        # on_message_complete:

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
 # be able to pass in a TLS.SSLConfig
 # make default buffer size arg to Server instead of global const
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
 # detect request/file response content types?
 # multi-process server
  # worker `serve` function that creates ServerClient, then `take!`s on a Channel{TCPSocket} and @async `process!`
  # master process does `tcp = accpet(server.tcp)`, then `put!`s it on Channel{TCPSocket}
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

type Server{T <: Scheme}
    host::IPAddr
    port::Int
    handler::Function
    logger::IO
    count::Int
    tlsconfig::TLS.SSLConfig
    tcp::Base.TCPServer

    function Server(host::IPAddr, port::Integer, handler::Function, logger::IO)
        new{T}(host, port, handler, logger, 0)
    end
end

Base.listen(s::Server) = (s.tcp = listen(s.host, s.port); return nothing)

const DEFAULT_BUFFER_SIZE = 1024

type ServerClient{T <: Scheme, I <: IO}
    id::Int
    server::Server
    parser::Parser
    keepalive::Bool
    replied::Bool
    buffer::Vector{UInt8}
    tcp::TCPSocket
    socket::I
    request::Request
    response::Response

    function ServerClient(id, server, parser, keepalive, replied, buffer, tcp, socket)
        sc = new(id, server, parser, keepalive, replied, buffer, tcp, socket)
        sc.request = parser.data.val
        sc.response = Response()
        return sc
    end
end

function ServerClient{T}(server::Server{T})
    if T == https
        tls = TLS.SSLContext()
        TLS.setup!(tls, server.tlsconfig)
        c = ServerClient{https, TLS.SSLContext}(server.count += 1, server, Parser(Request, https), false, false, Vector{UInt8}(DEFAULT_BUFFER_SIZE), TCPSocket(), tls)
    else
        tcp = TCPSocket()
        c = ServerClient{http, TCPSocket}(server.count += 1, server, Parser(Request, http), false, false, Vector{UInt8}(DEFAULT_BUFFER_SIZE), tcp, tcp)
    end
    finalizer(c, x->close(x.tcp))
    return c
end

# gets called when a full request has been parsed by our HTTP.Parser
function handle!(client::ServerClient)
    local response
    println(client.server.logger, "Received request on client: $(client.id) \n"); flush(STDOUT)
    show(client.server.logger, client.request)
    println(client.server.logger); flush(STDOUT)
    if !client.replied
        try
            response = client.server.handler(client.request, client.response)
        catch err
            response = Response(500)
            Base.display_error(err, catch_backtrace())
        end

        response.headers["Connection"] = client.keepalive ? "keep-alive" : "close"
        println(client.server.logger, "Responding with response on client: $(client.id) \n"); flush(STDOUT)
        show(client.server.logger, response)
        println(client.server.logger); flush(STDOUT)
        write(client.socket, response)
    end
    client.replied = false
    client.keepalive || close(client.socket)
    return
end

initTLS!(client::ServerClient{http}) = return
function initTLS!(client::ServerClient{https})
    try
        TLS.associate!(client.socket, client.tcp)
        TLS.handshake!(client.socket)
    catch e
        println("Error establishing SSL connection: ", e); flush(STDOUT)
        close(client.tcp)
    end
    return
end

function process!{T}(client::ServerClient{T})
    println(client.server.logger, "`process!`: client connection: ", client.id); flush(STDOUT)
    initTLS!(client)
    retry = 1
    while !eof(client.socket)
        # if no data after 30 seconds, break out
        nb = @timeout 10 readbytes!(client.socket, client.buffer, nb_available(client.socket)) break
        if nb < 1
            # `retry` tracks how many times we've unsuccessfully read data from the client
            # give up after 10 seconds of no data received
            sleep(1)
            retry += 1
            retry == 10 && break
            continue
        else
            http_parser_execute(client.parser, DEFAULT_REQUEST_PARSER_SETTINGS, client.buffer, nb)
            if errno(client.parser) != 0
                # error in parsing the http request
                break
            elseif client.parser.data.messagecomplete
                retry = 0
                handle!(client)
            end
        end
    end
    println(client.server.logger, "`process!`: finished processing client: ", client.id); flush(STDOUT)
end

function serve{T}(server::Server{T})
    println(server.logger, "Starting server to listen on: $(server.host):$(server.port)"); flush(STDOUT)
    listen(server)

    while true
        # initialize a ServerClient w/ Parser
        client = ServerClient(server)
        println(server.logger, "New client initialized: ", client.id); flush(STDOUT)
        try
            # accept blocks until a new connection is detected
            accept(server.tcp, client.tcp)
            println(server.logger, "New client connection accepted: ", client.id); flush(STDOUT)

            let client = client
                @async process!(client)
            end
        catch e
            if typeof(e) <: InterruptException
                println(server.logger, "Interrupt detectd, shutting down..."); flush(STDOUT)
                break
            else
                if !isopen(server.tcp)
                    println(server.logger, "Server TCPServer is closed, shutting down..."); flush(STDOUT)
                    # Server was closed while waiting to accept client. Exit gracefully.
                    break
                end
                println(server.logger, "Error encountered: $e"); flush(STDOUT)
                println(server.logger, "Resuming serving..."); flush(STDOUT)
            end
        end
    end
    close(server.tcp)
    return
end

function serve(host::IPAddr,port::Int,
                  handler=(req, rep) -> Response("Hello World!"),
                  logger=STDOUT;
                  cert::String="",
                  key::String="")
    if cert != "" && key != ""
        server = Server{https}(host, port, handler, logger)
        server.tlsconfig = TLS.SSLConfig(cert, key)
    else
        server = Server{http}(host, port, handler, logger)
    end

    return serve(server)
end
serve(; host::IPAddr=IPv4(127,0,0,1), port::Int=8081, handler::Function=(req, rep) -> Response("Hello World!"),
        logger::IO=STDOUT, cert::String="", key::String="") = serve(host, port, handler, logger; cert=cert, key=key)
