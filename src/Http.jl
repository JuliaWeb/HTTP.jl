module Http

include("RequestParser.jl")
export Server, 
       HttpHandler, 
       WebsocketHandler, 
       Request, 
       Response, 
       run

STATUS_CODES = {
    100 => "Continue",
    101 => "Switching Protocols",
    102 => "Processing",                          # RFC 2518, obsoleted by RFC 4918
    200 => "OK",
    201 => "Created",
    202 => "Accepted",
    203 => "Non-Authoritative Information",
    204 => "No Content",
    205 => "Reset Content",
    206 => "Partial Content",
    207 => "Multi-Status",                        # RFC 4918
    300 => "Multiple Choices",
    301 => "Moved Permanently",
    302 => "Moved Temporarily",
    303 => "See Other",
    304 => "Not Modified",
    305 => "Use Proxy",
    307 => "Temporary Redirect",
    400 => "Bad Request",
    401 => "Unauthorized",
    402 => "Payment Required",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    406 => "Not Acceptable",
    407 => "Proxy Authentication Required",
    408 => "Request Time-out",
    409 => "Conflict",
    410 => "Gone",
    411 => "Length Required",
    412 => "Precondition Failed",
    413 => "Request Entity Too Large",
    414 => "Request-URI Too Large",
    415 => "Unsupported Media Type",
    416 => "Requested Range Not Satisfiable",
    417 => "Expectation Failed",
    418 => "I'm a teapot",                        # RFC 2324
    422 => "Unprocessable Entity",                # RFC 4918
    423 => "Locked",                              # RFC 4918
    424 => "Failed Dependency",                   # RFC 4918
    425 => "Unordered Collection",                # RFC 4918
    426 => "Upgrade Required",                    # RFC 2817
    428 => "Precondition Required",               # RFC 6585
    429 => "Too Many Requests",                   # RFC 6585
    431 => "Request Header Fields Too Large",     # RFC 6585
    500 => "Internal Server Error",
    501 => "Not Implemented",
    502 => "Bad Gateway",
    503 => "Service Unavailable",
    504 => "Gateway Time-out",
    505 => "HTTP Version Not Supported",
    506 => "Variant Also Negotiates",             # RFC 2295
    507 => "Insufficient Storage",                # RFC 4918
    509 => "Bandwidth Limit Exceeded",
    510 => "Not Extended",                        # RFC 2774
    511 => "Network Authentication Required"      # RFC 6585
}

# Request handlers
# ================

immutable HttpHandler
    handle::Function
    sock::TcpSocket
    events::Dict

    HttpHandler(handle::Function) = new(handle, TcpSocket(), (ASCIIString=>Function)[])
end

immutable WebsocketHandler
    handle::Function # (request, sock) -> ...
end

# Server / Client
# ===============

immutable Server
    http::HttpHandler
    websock::Union(Nothing,WebsocketHandler)
end
Server(http::HttpHandler)                        = Server(http, nothing)
Server(handler::Function)                        = Server(HttpHandler(handler))
Server(websock::WebsocketHandler)                = Server(HttpHandler((req, res) -> Response(404)), websock)
Server(handler::Function, sockhandler::Function) = Server(HttpHandler(handler), WebsocketHandler(sockhandler))

type Client
    id::Int
    sock::TcpSocket
    parser::ClientParser

    Client(id::Int, sock::TcpSocket) = new(id, sock)
end

# Request / Response
# ==================

type Response
    status::Int
    message::String
    headers::Headers
    data::String
    finished::Bool
end
Response(s::Int, m::String, h::Headers, d::String) = Response(s, m, h, d, false)
Response(s::Int, m::String, h::Headers)            = Response(s, m, h, "", false)
Response(s::Int, m::String, d::String)             = Response(s, m, headers(), d, false)
Response(d::String, h::Headers)                    = Response(200, STATUS_CODES[200], h, d, false)
Response(s::Int, m::String)                        = Response(s, m, headers(), "")
Response(d::String)                                = Response(200, STATUS_CODES[200], d)
Response(s::Int)                                   = Response(s, STATUS_CODES[s])
Response()                                         = Response(200)

# Default response headers
headers() = (String => String)["Server" => "Julia/$VERSION"]

# Utility functions
# =================

is_websocket_handshake(req) = get(req.headers, "Upgrade", false) == "websocket"

function event(event::String, server::Server, args...)
    has(server.http.events, event) ? server.http.events[event](args...) : false
end

# Request -> Response functions
# =============================

# Turns Response into a HTTP response string to send to clients
function render(response::Response)
    res = join(["HTTP/1.1", response.status, response.message, "\r\n"], " ")

    for header in keys(response.headers)
        res = string(join([ res, header, ": ", response.headers[header] ]), "\r\n")
    end

    join([ res, "", response.data ], "\r\n")
end

# Handle client requests
function process_client(server::Server, client::Client, websockets_enabled::Bool)
    event("connect", server, client)

    client.sock.closecb = function (args...)
        clean!(client.parser)
    end

    while client.sock.open
        line = readline(client.sock)
        add_data(client.parser, line)
    end
end

# Callback factory for providing on_message_complete for each client parser
function message_handler(server::Server, client::Client, websockets_enabled::Bool)

    # After parsing is done, the HttpHandler & WebsockHandler are passed the Request
    function on_message_complete(req::Request)
            if websockets_enabled && is_websocket_handshake(req)
                server.websock.handle(req, client)             # Defer to websockets
                return true                                    # Keep-alive
            end

            local response                                     # Init response

            try
                response = server.http.handle(req, Response()) # Run the server handler
                if !isa(response, Response)                    # Promote return to Response
                    response = Response(response)
                end
            catch err
                response = Response(500)
                event("error", server, client, err)            # Something went wrong
                Base.display_error(err, catch_backtrace())     # Prints backtrace without throwing
            end

            event("write", server, client, response)
            write(client.sock, render(response))               # Send the response
            event("close", server, client)
            close(client.sock)                                 # Close this connection
    end
end

# Start event loop, listen on port, accept client connections -- blocks forever
function run(server::Server, port::Integer)
    id_pool = 0                                            # Increments for each connection
    sock = server.http.sock
    websockets_enabled = server.websock != nothing
    uv_error("listen", !bind(sock, Base.IPv4(uint32(0)), uint16(port)))
    listen(sock)
    event("listen", server, port)

    while true # handle requests, Base.wait_accept blocks until a connection is made
        client = Client(id_pool += 1, Base.wait_accept(sock))
        client.parser = ClientParser(message_handler(server, client, websockets_enabled))
        @async process_client(server, client, websockets_enabled)
    end
end

end # module Http
