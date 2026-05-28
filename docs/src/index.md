```@meta
CurrentModule = HTTP
```

# HTTP.jl

`HTTP.jl` provides HTTP client/server functionality, HTTP/2 support, SSE, and
WebSockets on top of [`Reseau`](https://github.com/JuliaServices/Reseau.jl)'s
transport, resolver, and TLS stack. The high-level surface stays familiar while
keeping request, response, body, transport, and stream types explicit.

## Quick Start

This example starts a local server, sends a request through the client API, and
reads the response body:

```julia
using HTTP

server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
    payload = "hello from HTTP.jl docs"
    return HTTP.Response(
        200;
        headers = ["Content-Type" => "text/plain"],
        body = payload,
    )
end

url = "http://127.0.0.1:$(HTTP.port(server))/hello"
resp = HTTP.get(url; proxy = HTTP.ProxyConfig())
HTTP.forceclose(server)
String(resp.body)
```

## What You Get

- Familiar top-level request helpers: `HTTP.get`, `HTTP.post`, `HTTP.request`, `HTTP.open`
- Explicit client controls: `HTTP.Client`, `HTTP.Transport`, `HTTP.RetryBucket`, `HTTP.ProxyConfig`
- Rich client timeout controls: `connect_timeout`, `request_timeout`, `response_header_timeout`, `read_idle_timeout`, and `write_idle_timeout`
- Server entrypoints for request/response and stream-level handlers: `HTTP.serve!`, `HTTP.listen!`, `HTTP.streamhandler`
- Built-in HTTP/2 support in the normal client and server workflows
- Protocol-specific APIs for WebSockets

## Documentation Map

- The [Client guide](guides/client.md) covers request construction, streaming, reusable clients, request bodies, and operational knobs.
- The [Server guide](guides/server.md) covers request handlers, stream handlers, lifecycle management, and SSE-oriented server patterns.
- The [Protocols guide](guides/protocols.md) covers WebSockets and where HTTP/2 fits into the normal client/server APIs.
- The [Migration guide](guides/migration-1x.md) calls out the major 1.x to 2.0 shifts.
- The [API reference](api/reference.md) is the canonical home for exported and documented submodule APIs.

## Design Direction

- `HTTP.jl` owns the HTTP protocol stack; `Reseau` owns the transport/runtime/TLS substrate.
- Request and response bodies have explicit internal representations while
  ordinary user-facing calls accept familiar strings, byte vectors, forms, and
  streams.
- Client/server internals follow a more explicit state-machine design, which makes retries, proxying, streaming, and HTTP/2 behavior easier to reason about.
- Most wire-level HTTP/2 and HPACK details are implementation details rather than part of the documented public API.
