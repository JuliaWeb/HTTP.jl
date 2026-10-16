```@meta
CurrentModule = HTTP
```

# Server API

```@contents
Pages = ["api/server.md"]
Depth = 2
```

## Server Lifecycle and Request Handlers

```@docs
HTTP.Server
HTTP.Stream
HTTP.listen!
HTTP.listen
HTTP.serve!
HTTP.serve
HTTP.streamhandler
HTTP.servefile
HTTP.fileserver
HTTP.servecontent
HTTP.forceclose
HTTP.port
HTTP.startread
HTTP.startwrite
HTTP.setstatus
HTTP.addtrailer
HTTP.closeread
HTTP.peeraddr
```

## Routing and Middleware

The router and middleware live in `HTTP.Handlers`. Except for `handlertimeout`
and `logging_middleware`, the names below are also available from `HTTP`
directly, as in `HTTP.Router` and `HTTP.register!`.

```@docs
HTTP.Handlers.Handler
HTTP.Handlers.Middleware
HTTP.Handlers.Router
HTTP.Handlers.Node
HTTP.Handlers.register!
HTTP.Handlers.getroute
HTTP.Handlers.getparams
HTTP.Handlers.getparam
HTTP.Handlers.getcookies
HTTP.Handlers.handlertimeout
HTTP.Handlers.logging_middleware
```

## Server-Sent Events

```@docs
HTTP.SSEEvent
HTTP.SSEStream
HTTP.sse_stream
```
