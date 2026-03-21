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

If you only need to stream into an `IO`, prefer the `response_body` keyword:

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
response = HTTP.get(base_url * "/buffered"; response_body = buffer, proxy = HTTP.ProxyConfig())
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
- `FixedLengthBody`, `ChunkedBody`, and `ManagedBody` for streamed bodies
- `EmptyBody` for requests or responses with no payload
- `Form` when you need a multipart/form-data request body

## Retries, Timeouts, and Tracing

The retry path is explicit and conservative. For predictable behavior, prefer a
long-lived `Client` over relying solely on default top-level behavior.

Reach for these APIs when you need more control:

- `RetryBucket` for coordinated retry throttling
- `ClientTrace` for request lifecycle callbacks
- `connect_timeout` and `readtimeout` keywords on `request`
- `retry_if`, `retry_non_idempotent`, and `respect_retry_after` for custom retry policy
