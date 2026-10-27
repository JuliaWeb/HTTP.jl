```@meta
CurrentModule = HTTP
```

# HTTP.jl

HTTP.jl is an HTTP client and server library for Julia. It speaks HTTP/1.1 and
HTTP/2, and its client can opt in to HTTP/3. It streams request and response
bodies, and supports WebSockets and server-sent events.
[Reseau](https://github.com/JuliaServices/Reseau.jl) provides the TCP, DNS,
TLS, and QUIC layers.

## Quick Start

Start a server, send it a request, and read the response body:

```julia
using HTTP

server = HTTP.serve!("127.0.0.1", 0) do req
    return HTTP.Response(200; body = "hello from HTTP.jl")
end

resp = HTTP.get("http://127.0.0.1:$(HTTP.port(server))/hello")
HTTP.forceclose(server)
String(resp.body)  # "hello from HTTP.jl"
```

Port `0` asks the operating system for a free port; `HTTP.port(server)`
returns the one it chose.

## Where to Go Next

- The [Client guide](guides/client.md) covers requests, streaming, reusable
  clients, request bodies, retries, and timeouts.
- The [Server guide](guides/server.md) covers request and stream handlers,
  routing, static files, server-sent events, and server timeouts.
- The [Protocols guide](guides/protocols.md) covers WebSockets, HTTP/2, and HTTP/3.
- The [Migration guide](guides/migration-1x.md) explains how to update code
  written for HTTP.jl 1.x.
- The [API reference](api/reference.md) lists every public name with its
  docstring.

## Docs for LLMs

The documentation is also published as plain Markdown for LLM tools, following
the [llms.txt](https://llmstxt.org/) convention:

- [llms.txt](https://juliaweb.github.io/HTTP.jl/stable/llms.txt): a short index of the pages.
- [llms-full.txt](https://juliaweb.github.io/HTTP.jl/stable/llms-full.txt): every page, with all docstrings expanded, in one file.

Give either file to an assistant when you ask it about HTTP.jl.
