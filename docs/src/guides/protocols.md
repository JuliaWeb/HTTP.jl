```@meta
CurrentModule = HTTP
```

# Protocols Guide

Most applications should stay on the higher-level client/server APIs. This
guide covers the protocol-specific APIs meant to be used directly, plus where
HTTP/2 fits into normal `HTTP.jl` usage.

## WebSockets

The WebSocket entrypoints live in the `HTTP.WebSockets` submodule. (The bare
`WebSockets` name is also exported when you `using HTTP`, but the docs always
use the fully-qualified `HTTP.WebSockets.*` form to avoid being shadowed by
other packages.)

Use `HTTP.WebSockets.open` for `ws://` and `wss://` URLs. Top-level
`HTTP.open` is the ordinary HTTP request/response streaming API and expects an
HTTP method such as `:GET`.

```julia
using HTTP

server = HTTP.WebSockets.listen!("127.0.0.1", 0; listenany = true) do ws
    for msg in ws
        HTTP.WebSockets.send(ws, uppercase(String(msg)))
    end
end

url = "ws://" * HTTP.WebSockets.server_addr(server) * "/echo"
reply = HTTP.WebSockets.open(url; proxy = HTTP.ProxyConfig()) do ws
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

On the client side, `prefer_http2 = true` is the default, so secure connections
try to negotiate HTTP/2 with ALPN when the server supports it. Set
`prefer_http2 = false` on `Transport` or `Client` to force HTTP/1.1 for those
connections.

```julia
using HTTP

h1_only = HTTP.Client(transport = HTTP.Transport(prefer_http2 = false))
resp = HTTP.get("https://example.com"; client = h1_only)
close(h1_only)
```

On the server side, use the same `serve!` and `listen!` entrypoints. For browser
and most production HTTP/2 traffic, run the server with TLS configured so ALPN
can select `h2`. Cleartext HTTP/2 is accepted when the peer starts the
connection with the HTTP/2 prior-knowledge preface; ordinary HTTP/1.1 upgrade
requests are not a separate public server API.

Use these higher-level APIs for ordinary HTTP/2 traffic:

- `HTTP.request`, `HTTP.get`, and the other top-level request helpers
- `HTTP.open` for client-side streaming
- `HTTP.Client` and `HTTP.Transport` for reusable client configuration
- `HTTP.serve!`, `HTTP.listen!`, and `HTTP.streamhandler` for servers

HPACK tables, HTTP/2 frame structs, and direct connection/session types are
internal implementation details rather than part of the documented public API.
