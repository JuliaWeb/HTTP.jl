# Migration From HTTP.jl 1.x

HTTP.jl 2.0 is a breaking release with a new HTTP stack underneath. Code that
calls `HTTP.get`, `HTTP.post`, `HTTP.request`, `HTTP.serve!`, `HTTP.Router`, and
`HTTP.WebSockets` usually needs only small changes. Code that used parser,
connection-pool, layer-stack, or other internal APIs has to move to the public
API. HTTP.jl 2.0 requires Julia 1.10 or later.

The snippets below assume `using HTTP` and an existing `url`.

## Checklist

- Read data written with `response_stream = io` from `io`; `resp.body` is
  `nothing`.
- Replace `HTTP.download` with `Downloads.download` or a `response_stream`
  file.
- Read text from a server request with `String(req.body)`.
- Use `HTTP.get_request_context(req)` for cancellation and deadlines.
- Replace `pool` with a long-lived `HTTP.Client`.
- Replace `retry_delays` and `retry_check` with `retries`, `retry_if`, and
  `HTTP.RetryBucket`.
- Replace `readtimeout` with the timeout keyword you need.
- Replace `sslconfig` with a `Transport`'s `tls_config`.
- Replace `HTTP.Exceptions.StatusError` and friends with the top-level names,
  and `HTTP.RequestError` with the underlying exception.
- Replace `Sockets.getpeername(stream)` with `HTTP.peeraddr(stream)`.
- Start servers with an interactive thread, such as `julia --threads=4,1`.
- Re-test redirects, retries, proxies, cookies, streaming, WebSockets,
  server-sent events, and HTTP/2.

## Response Bodies

`HTTP.request` and the verb helpers still return the whole body as a
`Vector{UInt8}` in `resp.body`. With `response_stream = io`, 1.x also stored
`io` in `resp.body`. In 2.0 `resp.body` is `nothing`; read the data from the
`io` you passed:

```julia
open("payload.bin", "w") do io
    resp = HTTP.get(url; response_stream = io)
    @assert resp.body === nothing
end
```

## `HTTP.download`

HTTP.jl 2.0 has no `download` function. `HTTP.download(url, path)` still runs,
because every module can see `Base.download`, but it calls `Base.download`,
which uses the Downloads standard library. It accepts none of HTTP.jl's
keywords; passing one throws a `MethodError`.

Use `Downloads.download` to copy a URL to a file:

```julia
using Downloads

Downloads.download(url, "payload.bin")
```

Stream the response into a file when you need HTTP.jl options such as headers,
retries, proxies, or a `Client`:

```julia
open("payload.bin", "w") do io
    HTTP.get(url; response_stream = io)
end
```

## Requests, Responses, and Headers

The 1.x positional constructors still work:

```julia
req = HTTP.Request("POST", "/widgets", ["Content-Type" => "text/plain"], "hello")
resp = HTTP.Response(201, ["Location" => "/widgets/1"], "created")
```

The keyword forms take the same values plus trailers, protocol version, and a
context:

```julia
req = HTTP.Request("POST", "/widgets"; headers = ["Content-Type" => "text/plain"], body = "hello")
```

`req.headers` and `resp.headers` are `HTTP.Headers`, an ordered vector of
`String => String` pairs; in 1.x they were a `Vector` of `SubString` pairs.
Header names keep the spelling you give them, and lookups such as
`HTTP.header(resp, "content-type")` ignore case. Headers received from the
network use `Content-Type` spelling, while 1.x kept the spelling from the wire.
Pass `canonicalize_headers = true` to send every request header name in that
form, as in 1.x. HTTP/2, which 2.0 uses for HTTPS when the server supports it,
always sends names in lowercase; pass `protocol = :h1` to a server that needs
exact spelling. Places that take headers still accept vectors of pairs.

## Request Context

`req.context` is still a `Dict{Symbol,Any}` for application data:

```julia
req.context[:request_id] = request_id
request_id = get(req.context, :request_id, nothing)
```

Cancellation and deadlines live on the [`HTTP.RequestContext`](@ref) returned by
`HTTP.get_request_context(req)`:

```julia
ctx = HTTP.get_request_context(req)
HTTP.set_deadline!(ctx, time_ns() + 5_000_000_000)
HTTP.canceled(ctx) && throw(HTTP.CanceledError("request canceled"))
```

## Clients, Proxies, and TLS

The `pool` keyword is ignored. Create a long-lived [`HTTP.Client`](@ref)
instead; it keeps connections, cookies, and settings across requests:

```julia
client = HTTP.Client(transport = HTTP.Transport(max_idle_per_host = 4))
try
    resp = HTTP.get(url; client = client)
finally
    close(client)
end
```

As in 1.x, requests without a `client` use proxies from the `HTTP_PROXY`,
`HTTPS_PROXY`, `ALL_PROXY`, and `NO_PROXY` environment variables. 2.0 reads them
once, when the first such request runs, instead of on every request. The
`proxy` keyword accepts a proxy URL or an [`HTTP.ProxyConfig`](@ref), and
`socks5://` and `socks5h://` proxies are supported:

```julia
HTTP.get(url; proxy = HTTP.ProxyURL("http://proxy.internal:8080"; no_proxy = "localhost"))
HTTP.get(url; proxy = HTTP.ProxyURL("socks5h://proxy.internal:1080"))
HTTP.get(url; proxy = nothing)  # connect directly
```

The `sslconfig` and `socket_type_tls` keywords are ignored. Configure TLS with a
`Reseau.TLS.Config` on the `Transport`:

```julia
using Reseau

client = HTTP.Client(transport = HTTP.Transport(tls_config = Reseau.TLS.Config(ca_file = "ca.pem")))
```

`require_ssl_verification = false` still turns off certificate checks for one
call.

HTTP.jl 2 does not read the `JULIA_SSL_NO_VERIFY_HOSTS` and
`JULIA_NO_VERIFY_HOSTS` environment variables: hosts listed there are verified
like any other. Pass `require_ssl_verification = false`, or give their client a
`Transport` with `Reseau.TLS.Config(verify_peer = false)`.

## Retries

The `retry_delays` and `retry_check` keywords are ignored. A `retry_if`
function replaces `retry_check`. Return `true` to retry and `nothing` to fall
back to the default rules:

Before:

```julia
resp = HTTP.get(url; retries = 3, retry_delays = [0.1, 0.5, 1.0],
    retry_check = (s, ex, req, resp, resp_body) -> resp !== nothing && resp.status == 409)
```

After:

```julia
resp = HTTP.get(url; retries = 3, retry_if = (attempt, err, req, resp) ->
    resp !== nothing && resp.status == 409 ? true : nothing)
```

There is no list of delays. Retries wait a random, exponentially growing delay;
pass `retry_bucket = HTTP.RetryBucket(backoff_scale_factor_ms = 100)` to change
its scale. 2.0 retries 408, 429, 500, 502, 503, and 504 responses by default,
where 1.x also retried 403, 409, and every other 5xx status. See
[Retries](client.md#Retries) in the client guide for the full default policy.

## Timeouts

`readtimeout` still works but is deprecated. It sets `read_idle_timeout`, the
longest wait between reads. Pick the timeout you mean:

```julia
resp = HTTP.get(url; connect_timeout = 5, request_timeout = 60, read_idle_timeout = 30)
```

[Timeouts](client.md#Timeouts) in the client guide describes each keyword.
A timeout throws `HTTP.TimeoutError`, also available as `HTTP.HTTPTimeoutError`.

## Exceptions

The exception types live at the top level: `HTTP.StatusError`,
`HTTP.ConnectError`, `HTTP.TimeoutError`, and their supertype `HTTP.HTTPError`.
The 1.x names `HTTP.Exceptions.StatusError`, `ConnectError`, `TimeoutError`, and
`HTTPError` still resolve to them, with a deprecation warning under
`--depwarn=yes`. `@try` and `current_exceptions_to_string` are gone.

`HTTP.RequestError` is gone. Failures throw the underlying exception instead,
and [`HTTP.isrecoverable`](@ref) tells you whether a failure is worth retrying:

```julia
try
    HTTP.get(url)
catch e
    HTTP.isrecoverable(e) || rethrow()
    # a transient network failure; retry later
end
```

## `HTTP.@client`

`HTTP.@client` accepts one middleware or a tuple of them in each position. The
first middleware in a tuple is the outermost:

```julia
HTTP.@client request_middleware
HTTP.@client request_middleware stream_middleware
HTTP.@client (outer_request, inner_request) (outer_stream, inner_stream)
```

Request middleware wraps `request` and the verb helpers. Stream middleware wraps
`open`.

## Servers

`HTTP.serve!`, `HTTP.serve`, `HTTP.listen!`, `HTTP.listen`, and `HTTP.Router`
keep their 1.x shapes. Some details changed:

- Server tasks run on Julia's `:interactive` thread pool. Start Julia with at
  least one interactive thread; see the [server guide](server.md).
- In a `serve!` handler, `req.body` is a body object rather than a
  `Vector{UInt8}`. Use `String(req.body)` to read it as text.
- `HTTP.peeraddr(stream)` replaces `Sockets.getpeername(stream)`. It returns
  the client address, or `nothing`; `string(addr)` gives `"ip:port"`.
- The server `readtimeout` keyword still works and sets `read_timeout`. Each
  server timeout has a seconds keyword (`read_timeout`) and a nanoseconds
  keyword (`read_timeout_ns`).

Before:

```julia
HTTP.listen("127.0.0.1", 8080) do stream
    ip, port = Sockets.getpeername(stream)
end
```

After:

```julia
HTTP.listen("127.0.0.1", 8080) do stream
    addr = HTTP.peeraddr(stream)
end
```

## WebSockets

The `HTTP.WebSockets` API keeps its 1.x shape: `open`, `listen!`, `listen`,
`upgrade`, `isupgrade`, `send`, `receive`, and iteration over a socket. Two
differences:

- `maxframesize` defaults to 16 MiB instead of no limit. Pass a larger value if
  your messages are bigger.
- `HTTP.WebSockets.upgrade` works only on HTTP/1.1 connections.

## Server-Sent Events

Clients still use the `sse_callback` keyword:

```julia
events = HTTP.SSEEvent[]
HTTP.request("GET", url; sse_callback = event -> push!(events, event))
```

Servers return the response that `HTTP.sse_stream` builds and write events in
its `do` block:

```julia
HTTP.serve!("127.0.0.1", 8080) do req
    return HTTP.sse_stream(200) do stream
        write(stream, HTTP.SSEEvent("ready"; event = "status", id = "1"))
    end
end
```

## Ignored 1.x Keywords

The client accepts these 1.x keywords so old calls do not fail, but they have no
effect and log a warning: `pool`, `retry_delays`, `retry_check`, `sslconfig`,
`socket_type_tls`, `detect_content_type`, `observelayers`, `logerrors`, and
`logtag`. `readtimeout` sets `read_idle_timeout`, and `canonicalize_headers`
keeps its 1.x meaning.

## Internal APIs

The 1.x layer stack, connection pool, parser, and socket/TLS extension points
have no 2.0 equivalent. Move that code to `Client`, `Transport`, `Stream`, the
server functions, `Router`, `HTTP.WebSockets`, or the SSE functions. If a use
case cannot be expressed with the public API, open an issue that describes it
instead of depending on 2.0 internals.
