# WebSockets

HTTP.jl provides a complete and well-tested websockets implementation via the `WebSockets` module. It is tested against the industry standard [autobahn testsuite](https://github.com/crossbario/autobahn-testsuite). The client and server usage are similar to their HTTP counterparts, but provide a `WebSocket` object that enables sending and receiving messages.

## WebSocket object

Both `WebSockets.open` (client) and `WebSockets.listen` (server) take a handler function that should accept a single `WebSocket` object argument. It has a small, simple API to provide full websocket functionality, including:
  * `receive(ws)`: blocking call to receive a single, non-control message from the remote. If ping/pong messages are received, they are handled/responded to automatically and a non-control message is waited for. If a CLOSE message is received, an error will be thrown. Returns either a `String` or `Vector{UInt8}` depending on whether the message had a TEXT or BINARY frame type. Fragmented messages are received fully before returning and the bodies of each frame are concatenated for a full, final message body.
  * `send(ws, msg)`: sends a message to the remote. If `msg` is `AbstractVector{UInt8}`, the message will have the BINARY type, if `AbstractString`, it will have TEXT type. `msg` can also be an iterable of either `AbstractVector{UInt8}` or `AbstractString` and a fragmented message will be sent, with one fragment for each iterated element.
  * `close(ws)`: initiate the close sequence of the websocket
  * `ping(ws[, data])`: send a PING message to the remote with optional `data`. PONG responses are received by calling `receive(ws)`.
  * `pong(ws[, data])`: send a PONG message to the remote with optional `data`.
  * `for msg in ws`: for convenience, the `WebSocket` object supports the iteration protocol, which results in a call to `receive(ws)` to produce each iterated element. Iteration terminates when a non-error CLOSE message is received. This is the most common way to handle the life of a `WebSocket`, and looks like:

```julia
# client
WebSockets.open(url) do ws
    for msg in ws
        # do cool stuff with msg
    end
end

# server
WebSockets.listen(host, port) do ws
    # iterate incoming websocket messages
    for msg in ws
        # send message back to client or do other logic here
        send(ws, msg)
    end
    # iteration ends when the websocket connection is closed by client or error
end
```

## WebSocket Client

To initiate a websocket client connection, the [`WebSockets.open`](@ref) function is provided, which operates similar to [`HTTP.open`](@ref), but the handler function should operate on a single `WebSocket` argument instead of an `HTTP.Stream`.

### Example

```julia
# simple websocket client
WebSockets.open("ws://websocket.org") do ws
    # we can iterate the websocket
    # where each iteration yields a received message
    # iteration finishes when the websocket is closed
    for msg in ws
        # do stuff with msg
        # send back message as String, Vector{UInt8}, or iterable of either
        send(ws, resp)
    end
end
```

## WebSocket Server

To start a websocket server to listen for client connections, the [`WebSockets.listen`](@ref) function is provided, which mirrors the [`HTTP.listen`](@ref) function, but the provided handler should operate on a single `WebSocket` argument instead of an `HTTP.Stream`.

### Example

```julia
# websocket server is very similar to client usage
WebSockets.listen("0.0.0.0", 8080) do ws
    for msg in ws
        # simple echo server
        send(ws, msg)
    end
end
```