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
```

## Routing and Middleware

The router and middleware helpers live in `HTTP.Handlers` and are also
available through `HTTP.Router`, `HTTP.register!`, and the related imported
aliases for compatibility.

```@docs
HTTP.Handlers.Handler
HTTP.Handlers.Middleware
HTTP.Handlers.Router
HTTP.Handlers.register!
HTTP.Handlers.getroute
HTTP.Handlers.getparams
HTTP.Handlers.getparam
HTTP.Handlers.getcookies
HTTP.Handlers.handlertimeout
```

## Server-Sent Events

```@docs
HTTP.SSEEvent
HTTP.SSEStream
HTTP.sse_stream
```
