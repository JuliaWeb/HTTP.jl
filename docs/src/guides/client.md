```@meta
CurrentModule = HTTP
```

# Client Guide

The top-level request helpers are intentionally familiar, but in 2.0 the
underlying pieces are explicit and reusable.

## High-Level Requests

`HTTP.request` is the main entrypoint. The verb helpers such as `HTTP.get` and
`HTTP.post` are convenience wrappers around it.

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
                    request_timeout = 0.1,
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
    payload = if req.target == "/stream"
        "streaming response body"
    else
        "$(req.method) $(req.target)"
    end
    return HTTP.Response(
        200;
        headers = ["Content-Type" => "text/plain"],
        body = HTTP.BytesBody(codeunits(payload)),
        content_length = ncodeunits(payload),
    )
end

base_url = wait_for_base_url(server)
resp = HTTP.request("GET", base_url * "/requests"; proxy = HTTP.ProxyConfig())
HTTP.forceclose(server)
(status = resp.status, body = String(resp.body))
```

Useful top-level request helpers:

- `HTTP.get`, `HTTP.head`, `HTTP.post`, `HTTP.put`, `HTTP.patch`, `HTTP.delete`, `HTTP.options`
- `HTTP.request` for the fully general call shape
- `HTTP.open` when you want streaming control instead of an eagerly consumed body

## Streaming Responses

`HTTP.open` gives you pull-based control over the response stream while still
using the normal redirect/decompression machinery.

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
                    request_timeout = 0.1,
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
    payload = req.target == "/stream" ? "streaming response body" : "$(req.method) $(req.target)"
    return HTTP.Response(
        200;
        headers = ["Content-Type" => "text/plain"],
        body = HTTP.BytesBody(codeunits(payload)),
        content_length = ncodeunits(payload),
    )
end

base_url = wait_for_base_url(server)
HTTP.open(:GET, base_url * "/stream"; proxy = HTTP.ProxyConfig()) do stream
    response_text = String(read(stream))
    HTTP.forceclose(server)
    response_text
end
```

If you only need to stream into an `IO`, use the `response_stream` keyword:

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
                    request_timeout = 0.1,
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
    payload = req.target == "/stream" ? "streaming response body" : "$(req.method) $(req.target)"
    return HTTP.Response(
        200;
        headers = ["Content-Type" => "text/plain"],
        body = HTTP.BytesBody(codeunits(payload)),
        content_length = ncodeunits(payload),
    )
end

base_url = wait_for_base_url(server)
buffer = IOBuffer()
response = HTTP.get(base_url * "/buffered"; response_stream = buffer, proxy = HTTP.ProxyConfig())
seekstart(buffer)
HTTP.forceclose(server)
(status = response.status, body = String(take!(buffer)))
```

## Reusing a `Client`

Construct a `Client` when you want connection reuse, a shared cookie jar,
custom proxy settings, or an explicit retry posture.

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
                    request_timeout = 0.1,
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
    payload = req.target == "/stream" ? "streaming response body" : "$(req.method) $(req.target)"
    return HTTP.Response(
        200;
        headers = ["Content-Type" => "text/plain"],
        body = HTTP.BytesBody(codeunits(payload)),
        content_length = ncodeunits(payload),
    )
end

base_url = wait_for_base_url(server)
transport = HTTP.Transport(max_idle_per_host = 2, max_idle_total = 4, proxy = HTTP.ProxyConfig())
client = HTTP.Client(transport = transport, cookiejar = HTTP.CookieJar())
client_response = HTTP.request("GET", base_url * "/reused"; client = client)
close(client)
HTTP.forceclose(server)
(status = client_response.status, body = String(client_response.body))
```

Important `Client` and `Transport` knobs:

- `prefer_http2 = true` to prefer ALPN-negotiated HTTP/2 for secure traffic
- connection-pool sizing via `max_idle_per_host` and `max_idle_total`
- shared `CookieJar` state across related requests
- explicit proxy routing with `ProxyConfig`, `ProxyURL`, `ProxyFromEnvironment`, and `NoProxy`

## Request and Response Bodies

The top-level request helpers buffer response bodies into `Vector{UInt8}` by
default. Lower-level APIs such as `HTTP.open`, `roundtrip!`, and stream/server
internals expose explicit body types instead.

Common body-related types:

- `BytesBody` for already-buffered data
- `FixedLengthBody`, `ChunkedBody`, and `EOFBody` for streamed bodies
- `EmptyBody` for requests or responses with no payload
- `Form` when you need a multipart/form-data request body

## Retries, Timeouts, and Tracing

The retry path is explicit and conservative. For predictable behavior, prefer a
long-lived `Client` over relying solely on default top-level behavior.

### Request Tracing and Verbose Output

`HTTP.request` accepts an optional leading trace callback:

```julia
using HTTP

function trace(event::HTTP.RequestEvent)
    @info "request" method = event.request.method url = event.url attempt = event.attempt
end

function trace(event::HTTP.ResponseHeadEvent)
    @info "response" status = event.response.status url = event.url
end

function trace(event::HTTP.DoneEvent)
    @info "done" url = event.url error = event.err
end

response = HTTP.request(trace, "GET", url)
```

The current event set is:

- `HTTP.RequestEvent`
- `HTTP.ResponseHeadEvent`
- `HTTP.RetryEvent`
- `HTTP.RedirectEvent`
- `HTTP.DoneEvent`

Verbose output is implemented on top of the same event path:

```julia
HTTP.request(trace, "GET", url; verbose = true)
```

`verbose = true` or `verbose = 1` prints one-line lifecycle messages to
`stdout`, while `verbose = 2` also prints request and response heads. When both
are used together, verbose output is emitted before the user callback runs.

### Timeout Model

The client APIs now expose timeout controls by phase instead of only a single
read timeout:

- `connect_timeout` bounds DNS, TCP connect, proxy `CONNECT`, TLS handshake,
  and HTTP/2 session setup
- `request_timeout` is the overall deadline for the whole exchange
- `response_header_timeout` bounds the wait from "request sent" to "response
  headers available"
- `read_idle_timeout` bounds inactivity between inbound read-progress events,
  including response-header waits when `response_header_timeout` is unset
- `write_idle_timeout` bounds inactivity between outbound write-progress events
- `expect_continue_timeout` controls how long HTTP/1 uploads wait on
  `100-continue` before sending the body anyway

`readtimeout` is still accepted for compatibility, but it is deprecated and now
behaves like `read_idle_timeout`.

For example:

```julia
resp = HTTP.get(
    url;
    connect_timeout = 2.0,
    response_header_timeout = 5.0,
    read_idle_timeout = 30.0,
)
```

`HTTP.open` uses the same timeout model, and `HTTP.WebSockets.open` uses the
handshake-relevant subset (`connect_timeout`, `request_timeout`,
`response_header_timeout`, `read_idle_timeout`, and `write_idle_timeout`).

Reach for these APIs when you need more control:

- `RetryBucket` for coordinated retry throttling
- `connect_timeout`, `request_timeout`, `response_header_timeout`,
  `read_idle_timeout`, `write_idle_timeout`, and `expect_continue_timeout`
  on `request`
- `retry_if`, `retry_non_idempotent`, and `respect_retry_after` for custom retry policy

When `retry_if` runs for a request-path failure, `err` is a
`RequestRetryError`; inspect `err.err` to see the underlying transport or
protocol exception. Response-based retry decisions keep `err = nothing` and
pass the response through `resp`.
