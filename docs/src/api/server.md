```@meta
CurrentModule = HTTP
```

# Server API

```@contents
Pages = ["api/server.md"]
Depth = 2
```

## Server and Routing

```@docs
HTTP.Server
HTTP.Stream
HTTP.listen!
HTTP.listen
HTTP.serve!
HTTP.serve
HTTP.streamhandler
HTTP.forceclose
HTTP.port
HTTP.startread
HTTP.closeread
HTTP.Handler
HTTP.Middleware
HTTP.Router
HTTP.register!
HTTP.getroute
HTTP.getparams
HTTP.getparam
HTTP.getcookies
```

## Server-Sent Events

```@docs
HTTP.SSEEvent
HTTP.SSEStream
HTTP.sse_stream
```
