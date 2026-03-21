```@meta
CurrentModule = HTTP
```

# WebSockets API

```@contents
Pages = ["api/websockets.md"]
Depth = 2
```

## Module and Core Types

```@docs
HTTP.WebSockets
HTTP.WebSockets.Conn
HTTP.WebSockets.CloseFrameBody
HTTP.WebSockets.WebSocketError
HTTP.WebSockets.WebSocket
```

## Client Operations

```@docs
HTTP.WebSockets.open
HTTP.WebSockets.send
HTTP.WebSockets.receive
HTTP.WebSockets.ping
HTTP.WebSockets.pong
```

## Server Operations

```@docs
HTTP.WebSockets.Server
HTTP.WebSockets.listen!
HTTP.WebSockets.listen
HTTP.WebSockets.serve!
HTTP.WebSockets.server_addr
HTTP.WebSockets.forceclose
```
