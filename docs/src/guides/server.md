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

function wait_for_base_url(server)
    for _ in 1:100
        port = HTTP.port(server)
        if port != 0
            base_url = "http://127.0.0.1:$(port)"
            try
                HTTP.get(
                    base_url * "/";
                    status_exception = false,
                    proxy = HTTP.ProxyConfig(),
                    connect_timeout = 0.1,
                    readtimeout = 0.1,
                )
                return base_url
            catch
            end
        end
        sleep(0.01)
    end
    error("server did not start listening in time")
end

server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
    payload = "handled " * req.target
    return HTTP.Response(
        200;
        headers = ["X-Handler" => "request"],
        body = HTTP.BytesBody(codeunits(payload)),
        content_length = ncodeunits(payload),
    )
end

base_url = wait_for_base_url(server)
resp = HTTP.get(base_url * "/health"; proxy = HTTP.ProxyConfig())
HTTP.forceclose(server)
(status = resp.status, header = HTTP.header(resp, "X-Handler"), body = String(resp.body))
```

This is the simplest server path and the best default for ordinary APIs.

## Stream Handlers

Use `HTTP.listen!` or `stream=true` when you need lower-level ownership of the
connection lifecycle. `HTTP.streamhandler` is the bridge when you want stream
server mechanics with a request-style handler body.

```julia
function wait_for_base_url(server)
    for _ in 1:100
        port = HTTP.port(server)
        if port != 0
            base_url = "http://127.0.0.1:$(port)"
            try
                HTTP.get(
                    base_url * "/";
                    status_exception = false,
                    proxy = HTTP.ProxyConfig(),
                    connect_timeout = 0.1,
                    readtimeout = 0.1,
                )
                return base_url
            catch
            end
        end
        sleep(0.01)
    end
    error("server did not start listening in time")
end

stream_server = HTTP.serve!(
    HTTP.streamhandler() do req
        payload = "stream handler"
        return HTTP.Response(
            201;
            body = HTTP.BytesBody(codeunits(payload)),
            content_length = ncodeunits(payload),
        )
    end,
    "127.0.0.1",
    0;
    stream = true,
    listenany = true,
)

stream_url = wait_for_base_url(stream_server)
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

## SSE and Long-Lived Responses

`HTTP.jl` exposes `SSEEvent`, `SSEStream`, and `sse_stream` for server-sent
events. Use these when you want a proper `text/event-stream` response instead
of hand-assembling event lines.

## HTTP/2 Servers

The same server entrypoints can serve HTTP/2 when TLS/ALPN or a cleartext
HTTP/2 preface selects it. Most applications do not need a separate server API
for HTTP/2; use the normal `serve!`, `listen!`, and `streamhandler` surfaces.
