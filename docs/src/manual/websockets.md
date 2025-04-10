# HTTP WebSockets Guide

This guide provides a comprehensive overview of the WebSocket features in HTTP.jl. It explains how to establish a WebSocket connection, send and receive both text and binary messages, handle control frames (such as ping, pong, and close), and manage the lifecycle of WebSocket connections.

## Overview

HTTP.jl’s WebSockets API offers a convenient way to create real‑time communication channels over HTTP. The key functions include:
- **`WebSockets.open`** – Opens a WebSocket connection.
- **`WebSockets.send`** – Sends a message (text or binary) over an open connection.
- **`WebSockets.receive`** – Receives messages from the WebSocket.
- **`WebSockets.ping`** and **`WebSockets.pong`** – Send control frames to check connection health.
- **Iteration** – A WebSocket can be iterated over to continuously process incoming messages.

## Connecting to a WebSocket Server

To open a WebSocket connection, use the `WebSockets.open` function with a URL (starting with either `"ws://"` or `"wss://"`). A user-defined function is provided to interact with the open connection.

Example:

```julia
using HTTP

WebSockets.open("wss://echo.websocket.org") do ws
    println("Connected to the WebSocket server!")
    # Further operations with the ws object...
end
```

## Sending and Receiving Messages

Once connected, you can send messages using `WebSockets.send` and retrieve them using `WebSockets.receive`. The API handles both text and binary messages seamlessly.

Example of sending a text message and receiving an echo:

```julia
using HTTP

WebSockets.open("wss://echo.websocket.org") do ws
    WebSockets.send(ws, "Hello, WebSocket!")
    message = WebSockets.receive(ws)
    println("Received message: ", message)
end
```

For binary messages, pass a `Vector{UInt8}` to `send`; `receive` will return binary data accordingly.

## Handling Control Frames

WebSocket control frames are used for protocol-level tasks such as keeping the connection alive or closing it gracefully. HTTP.jl provides:
- **`WebSockets.ping(ws, [data])`** – Sends a PING frame.
- **`WebSockets.pong(ws, [data])`** – Sends a PONG frame.

Example of sending a PING frame:

```julia
using HTTP, WebSockets

WebSockets.open("wss://echo.websocket.org") do ws
    WebSockets.ping(ws)
    println("Ping sent!")
    # Optionally, you can handle pong responses as needed.
end
```

## Iterating Over WebSocket Messages

A WebSocket connection can be used as an iterator, which continuously yields incoming messages until the connection is closed.

Example:

```julia
using HTTP, WebSockets

WebSockets.open("wss://echo.websocket.org") do ws
    for message in ws
        println("Received: ", message)
        # Exit the loop if a specific message is received
        if message == "exit"
            break
        end
    end
end
```

## Connection Lifecycle and Error Handling

You can check whether a WebSocket is open using `WebSockets.isclosed(ws)` and close it with `close(ws)`. The API is designed to raise exceptions for connection issues or protocol errors, allowing you to handle errors using try‑catch blocks.

Example:

```julia
using HTTP, WebSockets

WebSockets.open("wss://echo.websocket.org") do ws
    try
        WebSockets.send(ws, "Test message")
        msg = WebSockets.receive(ws)
        println("Received: ", msg)
    catch e
        @error "WebSocket error:" e
    finally
        close(ws)
        println("WebSocket closed.")
    end
end
```
