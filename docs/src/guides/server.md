```@meta
CurrentModule = HTTP
```

# Server Guide

`HTTP.jl` 2.0 supports both high-level request handlers and lower-level stream
handlers. The right choice depends on how much control you need over read/write
sequencing.

## Request Handlers

Use `HTTP.serve!` or `HTTP.serve` when your application naturally maps
`Request -> Response`.

```julia
using HTTP

server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
    payload = "handled " * req.target
    return HTTP.Response(
        200;
        headers = ["X-Handler" => "request"],
        body = payload,
    )
end

base_url = "http://127.0.0.1:$(HTTP.port(server))"
resp = HTTP.get(base_url * "/health"; proxy = HTTP.ProxyConfig())
HTTP.forceclose(server)
(status = resp.status, header = HTTP.header(resp, "X-Handler"), body = String(resp.body))
```

This is the simplest server path and the best default for ordinary APIs.

## Stream Handlers

Use `HTTP.listen!` when you need lower-level ownership of the connection
lifecycle. `HTTP.streamhandler` is the bridge when you want stream server
mechanics with a request-style handler body.

```julia
using HTTP

stream_server = HTTP.listen!(
    HTTP.streamhandler() do req
        return HTTP.Response(201; body = "stream handler")
    end,
    "127.0.0.1",
    0;
    listenany = true,
)

stream_url = "http://127.0.0.1:$(HTTP.port(stream_server))"
stream_resp = HTTP.get(stream_url * "/echo"; status_exception = false, proxy = HTTP.ProxyConfig())
HTTP.forceclose(stream_server)
(status = stream_resp.status, body = String(stream_resp.body))
```

Stream handlers are the right tool when you need:

- pull-based request body reads
- push-based or incremental response writing
- trailers or custom sequencing
- long-lived handlers that cannot be expressed as a single eager `Response`

## Server Lifecycle

The returned `Server` handle is operationally important. Hold onto it so you
can:

- inspect the bound port with `HTTP.port(server)`
- block on completion with `wait(server)`
- close or force-close the server explicitly during shutdown

`HTTP.forceclose(server)` is the fast shutdown path when you need to stop
accepting and serving immediately.

Every server timeout has both a seconds-valued keyword and a nanosecond-valued
`_ns` keyword:

```julia
using HTTP

handler = req -> HTTP.Response(200; body = "ok")
server = HTTP.serve!(
    handler,
    "127.0.0.1",
    8080;
    read_header_timeout_ns = 5_000_000_000,
    read_timeout_ns = 30_000_000_000,
    write_timeout_ns = 30_000_000_000,
    idle_timeout_ns = 120_000_000_000,
)
```

```julia
using HTTP

handler = req -> HTTP.Response(200; body = "ok")
server = HTTP.serve!(
    handler,
    "127.0.0.1",
    8080;
    read_timeout = 30,
    read_header_timeout = 5,
    write_timeout = 30,
    idle_timeout = 120,
)
```

The older `readtimeout` keyword is accepted as a seconds-valued migration alias
for `read_timeout`.

## Routing and Middleware

Use `HTTP.Router` when you want route matching without bringing in a
larger web framework:

```julia
using HTTP

router = HTTP.Router()

HTTP.register!(router, "GET", "/users/{id}") do req
    id = HTTP.getparam(req, "id")
    return HTTP.Response(200; body = "user " * id)
end

server = HTTP.serve!(router, "127.0.0.1", 8080)
```

Middleware is just function composition around handlers. For example, apply a
handler timeout to every registered route:

```julia
using HTTP

timeout = HTTP.Handlers.handlertimeout(5.0; status = 503)
router = HTTP.Router(
    req -> HTTP.Response(404),
    req -> HTTP.Response(405),
    timeout,
)
```

The router stores route metadata on the request context. Read it with
`HTTP.getroute`, `HTTP.getparams`, and `HTTP.getparam`.

## Static Files

`HTTP.fileserver(root)` returns a normal request handler rooted at a directory.
It serves static files, normalizes directory redirects, can fall back to a
single-page-app entrypoint, and emits conditional and range-aware responses.

```julia
using HTTP

handler = HTTP.fileserver("public"; spa_fallback = "index.html")
server = HTTP.serve!(handler, "127.0.0.1", 8080)
```

For lower-level control, use `HTTP.servefile(request, path)` when you already
resolved a filesystem path, or `HTTP.servecontent(request, source)` when the
bytes/string/seekable `IO` content is already in hand. These helpers populate
content type, `Last-Modified`, `ETag`, `Accept-Ranges`, and `Content-Range`
headers as appropriate, and honor conditional and range request headers before
returning a `Response`.

## SSE and Long-Lived Responses

`HTTP.jl` exposes `SSEEvent`, `SSEStream`, and `sse_stream` for server-sent
events. Use these when you want a proper `text/event-stream` response instead
of hand-assembling event lines.

```julia
using HTTP

server = HTTP.serve!("127.0.0.1", 8080) do req
    return HTTP.sse_stream(200) do stream
        write(stream, HTTP.SSEEvent("ready"; event = "status", id = "1"))
    end
end
```

## HTTP/2 Servers

The same server entrypoints can serve HTTP/2. For browser and most production
clients, configure TLS so ALPN can select `h2`; for cleartext prior-knowledge
clients, HTTP.jl accepts the HTTP/2 connection preface on the normal listener.
Most applications do not need a separate server API for HTTP/2; use the normal
`serve!`, `listen!`, and `streamhandler` surfaces.
