# Migration From HTTP.jl 1.x

HTTP.jl 2.0 is a breaking release. Code that stayed on the common
`HTTP.get`, `HTTP.post`, `HTTP.request`, and basic `HTTP.serve!` workflows
should usually migrate with small edits. Code that reached into parser,
connection-pool, layer-stack, HPACK, or HTTP/2 internals should move to the
documented 2.0 API instead of chasing renamed internals.

The Before/After snippets below are intentionally minimal — they show the API
shape change, not full runnable programs. Each runnable snippet assumes the
caller has already issued `using HTTP`, plus any extra `using` statements
shown in-line (for example `using JSON` for JSON examples or `using Downloads`
for the [`HTTP.download`](#httpdownload) discussion).

The most important 2.0 changes are:

- Julia 1.10 is the minimum supported Julia version.
- HTTP.jl now delegates transport, resolver, and TLS substrate work to Reseau.
- `HTTP.Headers` is now a standalone mutable header struct rather than an alias
  for a vector of substring pairs.
- `Request`, `Response`, `Headers`, `RequestContext`, bodies, `Client`,
  `Transport`, `Server`, and `Stream` are the core public building blocks.
- Top-level request helpers buffer `Response.body::Vector{UInt8}` by default.
- `RequestContext` is typed request state, not a plain `Dict`.
- Client pooling, retries, TLS, proxying, and timeouts use more explicit
  `Client` / `Transport` / keyword configuration.
- WebSocket entrypoints live under `HTTP.WebSockets`.

## Recommended Upgrade Order

1. Upgrade Julia and dependency compat so HTTP.jl 2.0 can be resolved.
2. Update high-level client calls and response field access.
3. Update explicit `Request` / `Response` constructors.
4. Replace direct connection-pool, layer, parser, HPACK, or HTTP/2 internals
   with documented `Client`, `Transport`, `Stream`, server, or WebSocket APIs.
5. Re-test timeout, retry, proxy, cookie, streaming, WebSocket, SSE, and HTTP/2
   paths explicitly.

## High-Level Requests

Most simple request calls still look the same.

Before:

```julia
resp = HTTP.get(url)
text = String(resp.body)
```

After:

```julia
resp = HTTP.get(url)
text = String(resp.body)
```

By default, `HTTP.request` and verb helpers return a fully materialized
`Vector{UInt8}` in `resp.body`. For streaming, use `response_stream` or
`HTTP.open`.

Before:

```julia
open("payload.bin", "w") do io
    HTTP.get(url; response_stream = io)
end
```

After:

```julia
open("payload.bin", "w") do io
    resp = HTTP.get(url; response_stream = io)
    @assert resp.body === nothing
end
```

In 1.x, the supplied `response_stream` object could also appear as
`resp.body`. In 2.0, the sink remains owned by the caller; read the data back
from the original `IO` or byte buffer you passed as `response_stream`.

## `HTTP.download`

The dedicated 1.x `HTTP.download` helper has been removed in HTTP.jl 2.0.

!!! warning "`HTTP.download` still resolves — but it is no longer HTTP.jl's"
    Because `HTTP` re-exports `Base.download`, calls like
    `HTTP.download(url, path)` continue to work. Those calls now go through
    `Base.download` (which is itself backed by the `Downloads` standard
    library), **not** through HTTP.jl's request stack. The 1.x keyword
    arguments (`proxy`, `retry`, `headers`, `client`, `transport`, TLS
    configuration, etc.) are not recognized by `Base.download` — passing them
    raises `MethodError` rather than silently being applied. Update such call
    sites to use one of the patterns below.

For the closest direct replacement, use the `Downloads.download` function from
Julia's standard library:

```julia
using Downloads

Downloads.download(url, "payload.bin")
```

If you want to keep all request handling inside HTTP.jl, stream the response
body into an `IOStream` that you own:

```julia
using HTTP

open("payload.bin", "w") do io
    resp = HTTP.request("GET", url; response_stream = io)
    @assert 200 <= resp.status < 300
    @assert resp.body === nothing
end
```

Use this pattern when you need HTTP.jl client configuration such as custom
headers, retries, proxy settings, TLS configuration, or a reusable
`HTTP.Client`. Use `Downloads.download` when you just need a URL copied to a
file.

For pull-based streaming:

```julia
using HTTP

HTTP.open(:GET, url) do stream
    response = HTTP.startread(stream)
    @info "status" response.status
    output = IOBuffer()
    buf = Vector{UInt8}(undef, 8192)
    while true
        n = readbytes!(stream, buf)
        n == 0 && break
        write(output, @view buf[1:n])
    end
    @info "captured bytes" length(take!(output))
end
```

Like all `HTTP.open` `do`-block calls, the form above returns the final
[`HTTP.Response`](@ref) — capture data you want to keep in an outer variable
rather than as the value of the `do` block.

## Request and Response Constructors

Common 1.x positional constructors remain accepted as migration shims, including
string and byte-vector request or response bodies:

```julia
req = HTTP.Request("POST", "/widgets", ["Content-Type" => "text/plain"], "hello")
resp = HTTP.Response(201, ["Location" => "/widgets/1"], "created")
```

New code may use the keyword forms when it needs explicit headers, trailers,
protocol metadata, or context ownership:

```julia
req = HTTP.Request(
    "POST",
    "/widgets";
    headers = ["Content-Type" => "text/plain"],
    body = "hello",
)
```

## Headers

`HTTP.Headers` is the canonical mutable header container. It preserves pair
order and canonicalizes header keys on insertion.

Before:

```julia
headers = ["content-type" => "application/json"]
```

After:

```julia
headers = HTTP.Headers(["content-type" => "application/json"])
HTTP.setheader(headers, "x-request-id", request_id)
```

Useful helpers include `HTTP.header`, `HTTP.headers`, `HTTP.hasheader`,
`HTTP.headercontains`, `HTTP.setheader`, `HTTP.appendheader`, and
`HTTP.removeheader`.

## Request Context

In 1.x, middleware often treated request context as a plain dictionary. In 2.0,
`RequestContext` is typed request state with deadline, cancellation, metadata,
and timeout fields. Dict-like symbol-key metadata access still works for
migration.

Before:

```julia
req.context[:request_id] = request_id
```

After:

```julia
ctx = HTTP.get_request_context(req)
ctx[:request_id] = request_id
```

Reading application metadata remains familiar:

```julia
request_id = get(HTTP.get_request_context(req), :request_id, nothing)
```

Use the typed helpers for control flow:

```julia
ctx = HTTP.get_request_context(req)
HTTP.set_deadline!(ctx, time_ns() + 5_000_000_000)
HTTP.cancel!(ctx; message = "caller disconnected")
HTTP.canceled(ctx) && throw(HTTP.CanceledError("request canceled"))
```

For compatibility, `req.context` returns the metadata view. Use
`HTTP.get_request_context(req)` whenever you need cancellation, deadlines, or
timeout state.

## Reusable Clients and Pooling

The 1.x `pool` keyword and old connection-pool internals are replaced by
`Client` and `Transport`.

Before:

```julia
resp = HTTP.get(url; pool = pool)
```

After:

```julia
transport = HTTP.Transport(max_idle_per_host = 4, max_idle_total = 32)
client = HTTP.Client(transport = transport, cookiejar = HTTP.CookieJar())

try
    resp = HTTP.get(url; client = client)
finally
    close(client)
end
```

Use a long-lived `Client` when you want connection reuse, shared cookies, proxy
configuration, retry buckets, and HTTP/2 preference to be consistent across
many requests.

## `HTTP.@client`

In 1.x, `HTTP.@client` composed one request middleware chain plus, optionally, a
stream middleware chain. In 2.0, each position may be a single middleware or a
tuple of middlewares:

```julia
HTTP.@client request_middleware
HTTP.@client request_middleware stream_middleware
HTTP.@client (outer_request, inner_request) (outer_stream, inner_stream)
```

Request middlewares wrap high-level `request(...)` calls. Stream middlewares
wrap `HTTP.open(...)` calls. Tuple entries are applied in order, so the first
middleware listed is the outermost wrapper.

## Retries

HTTP.jl 2.0 retries are explicit and conservative. The old `retry_delays` and
`retry_check` keywords are accepted as compatibility shims, but new code should
use `retry`, `retries`, `retry_if`, `respect_retry_after`, and
[`HTTP.RetryBucket`](@ref).

Before:

```julia
resp = HTTP.get(url; retry = true, retry_delays = [0.1, 0.5, 1.0])
```

After:

```julia
bucket = HTTP.RetryBucket()
resp = HTTP.get(
    url;
    retry = true,
    retries = 3,
    retry_bucket = bucket,
    respect_retry_after = true,
)
```

Custom retry decisions move to `retry_if`.

```julia
function retry_if(attempt, err, req, resp)
    if err !== nothing
        return attempt <= 2
    end
    return resp !== nothing && resp.status == 503 && attempt <= 3
end

resp = HTTP.get(url; retry_if = retry_if)
```

The full callback signature is:

```julia
retry_if(attempt::Integer, err, req::HTTP.Request, resp) -> Union{Bool,Nothing}
```

`attempt` is the current one-based attempt number. `err` is a
`HTTP.RequestRetryError` for request-path failures; inspect `err.err` for the
underlying transport or protocol exception. Response-based decisions pass
`err = nothing` and the response in `resp`. Returning `true` requests another
attempt when the body can be replayed, `false` suppresses a retry, and `nothing`
uses the built-in retry rules.

## Timeouts

The 1.x `readtimeout` keyword is deprecated. It is still accepted, but now maps
to `read_idle_timeout`.

Before:

```julia
resp = HTTP.get(url; connect_timeout = 5, readtimeout = 30)
```

After:

```julia
resp = HTTP.get(
    url;
    connect_timeout = 5,
    request_timeout = 60,
    response_header_timeout = 10,
    read_idle_timeout = 30,
)
```

Use the timeout that matches your intent:

- `connect_timeout` bounds DNS, TCP connect, proxy `CONNECT`, TLS handshake,
  and HTTP/2 session setup.
- `request_timeout` is the whole exchange deadline.
- `response_header_timeout` bounds the wait for response headers.
- `read_idle_timeout` bounds inactivity between inbound read progress events.
- `write_idle_timeout` bounds inactivity between outbound write progress
  events.
- `expect_continue_timeout` controls HTTP/1 `100-continue` upload waits.

Timeout failures are reported as `HTTP.HTTPTimeoutError`, an alias for
`HTTP.TimeoutError`.

## TLS, Sockets, and Proxies

The old `sslconfig` and `socket_type_tls` extension points are retained for
backwards compatibility only; they are no longer functional extension points
for the 2.0 transport architecture. Configure TLS and socket behavior through
the Reseau-backed `Transport` layer.

Before:

```julia
resp = HTTP.get(url; sslconfig = sslconfig)
```

After:

```julia
transport = HTTP.Transport(tls_config = tls_config)
client = HTTP.Client(transport = transport)
resp = HTTP.get(url; client = client)
```

Proxy configuration is more flexible and can be more explicit. As before, it can
come from the environment, but callers can also pass a direct/no-proxy policy or
a fixed proxy URL per request, client, or transport:

```julia
direct = HTTP.ProxyConfig()
from_env = HTTP.ProxyFromEnvironment()
fixed = HTTP.ProxyURL("http://proxy.internal:8080"; no_proxy = "localhost,127.0.0.1")

HTTP.get(url; proxy = from_env)
HTTP.get("http://127.0.0.1:8080"; proxy = direct)
```

## Servers

Request/response servers still use `HTTP.serve!`:

Before:

```julia
HTTP.serve!("127.0.0.1", 8080) do req
    return HTTP.Response(200, "ok")
end
```

After:

```julia
HTTP.serve!("127.0.0.1", 8080) do req
    return HTTP.Response(200; body = "ok")
end
```

Use `HTTP.listen!` for stream handlers:

```julia
server = HTTP.listen!("127.0.0.1", 8080) do stream
    req = HTTP.startread(stream)
    HTTP.setstatus(stream, 200)
    HTTP.setheader(stream, "Content-Type", "text/plain")
    write(stream, "streamed response for $(req.target)")
    closewrite(stream)
    HTTP.closeread(stream)
end
```

Every server timeout has a seconds-valued keyword and a nanosecond-valued
`_ns` keyword. The old server `readtimeout` keyword is accepted as a
seconds-valued migration alias for `read_timeout`.

```julia
server = HTTP.serve!(
    handler,
    "127.0.0.1",
    8080;
    read_timeout_ns = 30_000_000_000,
    read_header_timeout_ns = 5_000_000_000,
    write_timeout_ns = 30_000_000_000,
    idle_timeout_ns = 120_000_000_000,
)

server = HTTP.serve!(
    handler,
    "127.0.0.1",
    8080;
    read_timeout = 30,
    read_header_timeout = 5,
    write_timeout = 30,
    idle_timeout = 120,
)
```

Useful server helpers in 2.0 include:

- `HTTP.fileserver(root)` builds a ready-to-use static-file handler rooted at
  `root`. It serves ordinary files, normalizes directory redirects, can serve a
  configured SPA fallback, and uses the same conditional/range-aware response
  helpers as the lower-level APIs.
- `HTTP.servefile(request, path)` serves one filesystem path for a request,
  including `If-Modified-Since`, `If-None-Match`, `Range`, content type,
  `Last-Modified`, `ETag`, and `Accept-Ranges` handling.
- `HTTP.servecontent(request, source)` applies the same conditional and range
  response logic to bytes, strings, or seekable `IO` content you already own.
- `HTTP.Router` for route matching.
- `HTTP.forceclose(server)` for immediate shutdown.

## Routing and Middleware

`HTTP.Router` and `HTTP.register!` are the top-level public router names; the
underlying implementation lives in `HTTP.Handlers` and remains available as
`HTTP.Handlers.Router` / `HTTP.Handlers.register!` if you prefer the explicit
path.

```julia
router = HTTP.Router()

HTTP.register!(router, "GET", "/users/{id}") do req
    id = HTTP.getparam(req, "id")
    return HTTP.Response(200; body = id)
end

server = HTTP.serve!(router, "127.0.0.1", 8080)
```

When a route matches, the route string and path parameters are stored in the
request context. Retrieve them with `HTTP.getroute`, `HTTP.getparams`, or
`HTTP.getparam`.

## WebSockets

Use `HTTP.WebSockets` for WebSocket-specific client and server behavior.
Top-level `HTTP.open` is for ordinary HTTP request/response streaming, not
`ws://` or `wss://` URLs.

Before:

```julia
# Any code relying on top-level HTTP.open or internal upgrade helpers for
# WebSocket traffic should move to HTTP.WebSockets.
```

After:

```julia
HTTP.WebSockets.open("ws://127.0.0.1:8080/socket") do ws
    HTTP.WebSockets.send(ws, "ping")
    msg = HTTP.WebSockets.receive(ws)
end
```

Server side:

```julia
server = HTTP.WebSockets.listen!("127.0.0.1", 8080) do ws
    for msg in ws
        HTTP.WebSockets.send(ws, msg)
    end
end
```

To mix ordinary HTTP routes and WebSocket routes on a single server, upgrade an
in-flight server stream by hand with `HTTP.WebSockets.upgrade`, the 2.0
counterpart to the 1.x `WebSockets.upgrade(http)` helper. Guard the call with
`HTTP.WebSockets.isupgrade` and upgrade before writing any response:

```julia
server = HTTP.listen!("127.0.0.1", 8080) do stream
    if HTTP.WebSockets.isupgrade(stream.message)
        HTTP.WebSockets.upgrade(stream) do ws
            for msg in ws
                HTTP.WebSockets.send(ws, msg)
            end
        end
    else
        HTTP.setstatus(stream, 200)
        HTTP.startwrite(stream)
        write(stream, "ok")
    end
end
```

`upgrade` runs its handler synchronously and closes the connection when the
handler returns. It accepts the same `subprotocols`, `check_origin`,
`maxframesize`, and `maxfragmentation` keywords as `listen!`. WebSocket upgrades
over HTTP/2 are not supported.

The WebSocket client accepts the handshake timeout controls
`connect_timeout`, `request_timeout`, `response_header_timeout`,
`read_idle_timeout`, and `write_idle_timeout`.

## Server-Sent Events

Client-side SSE uses the `sse_callback` keyword on `HTTP.request`:

```julia
events = HTTP.SSEEvent[]

HTTP.request("GET", url; sse_callback = event -> push!(events, event))
```

Server-side SSE uses `HTTP.sse_stream`:

```julia
HTTP.serve!("127.0.0.1", 8080) do req
    return HTTP.sse_stream(200) do stream
        write(stream, HTTP.SSEEvent("ready"; event = "status", id = "1"))
    end
end
```

## Internal APIs

These 1.x internals are not migration targets for 2.0:

- layer-stack internals
- connection-pool internals
- parser internals
- undocumented socket/TLS extension points

Move those call sites to documented `Client`, `Transport`, `Stream`, server,
router, WebSocket, or SSE APIs. If a 1.x internal use case cannot be expressed
through the 2.0 public surface, open an issue with the use case rather than
depending on the new internals.

## Compatibility Keywords

HTTP.jl 2.0 accepts several old client keywords so existing code fails less
abruptly:

- `readtimeout`: maps to `read_idle_timeout`
- `pool`: accepted, but use `client` / `transport`
- `retry_delays` and `retry_check`: accepted, but use `retry_if`,
  `retries`, and `retry_bucket`
- `sslconfig` and `socket_type_tls`: accepted, but configure the transport
- `copyheaders`, `canonicalize_headers`, `detect_content_type`,
  `observelayers`, `logerrors`, and `logtag`: accepted for compatibility, but
  not the preferred 2.0 observation/configuration surface

Treat these as temporary migration aids. New code should use the documented
2.0 API names.

## Final Checklist

- Prefer `resp.status`; `resp.status_code` remains available as a compatibility alias.
- Use `HTTP.get_request_context(req)` for cancellation/deadline state.
- Prefer keyword constructors for `Request` and `Response`.
- Replace `pool` usage with a long-lived `HTTP.Client`.
- Replace `readtimeout` with the precise timeout keyword you need.
- Replace `HTTP.download` with `Downloads.download` or an explicit
  `HTTP.request(...; response_stream = io)` file stream.
- Move WebSocket code to `HTTP.WebSockets`.
- Replace internal parser/connection/HPACK/HTTP2 usage with documented APIs.
- Run integration tests for redirects, retries, proxy configuration, cookies,
  streaming, WebSockets, SSE, and HTTP/2 after upgrading.
