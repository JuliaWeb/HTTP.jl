```@meta
CurrentModule = HTTP
```

# API Reference

This section is the canonical placement for exported `HTTP.jl` docstrings and
the documented submodule APIs that make up the supported 2.0 surface. The
guides explain how the pieces fit together; these pages are where the concrete
names live.

## Module

```@docs
HTTP
```

## Reference Map

- [Core API](core.md): request/response types, headers, bodies, cookies, forms, and proxy configuration.
- [Client API](client.md): `Client`, `Transport`, top-level requests, streaming, and connection reuse helpers.
- [Server API](server.md): `Server`, `Stream`, routing, middleware, static files, and SSE.
- [WebSockets API](websockets.md): WebSocket client/server types, messaging helpers, and server lifecycle operations.
