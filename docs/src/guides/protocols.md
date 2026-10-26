```@meta
CurrentModule = HTTP
```

# Protocols Guide

This page covers WebSockets, HTTP/2, and HTTP/3. HTTP/2 and HTTP/3 need no
separate API: the client and server functions from the other guides use them
when both sides support them.

## WebSockets

The WebSocket API lives in the `HTTP.WebSockets` submodule. `using HTTP` also
exports the name `WebSockets`; these docs write `HTTP.WebSockets` so that
another package's `WebSockets` cannot shadow it.

`HTTP.WebSockets.listen!` starts a server that calls your function with each
new connection. `HTTP.WebSockets.open` connects to a `ws://` or `wss://` URL:

```julia
using HTTP

server = HTTP.WebSockets.listen!("127.0.0.1", 0) do ws
    for msg in ws
        HTTP.WebSockets.send(ws, uppercase(msg))
    end
end

url = "ws://" * HTTP.WebSockets.server_addr(server)
reply = HTTP.WebSockets.open(url) do ws
    HTTP.WebSockets.send(ws, "hello")
    HTTP.WebSockets.receive(ws)
end
HTTP.WebSockets.forceclose(server)
reply  # "HELLO"
```

Iterating over a WebSocket yields each message until the peer closes the
connection. `receive` returns a `String` for a text message and a
`Vector{UInt8}` for a binary one. The `do` block form of `open` returns the
block's value and closes the connection when the block ends.

To serve WebSockets and ordinary HTTP routes from one server, upgrade requests
by hand inside an `HTTP.listen!` handler; see `HTTP.WebSockets.upgrade`.

`HTTP.WebSockets.open` also accepts an `IO` that is already connected, such as a
`TCPSocket` or a TLS stream, instead of a URL. Pass the request `target` and
`host` as keywords. `open` never closes that `IO`:

```julia
ws = HTTP.WebSockets.open(io; target = "/echo", host = "example.com")
```

### Limits and timeouts

`maxframesize` limits the size of one incoming frame, and `maxfragmentation`
the number of frames in one message. They default to 16 MiB and 1024 on clients
and servers; pass larger values if your protocol needs them. A peer that goes
over a limit gets a close frame with status 1009.

`HTTP.WebSockets.open` with a URL accepts the client timeouts
`connect_timeout`, `request_timeout`, `response_header_timeout`,
`read_idle_timeout`, and `write_idle_timeout`. `read_idle_timeout` keeps
applying after the handshake: if nothing arrives for that long, the connection
closes and `receive` throws a `WebSocketError`.

### Compression

Pass `compress = true` to use the permessage-deflate extension
([RFC 7692](https://www.rfc-editor.org/rfc/rfc7692)), which compresses each
message. Both sides must ask for it; otherwise messages are sent uncompressed.
`HTTP.WebSockets.listen!`, `HTTP.WebSockets.upgrade`, and
`HTTP.WebSockets.open` accept the keyword:

```julia
server = HTTP.WebSockets.listen!("127.0.0.1", 0; compress = true) do ws
    for msg in ws
        HTTP.WebSockets.send(ws, msg)
    end
end

HTTP.WebSockets.open("ws://" * HTTP.WebSockets.server_addr(server); compress = true) do ws
    HTTP.WebSockets.send(ws, repeat("compress me ", 1000))
    HTTP.WebSockets.receive(ws)
end
```

Compression helps most with large, repetitive text such as JSON. The
`maxframesize` limit applies to the decompressed message.

## HTTP/2

The client asks for HTTP/2 when it connects to an `https://` URL, and uses it
when the server agrees. Pass `prefer_http2 = false` to `HTTP.Client`, or
`protocol = :h1` to a single request, to use HTTP/1.1 instead.
`protocol = :h2` with an `http://` URL sends cleartext HTTP/2 without first
asking the server, which works with servers that accept it, including HTTP.jl's.

```julia
h1_only = HTTP.Client(prefer_http2 = false)
resp = HTTP.get(h1_only, "https://example.com")
close(h1_only)
```

Servers started with `HTTP.serve!` or `HTTP.listen!` speak HTTP/2 too. Over TLS,
the client and server agree on HTTP/2 during the TLS handshake, which is what
browsers require. On a plain listener, a client that opens with the HTTP/2
connection preface gets HTTP/2; pass `allow_h2c = false` to turn that off.
Requests with an `Upgrade: h2c` header are answered with HTTP/1.1.

### Flow-control windows

HTTP/2 flow control limits how many bytes can be in flight on a stream before
the receiver acknowledges them. With the protocol default window of 65,535
bytes, one stream can move at most about `window / round-trip time` per second,
which slows large transfers on high-latency links. Pass an
[`HTTP.HTTP2Settings`](@ref) as `http2_settings` to raise the receive windows.
The server's setting affects uploads and the client's affects downloads:

```julia
settings = HTTP.HTTP2Settings(
    initial_window_size = 1 << 20,     # 1 MiB per stream
    connection_window_size = 1 << 21,  # 2 MiB per connection
)

client = HTTP.Client(http2_settings = settings)
server = HTTP.serve!("127.0.0.1", 8080; http2_settings = settings) do req
    return HTTP.Response(200; body = "ok")
end
```

Both windows default to 65,535 bytes.

## HTTP/3

The client can send requests over HTTP/3, which runs on QUIC over UDP instead
of TCP. It is off by default. With `prefer_http3 = true`, a client uses HTTP/3
for an `https://` origin once one of the origin's responses has advertised it
in an `Alt-Svc` header, as most large sites do; the first request to an origin
still goes over TCP. `protocol = :h3` on a single request uses HTTP/3 without
waiting for an advertisement:

```julia
client = HTTP.Client(prefer_http3 = true)
HTTP.get(client, "https://cloudflare-quic.com")         # HTTP/2; learns of HTTP/3
resp = HTTP.get(client, "https://cloudflare-quic.com")  # HTTP/3
resp.version                                            # v"3.0.0"
close(client)

HTTP.get("https://www.google.com"; protocol = :h3)
```

When a QUIC connection to an advertised origin cannot be made, for example
because a firewall drops UDP, the request goes over TCP instead and the client
leaves that origin's HTTP/3 alternative alone for 5 minutes. HTTP/3 is never
used through a proxy. The client takes its TLS settings from the transport's
`tls_config`, negotiating `h3` with ALPN. HTTP.jl servers do not speak HTTP/3
yet.
