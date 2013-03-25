module Http

using Httplib
include("RequestParser.jl")
export HttpHandler,
       Server,
       run,
       # from Httplib
       Request,
       Response

# `HttpHandler` types are used to instantiate a `Server`.
#
# An `HttpHandler` is responsible for the entirety of the request / response cycle.
# Instantiate an `HttpHandler` with a single `Function` argument, which becomes `HttpHandler.handle`.
# This handler is called on every incoming request and passed `req::Request, res::Response`.
# The return value of `HttpHandler.handle` is the response sent to the client for the given `req`.
#
# `HttpHandler.handle` can return a `String`:
#
#     handler = HttpHandler() do req, res
#         "Hello world!"
#     end
#
# an HTTP status code as `Int`:
#
#     handler = HttpHandler() do req, res
#         404
#     end
# 
# or a full `Response` instance:
#
#     handler = HttpHandler() do req, res
#         Response(200, "Success", "Hello World!" 
#     end  
#
# `HttpHandler.sock` is used internally to store the `TcpSocket` for incoming connections.
#
# `HttpHandler.events` is a dictionary of functions to call when certain server events occur.
# Set these functions by direct assignment:
#
#     handler.events["listen"] = (port) -> "Listening on $port..."
#
# All default events and their arguments:
#
#   - `"listen"  => (port::Int)`
#   - `"connect" => (client::Client)`
#   - `"write"   => (client::Client, res::Response)`
#   - `"close"   => (client::Client)`
#
# If you want to trigger custom events on your server, use the `event` function:
#
#     # listen for "foo"
#     handler.events["foo"] = (bar) -> "Hello $bar"
#     # trigger "foo"
#     Http.event(server, "foo", "Julia")
#
immutable HttpHandler
    handle::Function
    sock::TcpSocket
    events::Dict

    HttpHandler(handle::Function) = new(handle, TcpSocket(), Dict{ASCIIString, Function}())
end
handle(handler::HttpHandler, req::Request, res::Response) = handler.handle(req, res)

# Client encapsulates a single connection
#
# When new connections are initialized a `Client` is created with a new id and the connection socket.
# `Client.parser` will store a `ClientParser` to handle all HTTP parsing for the connection lifecycle.
#
type Client
    id::Int
    sock::TcpSocket
    parser::ClientParser

    Client(id::Int, sock::TcpSocket) = new(id, sock)
end

# `WebsocketInterface` defines the abstract protocol for a WebsocketHandler.
#
# The methods `is_websocket_handshake` and `handle` will be called if `Server.sockets` is populated.
# Concrete types of `WebsocketInterface` are required to define these methods.
abstract WebsocketInterface
# `is_websocket_handshake` should determine if `req` is a valid websocket upgrade request.
function is_websocket_handshake(handler::WebsocketInterface, req::Request)
    throw("`$(typeof(handler))` does not implement `is_websocket_handshake`.")
end
# `handle` is called when `is_websocket_handshake` returns true, and takes full control of the connection.
function handle(handler::WebsocketInterface, req::Request, client::Client)
    throw("`$(typeof(handler))` does not implement `handle`.")
end

# `Server` types encapsulate an `HttpHandler` and optional `WebsocketInterface` to serve requests.
# 
# Instantiate with both an `HttpHandler` and `WebsocketInterface` to serve both protocols.
# Instantiate with just an `HttpHandler` to serve only standard `Http`
# Instantiate with just a `Function` to create an `HttpHandler` automatically.
# Instantiate with just a `WebsocketInterface` to only serve websockets requests and `404` all others. 
#
immutable Server
    http::HttpHandler
    websock::Union(Nothing, WebsocketInterface)
end
Server(http::HttpHandler)           = Server(http, nothing)
Server(handler::Function)           = Server(HttpHandler(handler))
Server(websock::WebsocketInterface) = Server(HttpHandler((req, res) -> Response(404)), websock)

# Triggers `event` on `server`.
# If there is a function bound to `event` in `server.events` it will be called with `args...`
#
function event(event::String, server::Server, args...)
    has(server.http.events, event) && server.http.events[event](args...)
end

# Converts a `Response` to an HTTP response string
function render(response::Response)
    res = join(["HTTP/1.1", response.status, response.message, "\r\n"], " ")

    for header in keys(response.headers)
        res = string(join([ res, header, ": ", response.headers[header] ]), "\r\n")
    end

    join([ res, "", response.data ], "\r\n")
end

# `run` starts `server` listening on `port`. 
#
# Accepts incoming connections and instatiates each `Client`.
# Manages the `client.id` pool.
# Spawns a new `Task` for each connection.
# Blocks forever.
#
#     server = Server() do req, res
#         "Hello world"
#     end
#
#     run(server, 8000)
#
function run(server::Server, port::Integer)
    id_pool = 0 # Increments for each connection
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

# Handles live connections, runs inside a `Task`.
#
# Blocks ( yields ) until a line can be read, then passes it into `client.parser`.
#
function process_client(server::Server, client::Client, websockets_enabled::Bool)
    event("connect", server, client)

    while client.sock.open
        line = readline(client.sock)
        add_data(client.parser, line)
    end
    
    # Garbage collects parser globals on connection close, (see: `RequestParser.jl`)
    clean!(client.parser)
end

# Callback factory for providing `on_message_complete` for `client.parser`
function message_handler(server::Server, client::Client, websockets_enabled::Bool)

    # Called when the `ClientParser` has successfull parsed a complete `Request`.
    #
    # If websockets are enabled and claim this request, defer to `server.websock` and return.
    # Otherwise, call `server.http.handle` to get a `Response` for the `client`.
    # Catches any errors with `server.http.handle`, returns a `500` and writes a stacktrace to `stdout`.
    # Closes all connections after response ( should be changed to support keep-alive )
    #
    function on_message_complete(req::Request)
        if websockets_enabled && is_websocket_handshake(server.websock, req)
            handle(server.websock, req, client)
            return true
        end

        local response                                      # Init response

        try
            response = handle(server.http, req, Response()) # Run the server handler
            if !isa(response, Response)                     # Promote return to Response
                response = Response(response)
            end
        catch err
            response = Response(500)
            event("error", server, client, err)             # Something went wrong
            Base.display_error(err, catch_backtrace())      # Prints backtrace without throwing
        end

        write(client.sock, render(response))                # Send the response
        event("write", server, client, response)
        close(client.sock)                                  # Close this connection
        event("close", server, client)
    end
end

end # module Http
