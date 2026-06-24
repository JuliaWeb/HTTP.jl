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

- `HTTP.get`, `HTTP.head`, `HTTP.query`, `HTTP.post`, `HTTP.put`, `HTTP.patch`, `HTTP.delete`, `HTTP.options`
- `HTTP.request` for the fully general call shape
- `HTTP.open` when you want streaming control instead of an eagerly consumed body

## Streaming Responses

`HTTP.open` gives you pull-based control over the response stream while still
using the normal redirect/decompression machinery.

```julia
using HTTP

server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
    payload = req.target == "/stream" ? "streaming response body" : "$(req.method) $(req.target)"
    return HTTP.Response(
        200;
        headers = ["Content-Type" => "text/plain"],
        body = payload,
    )
end

base_url = "http://127.0.0.1:$(HTTP.port(server))"
response = HTTP.open(:GET, base_url * "/stream"; proxy = HTTP.ProxyConfig()) do stream
    response_text = String(read(stream))
    @info "got body" response_text
end
HTTP.forceclose(server)
response
```

The `do`-block form returns the final [`HTTP.Response`](@ref), not the value
returned by the `do` block. Capture anything you want to keep from inside the
block in an outer variable.

If you only need to stream into an `IO`, use the `response_stream` keyword:

```julia
using HTTP

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
using HTTP

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
- explicit proxy routing with `ProxyConfig`, `ProxyURL`, `ProxyFromEnvironment`, and `NoProxy`;
  proxy URLs may use `http://`, `socks5://`, or `socks5h://`
- coordinated retries through a shared `RetryBucket`
- binding outbound connections to a specific source address/interface with `local_addr`

### Binding to a local address

Like Go's `net.Dialer.LocalAddr` (and `curl --interface`), `local_addr` selects the
source IP — and therefore the outgoing interface — for a client's connections. This
is useful on multi-homed hosts or to separate traffic by interface. Pass an IP-literal
string (the kernel chooses an ephemeral source port) or a `Reseau.TCP.SocketAddrV4` /
`SocketAddrV6` for full control including a fixed source port:

```julia
# All requests from this client leave via 192.0.2.10.
client = HTTP.Client(local_addr = "192.0.2.10")
HTTP.get("http://example.com"; client = client)

# Equivalent, set on the transport (the canonical home — local_addr is a
# connection-pool property, so each bound client keeps its own pool):
client = HTTP.Client(transport = HTTP.Transport(local_addr = "192.0.2.10"))
```

The address must be an IP assigned to a local interface; binding to an unassigned
address fails fast. Interface *names* are not accepted — resolve them to an IP first.

### Per-`Client` defaults

`Client` can also act as a configuration container, just like
`requests.Session()` or `axios.create()` in other ecosystems. Defaults set on
the client apply to every request issued through it; per-call keywords always
win when both are provided.

```julia
client = HTTP.Client(
    default_headers = ["User-Agent" => "MyApp/1.0", "X-API-Version" => "v2"],
    default_query = Dict("api_key" => "secret"),
    default_basicauth = "alice" => "password",
    request_timeout = 30,
    connect_timeout = 5,
    read_idle_timeout = 10,
)

# Defaults applied automatically.
HTTP.get(client, "https://api.example.com/users")

# Per-call values override defaults for this call only.
HTTP.get(client, "https://api.example.com/users";
    headers = ["X-API-Version" => "v1"],
    request_timeout = 60,
)
```

Recognized client defaults:

- `default_headers`: vector or dict of headers added when not present per-call
- `default_query`: dict, named-tuple, or vector-of-pairs of query parameters; per-call keys override matching defaults
- `default_basicauth`: applied unless the call passes `basicauth` or an explicit `Authorization` header
- `connect_timeout`, `request_timeout`, `response_header_timeout`,
  `read_idle_timeout`, `write_idle_timeout`: applied when the per-call timeout
  is `0` (the default)

### Positional `Client` calls

The verb helpers also accept the `Client` positionally — `HTTP.get(client, url)`
is equivalent to `HTTP.get(url; client = client)`. This works for `get`, `head`,
`post`, `put`, `patch`, `delete`, `options`, `request`, and `open`.

### Closed clients are poisoned

After `close(client)`, subsequent calls that use it raise `ArgumentError`:

```julia
client = HTTP.Client()
HTTP.get(client, "https://example.com")
close(client)
HTTP.get(client, "https://example.com")  # throws ArgumentError("HTTP.Client is closed")
```

Use `isopen(client)` to check the live state.

## Cancelling an in-flight request

Pass an `HTTP.RequestContext` via the `context` keyword to give an external
task control over an outstanding request. Calling `HTTP.cancel!(ctx)` from
another task aborts the in-flight read/write and the spawning task observes an
`HTTP.CanceledError`. HTTP/1 cancellation closes the active connection, while
HTTP/2 cancellation resets the active stream:

```julia
ctx = HTTP.RequestContext()
task = Threads.@spawn HTTP.get("https://slow.example.com/long"; context = ctx)
sleep(0.5)
HTTP.cancel!(ctx; message = "user pressed Ctrl-C")
try
    fetch(task)
catch e
    inner = e isa Base.TaskFailedException ? e.task.exception : e
    @assert inner isa HTTP.CanceledError
end
```

The same `context` keyword works on `HTTP.request`, `HTTP.get`/`head`/`post`/
`put`/`patch`/`delete`/`options`, `HTTP.open`, and the lower-level `HTTP.do!`.
Combined with a deadline (`HTTP.RequestContext(deadline_ns = ...)` or
`HTTP.set_deadline!(ctx, ...)`) the same `context` value can drive both
absolute deadlines and external cancellation.

## Request and Response Bodies

The top-level request helpers buffer response bodies into `Vector{UInt8}` by
default. For request and server-response bodies, ordinary strings, byte vectors,
forms, and `IO` objects cover the common user-facing cases. Lower-level body
wrappers exist for the protocol implementation and custom streaming extensions,
but most application code should not need to construct them directly.

### Reading the response body

Convert the raw bytes to a `String` when you want text:

```julia
using HTTP

response = HTTP.get("http://example.com")
text = String(response.body)
```

!!! warning "`String(response.body)` consumes the bytes"
    `String(::Vector{UInt8})` aliases the underlying buffer rather than
    copying it, so `response.body` is left empty (`length == 0`) once the
    `String` has been constructed. If you want to keep the bytes around for a
    second read, use `String(copy(response.body))` (or `copy(response.body)`
    if you want raw bytes), or stream into a sink you own with
    `response_stream = IOBuffer()`.

### Sending JSON

HTTP.jl ships without a JSON dependency, so the request body is yours to
serialize. The recommended JSON library is
[JSON.jl](https://github.com/JuliaIO/JSON.jl) — pair it with an explicit
`Content-Type: application/json` header:

```julia
using HTTP, JSON

payload = Dict("name" => "alice", "age" => 30)
response = HTTP.post(
    "https://api.example.com/users";
    headers = ["Content-Type" => "application/json"],
    body = JSON.json(payload),
)

returned = JSON.parse(String(response.body))
```

The verb helpers accept the body either positionally
(`HTTP.post(url, headers, body)`) or via the `body=` keyword as shown above.

### Sending form data

`HTTP.post(url, [], dict)` (or `NamedTuple`) auto-serializes to
`application/x-www-form-urlencoded` and sets the matching `Content-Type` header
for you:

```julia
HTTP.post("http://example.com/login", [], Dict("user" => "alice", "pw" => "s3cret"))
```

For `multipart/form-data` (file uploads), use [`HTTP.Form`](@ref):

```julia
form = HTTP.Form(Dict("file" => open("upload.bin", "r"), "kind" => "binary"))
HTTP.post("http://example.com/upload", [], form)
```

### Sending QUERY requests

RFC 10008 defines `QUERY` for safe, idempotent requests with content. Use
`HTTP.query` when a request needs a body but has GET-like semantics:

```julia
HTTP.query(
    "https://api.example.com/search";
    headers = ["Content-Type" => "application/json"],
    body = """{"select":["name","email"],"limit":10}""",
)
```

`Dict` and `NamedTuple` bodies are encoded the same way as `HTTP.post` form
bodies, with `Content-Type: application/x-www-form-urlencoded` set
automatically:

```julia
HTTP.query("https://api.example.com/search"; body = (select = "name", limit = 10))
```

Servers that support `QUERY` can advertise accepted query content media types
with the `Accept-Query` response header.

### Query parameters

The `query` keyword URL-encodes a `Dict` or vector of pairs and appends them
to the URL's query string. Use it instead of building the query string by hand.

```julia
HTTP.get("http://example.com/search"; query = Dict("page" => 2, "limit" => 10))
# GET /search?limit=10&page=2
```

A `Dict` is convenient but does not preserve order. Pass a vector of pairs
when ordering matters:

```julia
HTTP.get("http://example.com/search"; query = ["page" => 2, "tag" => "hot"])
# GET /search?page=2&tag=hot
```

Repeat a key in the vector form to send the same parameter multiple times:

```julia
HTTP.get("http://example.com/search"; query = ["tag" => "a", "tag" => "b"])
# GET /search?tag=a&tag=b
```

`query` is *appended* to any existing query string in the URL — it does not
replace it:

```julia
HTTP.get("http://example.com/search?type=user"; query = ["page" => 2])
# GET /search?type=user&page=2
```

#### Reading query parameters on the server

Server-side, `req.target` holds the request path plus its query string. Use
`HTTP.URI` to split the two and `HTTP.queryparams` (returns a `Dict`) or
`HTTP.queryparampairs` (preserves order and repeated keys) to decode them:

```julia
HTTP.serve!("127.0.0.1", 8080) do req
    uri = HTTP.URI(req.target)
    params = HTTP.queryparams(uri.query)            # Dict{String,String}
    pairs  = HTTP.queryparampairs(uri.query)        # Vector{Pair{String,String}}
    return HTTP.Response(200; body = "got $(length(params)) params")
end
```

#### Reading POST form parameters on the server

A request body sent as `application/x-www-form-urlencoded` — the default for HTML
form posts, and what `HTTP.post(url, [], dict)` produces — uses the same encoding
as a URL query string, except that a space is written as `+`. `HTTP.queryparams`
decodes both `+` and `%20` to a space, so you can decode a form body by passing it
straight to `queryparams` (or `queryparampairs` to preserve order and repeated
keys):

```julia
HTTP.serve!("127.0.0.1", 8080) do req
    params = HTTP.queryparams(String(req.body))     # Dict{String,String}
    user = get(params, "user", "anonymous")
    return HTTP.Response(200; body = "hello $user")
end
```

This decodes the client-side `Dict`/`NamedTuple` form encoding shown under
"Sending form data" above — for example a posted `user=a b` decodes back to
`Dict("user" => "a b")`.

## Retries and Timeouts

The retry path is explicit and conservative. For predictable behavior, prefer a
long-lived `Client` over relying solely on default top-level behavior.

```julia
using HTTP

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

- `connect_timeout` bounds DNS, TCP connect, HTTP proxy `CONNECT` or SOCKS5
  handshakes, TLS handshake, and HTTP/2 session setup
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
using HTTP

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

### Debugging Requests

When a request misbehaves, `verbose` prints what the client is doing on the
wire. `verbose = 1` shows one-line attempt/response/done summaries;
`verbose = 2` adds the request and response head text:

```julia
HTTP.get("http://example.com"; verbose = 2)
```

Sample output:

```
[http] request attempt 1 GET http://example.com/ via h1
[http] request
GET / HTTP/1.1
Host: example.com
Accept-Encoding: gzip, deflate
User-Agent: HTTP.jl/2.0.0
[http] response attempt 1 200 for http://example.com/
[http] response
HTTP/1.1 200 OK
Content-Length: 1256
[http] done 200 for http://example.com/
```

For programmatic introspection — for example, to push events into your own
logger — pass a `trace` callback. The callback receives subtypes of
`HTTP.ClientEvent`:

- [`HTTP.RequestEvent`](@ref) — request being sent
- [`HTTP.ResponseHeadEvent`](@ref) — response headers received
- [`HTTP.RetryEvent`](@ref) — retry scheduled
- [`HTTP.RedirectEvent`](@ref) — redirect followed
- [`HTTP.DoneEvent`](@ref) — request finished (with response or error)

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
