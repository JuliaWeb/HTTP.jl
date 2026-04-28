```@meta
CurrentModule = HTTP
```

# Client Guide

The top-level request helpers are intentionally familiar, but in 2.0 the
underlying pieces are explicit and reusable.

The short version:

- use `HTTP.request` or verb helpers for eager responses
- use `HTTP.open` or `response_stream` for streaming
- use `HTTP.Client` when you want one reusable bundle of transport, retry,
  cookie, proxy, and HTTP/2 preferences
- use phase-specific timeout keywords instead of the old `readtimeout`

## High-Level Requests

`HTTP.request` is the main entrypoint. The verb helpers such as `HTTP.get` and
`HTTP.post` are convenience wrappers around it.

```julia
using HTTP

server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
    payload = if req.target == "/stream"
        "streaming response body"
    else
        "$(req.method) $(req.target)"
    end
    return HTTP.Response(
        200;
        headers = ["Content-Type" => "text/plain"],
        body = payload,
    )
end

base_url = "http://127.0.0.1:$(HTTP.port(server))"
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
server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
    payload = req.target == "/stream" ? "streaming response body" : "$(req.method) $(req.target)"
    return HTTP.Response(
        200;
        headers = ["Content-Type" => "text/plain"],
        body = payload,
    )
end

base_url = "http://127.0.0.1:$(HTTP.port(server))"
HTTP.open(:GET, base_url * "/stream"; proxy = HTTP.ProxyConfig()) do stream
    response_text = String(read(stream))
    HTTP.forceclose(server)
    response_text
end
```

If you only need to stream into an `IO`, use the `response_stream` keyword:

```julia
server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
    payload = req.target == "/stream" ? "streaming response body" : "$(req.method) $(req.target)"
    return HTTP.Response(
        200;
        headers = ["Content-Type" => "text/plain"],
        body = payload,
    )
end

base_url = "http://127.0.0.1:$(HTTP.port(server))"
buffer = IOBuffer()
response = HTTP.get(base_url * "/buffered"; response_stream = buffer, proxy = HTTP.ProxyConfig())
seekstart(buffer)
HTTP.forceclose(server)
(status = response.status, body = String(take!(buffer)))
```

## Reusing a `Client`

Construct a `Client` when a set of options should travel together across many
requests. Top-level calls already reuse default connection and cookie machinery;
a `Client` gives you an explicit owner for a particular transport, cookie jar,
retry bucket, proxy policy, and HTTP/2 preference.

```julia
server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
    payload = req.target == "/stream" ? "streaming response body" : "$(req.method) $(req.target)"
    return HTTP.Response(
        200;
        headers = ["Content-Type" => "text/plain"],
        body = payload,
    )
end

base_url = "http://127.0.0.1:$(HTTP.port(server))"
retry_bucket = HTTP.RetryBucket(capacity = 100)
transport = HTTP.Transport(
    max_idle_per_host = 2,
    max_idle_total = 4,
    proxy = HTTP.ProxyConfig(),
)
client = HTTP.Client(
    transport = transport,
    cookiejar = HTTP.CookieJar(),
    retry_bucket = retry_bucket,
)
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
- coordinated retries through a shared `RetryBucket`

## Request and Response Bodies

The top-level request helpers buffer response bodies into `Vector{UInt8}` by
default. For request and server-response bodies, ordinary strings, byte vectors,
forms, and `IO` objects cover the common user-facing cases. Lower-level body
wrappers exist for the protocol implementation and custom streaming extensions,
but most application code should not need to construct them directly.

## Retries and Timeouts

The retry path is explicit and conservative. For predictable behavior, prefer a
long-lived `Client` over relying solely on default top-level behavior.

```julia
bucket = HTTP.RetryBucket(capacity = 100)

function retry_if(attempt, err, req, resp)
    if err !== nothing
        return attempt <= 2
    end
    return resp !== nothing && resp.status in (429, 503) && attempt <= 3
end

url = "https://example.com"
response = HTTP.get(
    url;
    retry = true,
    retries = 3,
    retry_bucket = bucket,
    retry_if = retry_if,
    respect_retry_after = true,
)
```

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

The full custom retry callback signature is:

```julia
retry_if(attempt::Integer, err, req::HTTP.Request, resp) -> Union{Bool,Nothing}
```

When it runs for a request-path failure, `err` is a `RequestRetryError`; inspect
`err.err` to see the underlying transport or protocol exception. Response-based
retry decisions keep `err = nothing` and pass the response through `resp`.
Returning `true` requests another attempt when the request body can be replayed,
`false` suppresses a retry, and `nothing` defers to the built-in retry rules.

### 1.x Compatibility Keywords

HTTP.jl 2.0 accepts several 1.x client keywords as migration aids. Treat them
as temporary compatibility, not as the preferred API:

- `readtimeout` maps to `read_idle_timeout`
- `pool` should become a long-lived `Client` or `Transport`
- `retry_delays` and `retry_check` should become `retry_if`, `retries`, and
  `retry_bucket`
- `sslconfig` and `socket_type_tls` should move to transport/TLS configuration
- `copyheaders`, `canonicalize_headers`, `detect_content_type`,
  `observelayers`, `logerrors`, and `logtag` are accepted for compatibility
  where possible

See the [migration guide](migration-1x.md) for before/after examples.
