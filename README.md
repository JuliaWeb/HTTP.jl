
# HTTP

*HTTP client and server functionality for Julia*

| **Documentation**                                                         | **Build Status**                                                                                |
|:-------------------------------------------------------------------------:|:-----------------------------------------------------------------------------------------------:|
| [![][docs-stable-img]][docs-stable-url] [![][docs-dev-img]][docs-dev-url] | [![][github-actions-ci-img]][github-actions-ci-url] [![][codecov-img]][codecov-url] |


## Installation

The package can be installed with Julia's package manager,
either by using the Pkg REPL mode (press `]` to enter):
```
pkg> add HTTP
```
or by using Pkg functions
```julia
julia> using Pkg; Pkg.add("HTTP")
```

## Overview

`HTTP.jl` provides HTTP client/server support, HTTP/2, WebSockets, SSE,
cookies, multipart forms, retries, and proxy-aware transports for Julia.

Current package compat targets Julia `1.10` and later.

## Scope and Deferred Go Parity

`HTTP.jl` 2.x borrows heavily from Go's `net/http` design, but it is not a
drop-in clone of every Go API or feature.

The current release intentionally defers:

- HTTP/2 server push and a `Pusher`-style surface
- Go `ResponseController` / hijack-style server-control APIs
- full Go request lifecycle instrumentation parity
- full `net/url` and `ServeMux` feature parity

These are explicit scope decisions for the 2.x release line rather than known
bugs in the documented client, server, streaming, proxy, HTTP/2, SSE, and
WebSocket APIs.

## Contributing and Questions

Contributions are very welcome, as are feature requests and suggestions. Please open an
[issue][issues-url] if you encounter any problems or would just like to ask a question.


## Client Examples

High-level request helpers return a `Response` whose `body` is a
`Vector{UInt8}` by default.

```julia
r = HTTP.get("http://httpbin.org/ip")
println(r.status)
println(String(r.body))
```

Stream directly into an `IO` sink with `response_stream`, or use `HTTP.open` when
you want pull-based control over the response stream.

```julia
open("response.bin", "w") do io
    HTTP.get("https://example.com/data.bin"; response_stream = io)
end

HTTP.open(:GET, "https://example.com/stream") do stream
    println(String(read(stream)))
end
```

Handle [Server-Sent Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
by passing an `sse_callback` function to `HTTP.request`:

```julia
events = HTTP.SSEEvent[]
HTTP.request("GET", "http://127.0.0.1:8080/events"; sse_callback = event -> push!(events, event))
```

Each callback receives an `HTTP.SSEEvent` with the parsed `data`, `event`,
`id`, `retry`, and `fields` from the stream.

## Server Examples

Use `HTTP.serve!` for request/response handlers:

```julia
using HTTP

server = HTTP.serve!("127.0.0.1", 8081) do request
    payload = "Hello from HTTP.jl"
    return HTTP.Response(
        200;
        headers = ["Content-Type" => "text/plain"],
        body = HTTP.BytesBody(codeunits(payload)),
        content_length = ncodeunits(payload),
    )
end

resp = HTTP.get("http://127.0.0.1:8081"; proxy = HTTP.ProxyConfig())
println(resp.status)
println(String(resp.body))

HTTP.forceclose(server)
```

Use `HTTP.listen!` or `HTTP.streamhandler` when you need lower-level stream
ownership for incremental reads, writes, or trailers.

## WebSocket Examples

```julia
using HTTP

server = HTTP.WebSockets.listen!("127.0.0.1", 8081) do ws
    for msg in ws
        HTTP.WebSockets.send(ws, msg)
    end
end

HTTP.WebSockets.open("ws://127.0.0.1:8081"; proxy = HTTP.ProxyConfig()) do ws
    HTTP.WebSockets.send(ws, "Hello")
    println(HTTP.WebSockets.receive(ws))
end

HTTP.WebSockets.forceclose(server)
```

[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://JuliaWeb.github.io/HTTP.jl/dev

[docs-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[docs-stable-url]: https://JuliaWeb.github.io/HTTP.jl/stable

[github-actions-ci-img]: https://github.com/JuliaWeb/HTTP.jl/workflows/CI/badge.svg
[github-actions-ci-url]: https://github.com/JuliaWeb/HTTP.jl/actions?query=workflow%3ACI

[codecov-img]: https://codecov.io/gh/JuliaWeb/HTTP.jl/branch/master/graph/badge.svg
[codecov-url]: https://codecov.io/gh/JuliaWeb/HTTP.jl

[issues-url]: https://github.com/JuliaWeb/HTTP.jl/issues
