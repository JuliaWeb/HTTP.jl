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

`HTTP.WebSockets.open` can also handshake over an already-connected `IO` instead
of a URL. Pass any byte stream (a raw `TCPSocket`, a TLS stream, etc.) as the
first argument, and optionally override the request-line `target`/`Host` header.
This is handy when the transport is established out-of-band or for tunnelling
WebSockets over a custom stream. The caller retains ownership of the `IO`, `open`
never closes it.

```julia
ws = HTTP.WebSockets.open(io; target = "/echo", host = "example.com:80")
```

`HTTP.WebSockets.open` also accepts the client-side handshake timeout controls:

- `connect_timeout`
- `request_timeout`
- `response_header_timeout`
- `read_idle_timeout`
- `write_idle_timeout`

### Message compression (permessage-deflate)

HTTP.jl supports the WebSocket permessage-deflate extension ([RFC 7692](https://www.rfc-editor.org/rfc/rfc7692)),
which DEFLATE-compresses each message. It is **opt-in on both ends** via
`compress = true` and is negotiated during the handshake — if either side
declines, the connection transparently falls back to uncompressed frames.

```julia
# server advertises permessage-deflate; clients may negotiate it
server = HTTP.WebSockets.listen!("127.0.0.1", 0; listenany = true, compress = true) do ws
    for msg in ws
        HTTP.WebSockets.send(ws, msg)
    end
end

# client offers compression
HTTP.WebSockets.open("ws://" * HTTP.WebSockets.server_addr(server); compress = true) do ws
    HTTP.WebSockets.send(ws, repeat("compress me ", 1000))  # sent compressed
    HTTP.WebSockets.receive(ws)
end
```

`compress` is also accepted by `HTTP.WebSockets.upgrade` for servers that mix
HTTP and WebSocket routes. Compression is most beneficial for larger, repetitive
text/JSON payloads; tiny or already-compressed (binary/media) messages gain
little. Decompressed message size is bounded by `maxframesize`, guarding against
decompression bombs. `maxframesize` defaults to 16 MiB for high-level
WebSocket clients and servers; pass a larger value explicitly if your protocol
requires larger messages.

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

### Tuning flow-control windows

HTTP/2 flow control caps the in-flight unacknowledged bytes, so single-stream
throughput is bounded by roughly `window / RTT`. The protocol default window of
65535 bytes is fine for small requests but throttles large uploads or downloads
on links with non-trivial latency. Pass an `HTTP.HTTP2Settings` through the
`http2_settings` keyword on either side to raise the per-stream and
connection-level receive windows. Uploads depend on the server's receive window
and downloads on the client's.

```julia
using HTTP

settings = HTTP.HTTP2Settings(
    initial_window_size = 1 << 20,     # 1 MiB per-stream receive window
    connection_window_size = 1 << 21,  # 2 MiB connection-level receive window
)

client = HTTP.Client(http2_settings = settings)
server = HTTP.serve!("127.0.0.1", 8080; http2_settings = settings) do request
    HTTP.Response(200, "ok")
end
```

Both windows default to the protocol default of 65535, so omitting
`http2_settings` leaves behavior unchanged.

Use these higher-level APIs for ordinary HTTP/2 traffic:

- `HTTP.request`, `HTTP.get`, and the other top-level request helpers
- `HTTP.open` for client-side streaming
- `HTTP.Client` and `HTTP.Transport` for reusable client configuration
- `HTTP.serve!`, `HTTP.listen!`, and `HTTP.streamhandler` for servers

HPACK tables, HTTP/2 frame structs, and direct connection/session types are
internal implementation details rather than part of the documented public API.
