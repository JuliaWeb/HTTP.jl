module Http

using Httplib
include("RequestParser.jl")
export Server,
       HttpHandler,
       Request,
       Response,
       run

# Websocket interface
# ===================

abstract WebsocketInterface
function handle(handler::WebsocketInterface, args...)
    throw("`$(typeof(handler))` does not implement `handle`.")
end
function is_websocket_handshake(handler::WebsocketInterface, args...)
    throw("`$(typeof(handler))` does not implement `is_websocket_handshake`.")
end

# Request handlers
# ================

immutable HttpHandler
    handle::Function
    sock::TcpSocket
    events::Dict

    HttpHandler(handle::Function) = new(handle, TcpSocket(), Dict{ASCIIString, Function}())
end
handle(handler::HttpHandler, req::Request, res::Response) = handler.handle(req, res)

# Server / Client
# ===============

immutable Server
    http::HttpHandler
    websock::Union(Nothing, WebsocketInterface)
end
Server(http::HttpHandler)                        = Server(http, nothing)
Server(handler::Function)                        = Server(HttpHandler(handler))
Server(websock::WebsocketInterface)              = Server(HttpHandler((req, res) -> Response(404)), websock)

type Client
    id::Int
    sock::TcpSocket
    parser::ClientParser

    Client(id::Int, sock::TcpSocket) = new(id, sock)
end

# Utility functions
# =================

function event(event::String, server::Server, args...)
    has(server.http.events, event) && server.http.events[event](args...)
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

    client.sock.closecb = (args...) -> clean!(client.parser)

    while client.sock.open
        line = readline(client.sock)
        add_data(client.parser, line)
    end
end

# Callback factory for providing on_message_complete for each client parser
function message_handler(server::Server, client::Client, websockets_enabled::Bool)

    # After parsing is done, the HttpHandler & WebsockHandler are passed the Request
    function on_message_complete(req::Request)
        if websockets_enabled && is_websocket_handshake(server.websock, req)
            handle(server.websock, req, client)
            return true
        end

        local response                                     # Init response

        try
            response = handle(server.http, req, Response()) # Run the server handler
            if !isa(response, Response)                    # Promote return to Response
                response = Response(response)
            end
        catch err
            response = Response(500)
            event("error", server, client, err)            # Something went wrong
            Base.display_error(err, catch_backtrace())     # Prints backtrace without throwing
        end

        write(client.sock, render(response))               # Send the response
        event("write", server, client, response)
        close(client.sock)                                 # Close this connection
        event("close", server, client)
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
