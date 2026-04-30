
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

HTTP.jl 2.0 is a breaking release. See the
[migration guide][migration-guide-url] for the main 1.x to 2.0 changes around
response fields, constructors, request context, client pooling, retries,
timeouts, servers, WebSockets, and SSE.

## Contributing and Questions

Contributions are very welcome, as are feature requests and suggestions. Please open an
[issue][issues-url] if you encounter any problems or would just like to ask a question.


## Client Examples

High-level request helpers return a `Response` whose `body` is a
`Vector{UInt8}` by default.

```julia
using HTTP

r = HTTP.get("http://httpbin.org/ip")
println(r.status)
println(String(r.body))
```

> ⚠️ `String(r.body)` aliases the underlying byte buffer rather than copying
> it, so `r.body` is left empty afterwards. Use `String(copy(r.body))` (or
> `response_stream = IOBuffer()`) when you need to keep the bytes around.

To send JSON, serialize the payload with [JSON.jl](https://github.com/JuliaIO/JSON.jl)
and set the `Content-Type` header explicitly — HTTP.jl ships without a JSON
dependency:

```julia
using HTTP, JSON

payload = Dict("name" => "alice", "age" => 30)
r = HTTP.post(
    "http://httpbin.org/post";
    headers = ["Content-Type" => "application/json"],
    body = JSON.json(payload),
)
returned = JSON.parse(String(r.body))
```

Stream directly into an `IO` sink with `response_stream`, or use `HTTP.open` when
you want pull-based control over the response stream. The `do`-block form of
`HTTP.open` returns the final `HTTP.Response`, not the value returned by the
`do` block.

```julia
using HTTP

open("response.bin", "w") do io
    HTTP.get("https://example.com/data.bin"; response_stream = io)
end

text = ""
response = HTTP.open(:GET, "https://example.com/stream") do stream
    text = String(read(stream))
end
@assert response isa HTTP.Response
println(text)
```

Handle [Server-Sent Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events)
by passing an `sse_callback` function to `HTTP.request`:

```julia
using HTTP

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
        body = payload,
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
[migration-guide-url]: https://juliaweb.github.io/HTTP.jl/dev/guides/migration-1x/
