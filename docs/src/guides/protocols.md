```@meta
CurrentModule = HTTP
```

# Protocols Guide

Most applications should stay on the higher-level client/server APIs. This
guide covers the protocol-specific APIs meant to be used directly, plus where
HTTP/2 fits into normal `HTTP.jl` usage.

## WebSockets

WebSockets live under `HTTP.WebSockets`.

```julia
using HTTP

function wait_for_ws_url(server)
    for _ in 1:100
        try
            return "ws://" * HTTP.WebSockets.server_addr(server) * "/echo"
        catch
            sleep(0.01)
        end
    end
    error("websocket server did not start listening in time")
end

server = HTTP.WebSockets.listen!("127.0.0.1", 0; listenany = true) do ws
    for msg in ws
        HTTP.WebSockets.send(ws, uppercase(String(msg)))
    end
end

reply = HTTP.WebSockets.open(wait_for_ws_url(server); proxy = HTTP.ProxyConfig()) do ws
    HTTP.WebSockets.send(ws, "hello")
    HTTP.WebSockets.receive(ws)
end
HTTP.WebSockets.forceclose(server)
reply
```

Main WebSocket entrypoints:

- `HTTP.WebSockets.open`
- `HTTP.WebSockets.listen!`
- `HTTP.WebSockets.send`
- `HTTP.WebSockets.receive`
- `HTTP.WebSockets.forceclose`

The WebSocket layer covers close/ping/pong framing, server helpers, and
proxy-aware clients without forcing you through internal parser state. The
[WebSockets API reference](../api/websockets.md) is the canonical home for the
public docstrings.

`HTTP.WebSockets.open` also accepts the client-side handshake timeout controls:

- `connect_timeout`
- `request_timeout`
- `response_header_timeout`
- `read_idle_timeout`
- `write_idle_timeout`

## HTTP/2 Support

`HTTP.jl` supports HTTP/2 through the normal client and server APIs.

On the client side, set `prefer_http2 = true` on `Transport` or `Client` when
you want secure connections to negotiate HTTP/2 when the server supports it.
On the server side, the standard `serve!`/`listen!` entrypoints can speak
HTTP/2 when TLS/ALPN or a cleartext HTTP/2 preface selects it.

Use these higher-level APIs for ordinary HTTP/2 traffic:

- `HTTP.request`, `HTTP.get`, and the other top-level request helpers
- `HTTP.open` for client-side streaming
- `HTTP.Client` and `HTTP.Transport` for reusable client configuration
- `HTTP.serve!`, `HTTP.listen!`, and `HTTP.streamhandler` for servers

HPACK tables, HTTP/2 frame structs, and direct connection/session types are
internal implementation details rather than part of the documented public API.

## Intentional Go Parity Gaps

`HTTP.jl` 2.x borrows ideas from Go's `net/http`, but it does not aim to
surface every Go API or compatibility point.

The current release intentionally defers:

- HTTP/2 server push and any `Pusher`-style server API
- Go `ResponseController` / hijack-style response-control APIs
- full Go request lifecycle instrumentation parity
- full `net/url` and `ServeMux` feature parity

Treat these as explicit scope decisions for the current release, not accidental
regressions in the supported client, server, HTTP/2, or WebSocket features
documented here.
