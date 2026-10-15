```@meta
CurrentModule = HTTP
```

# Client Guide

`HTTP.request` and the verb helpers such as `HTTP.get` and `HTTP.post` send a
request and return an [`HTTP.Response`](@ref) with the whole body in memory.
`HTTP.open` streams the response instead. An [`HTTP.Client`](@ref) holds
connections and settings that you want to share across requests.

## Making Requests

```julia
using HTTP

server = HTTP.serve!("127.0.0.1", 0) do req
    return HTTP.Response(200; body = "$(req.method) $(req.target)")
end
url = "http://127.0.0.1:$(HTTP.port(server))"

resp = HTTP.request("GET", url * "/hello")
resp.status        # 200
String(resp.body)  # "GET /hello"

HTTP.forceclose(server)
```

`HTTP.get`, `HTTP.head`, `HTTP.post`, `HTTP.put`, `HTTP.patch`, `HTTP.delete`,
`HTTP.options`, and `HTTP.query` call `HTTP.request` with a fixed method and
accept the same keywords.

A response with status 300 or above throws an [`HTTP.StatusError`](@ref).
Redirect responses (301, 302, 303, 307, and 308) are the exception. Pass
`status_exception = false` to get the response instead.

The client follows up to 10 redirects. Set `redirect = false` or
`redirect_limit` to change that. A `Location` header is resolved against the
current URL as [RFC 3986](https://www.rfc-editor.org/rfc/rfc3986#section-5.2)
specifies: `.` and `..` segments are removed, while repeated slashes and
percent-encoded bytes are kept. The path of the URL you pass is sent as written,
and fragments are never sent.

## Request Bodies

Pass the body as the third positional argument or with the `body` keyword.
Strings and byte vectors are sent as they are. Files and `IOBuffer`s are read
into memory first. Other `IO` values, and iterables of strings or byte chunks,
are streamed with chunked transfer encoding.

HTTP.jl has no JSON dependency. Serialize the payload yourself, for example with
[JSON.jl](https://github.com/JuliaIO/JSON.jl), and set the `Content-Type`
header:

```julia
using HTTP, JSON

resp = HTTP.post(
    "https://api.example.com/users";
    headers = ["Content-Type" => "application/json"],
    body = JSON.json(Dict("name" => "alice", "age" => 30)),
)
user = JSON.parse(String(resp.body))
```

A `Dict` or `NamedTuple` body is sent as an HTML form
(`application/x-www-form-urlencoded`), and the `Content-Type` header is set for
you:

```julia
HTTP.post("https://example.com/login", [], Dict("user" => "alice", "pw" => "s3cret"))
```

Use [`HTTP.Form`](@ref) for `multipart/form-data`, such as file uploads. An open
file is sent with its file name:

```julia
open("upload.bin") do file
    HTTP.post("https://example.com/upload", [], HTTP.Form(Dict("file" => file, "kind" => "binary")))
end
```

### QUERY requests

[RFC 10008](https://www.rfc-editor.org/rfc/rfc10008) defines the `QUERY` method
for safe, idempotent requests that carry a body. `HTTP.query` sends one:

```julia
HTTP.query(
    "https://api.example.com/search";
    headers = ["Content-Type" => "application/json"],
    body = """{"select":["name","email"],"limit":10}""",
)
```

## Query Parameters

The `query` keyword URL-encodes a `Dict`, `NamedTuple`, or vector of pairs and
appends it to the URL's query string:

```julia
HTTP.get("https://example.com/search"; query = Dict("page" => 2, "limit" => 10))
# GET /search?limit=10&page=2
```

A `Dict` has no order. Use a vector of pairs to fix the order or to repeat a key:

```julia
HTTP.get("https://example.com/search"; query = ["tag" => "a", "tag" => "b"])
# GET /search?tag=a&tag=b
```

`query` adds to a query string that is already in the URL:

```julia
HTTP.get("https://example.com/search?type=user"; query = ["page" => 2])
# GET /search?type=user&page=2
```

## Reading the Response Body

`resp.body` is a `Vector{UInt8}`. Convert it to text with `String`:

```julia
resp = HTTP.get("https://example.com")
text = String(resp.body)
```

!!! warning "`String(resp.body)` empties `resp.body`"
    `String(::Vector{UInt8})` takes over the vector's memory instead of copying
    it, so `resp.body` is empty afterwards. Use `String(copy(resp.body))` if you
    need the bytes again.

## Streaming Responses

`HTTP.open` sends the request and lets you read the response body as it
arrives. It follows redirects and decompresses the body like `HTTP.request`.

```julia
resp = HTTP.open("GET", "https://example.com") do stream
    while !eof(stream)
        chunk = readavailable(stream)
        # process chunk
    end
end
```

The `do` block form returns the final `HTTP.Response`, not the value of the
block. Store anything you need from the block in a variable defined outside it.
Call `HTTP.startread(stream)` inside the block to see the status and headers
before you read the body.

To copy the body into an `IO` instead, pass it as `response_stream`. The
response's `body` is then `nothing`:

```julia
buf = IOBuffer()
resp = HTTP.get("https://example.com"; response_stream = buf)
text = String(take!(buf))
```

## Reusing a Client

Calls without a `client` keyword share one default client, so they already reuse
connections and share a cookie jar. Create your own [`HTTP.Client`](@ref) when a
set of requests needs its own connection pool, cookies, or settings:

```julia
client = HTTP.Client(
    transport = HTTP.Transport(max_idle_per_host = 4),
    cookiejar = HTTP.CookieJar(),
)
resp = HTTP.get(client, "https://example.com")  # same as HTTP.get(url; client = client)
close(client)
```

Every request function accepts the client as its first argument or as the
`client` keyword. A closed client throws `ArgumentError` when you use it;
`isopen(client)` tells you whether it is still open.

Settings are split between the two types:

- [`HTTP.Transport`](@ref) owns connections: pool sizes (`max_idle_per_host`,
  `max_idle_total`, `max_conns_per_host`), `idle_timeout_ns`, TLS settings
  (`tls_config`), the proxy (`proxy`), the retry budget (`retry_bucket`), the
  source address (`local_addr`), and the response header limits
  (`max_line_bytes` and `max_header_bytes`).
- [`HTTP.Client`](@ref) owns request policy: the transport, the cookie jar,
  redirects (`max_redirects`, `check_redirect`), HTTP/2 (`prefer_http2`,
  `http2_settings`), and per-request defaults.

A `Client` created without a `transport` reads its proxy from the
`HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and `NO_PROXY` environment variables.
A `Transport` you create yourself connects directly unless you pass `proxy`.
Proxy URLs may use `http://`, `socks5://`, or `socks5h://`.

### Per-client defaults

A client can carry defaults that apply to every request sent through it:

```julia
client = HTTP.Client(
    default_headers = ["User-Agent" => "MyApp/1.0", "X-API-Version" => "v2"],
    default_query = Dict("api_key" => "secret"),
    default_basicauth = "alice" => "password",
    connect_timeout = 5,
    request_timeout = 30,
)

HTTP.get(client, "https://api.example.com/users")

# Per-call values replace the defaults they overlap.
HTTP.get(client, "https://api.example.com/users"; headers = ["X-API-Version" => "v1"])
```

- `default_headers` are added unless the call sets the same header.
- `default_query` is merged with the call's `query`; keys in the call replace
  the default values for the same key.
- `default_basicauth` is used unless the call passes `basicauth` or an
  `Authorization` header.
- The timeouts (`connect_timeout`, `request_timeout`, `response_header_timeout`,
  `read_idle_timeout`, `write_idle_timeout`) apply when the call passes no value
  or `0`.

### Binding to a local address

`local_addr` sets the source IP address of a client's connections, which picks
the outgoing interface on a host with several. Pass an IP address string, or a
`Reseau.TCP.SocketAddrV4` or `SocketAddrV6` to also fix the source port:

```julia
client = HTTP.Client(local_addr = "192.0.2.10")
```

The address must belong to a local interface. Interface names such as `"en0"`
throw an `ArgumentError`. When you pass your own `transport`, set `local_addr` on
the `Transport` instead.

## Timeouts

Each timeout keyword bounds one part of a request. All values are in seconds.

- `connect_timeout` bounds DNS lookup, the TCP connect, the proxy `CONNECT` or
  SOCKS5 handshake, the TLS handshake, and HTTP/2 connection setup. It
  defaults to 30.
- `request_timeout` bounds the whole call.
- `response_header_timeout` bounds the wait for the response headers after the
  request is sent.
- `read_idle_timeout` bounds the time between reads, including the wait for the
  response headers.
- `write_idle_timeout` bounds the time between writes.
- `expect_continue_timeout` sets how long an HTTP/1 upload with an
  `Expect: 100-continue` header waits for `100 Continue` before it sends the
  body anyway.

`request_timeout`, `response_header_timeout`, `read_idle_timeout`, and
`write_idle_timeout` are off unless you set them. A timeout throws
[`HTTP.TimeoutError`](@ref).

```julia
resp = HTTP.get(
    "https://example.com";
    connect_timeout = 2,
    response_header_timeout = 5,
    read_idle_timeout = 30,
)
```

`HTTP.open` takes the same keywords. `HTTP.WebSockets.open` takes all of them
except `expect_continue_timeout`.

## Retries

By default a request is retried up to 4 times (`retries = 4`) when all of these
hold:

- the method is `GET`, `HEAD`, `OPTIONS`, `TRACE`, `QUERY`, `PUT`, or `DELETE`,
  or the request has an `Idempotency-Key` or `X-Idempotency-Key` header (pass
  `retry_non_idempotent = true` to retry other requests)
- the body can be sent again, which is true unless it is streamed from an `IO`
  or an iterable
- the attempt failed with a network error, such as a refused or reset
  connection, or the response status is 408, 429, 500, 502, 503, or 504

Retries wait a random, exponentially growing delay, or the delay that a 429 or
503 response asks for in its `Retry-After` header, up to 20 seconds. Pass
`retry = false` to turn retries off. Each `Transport` also has a [`HTTP.RetryBucket`](@ref) that limits
how many retries a burst of failures can trigger.

Pass `retry_if` to make your own decision:

```julia
function retry_if(attempt, err, req, resp)
    err !== nothing && return attempt <= 2      # failed before a response
    return resp.status in (429, 503) && attempt <= 3
end

HTTP.get("https://example.com"; retry_if = retry_if)
```

`retry_if(attempt, err, req, resp)` gets the one-based number of the attempt
that just finished. For a failure before any response, `err` is an
[`HTTP.RequestRetryError`](@ref) whose `err.err` field holds the underlying
exception, and `resp` is `nothing`. For a response, `err` is `nothing` and `resp`
is the response. Return `true` to retry, `false` to stop, or `nothing` to use the
default rules. A body that cannot be sent again is never retried.

## Cancellation and Deadlines

Pass an [`HTTP.RequestContext`](@ref) as `context` to control a request from
another task. `HTTP.cancel!(ctx)` aborts the request, which then throws
[`HTTP.CanceledError`](@ref):

```julia
ctx = HTTP.RequestContext()
task = Threads.@spawn HTTP.get("https://example.com/slow"; context = ctx)
HTTP.cancel!(ctx)
fetch(task)  # throws a TaskFailedException wrapping an HTTP.CanceledError
```

A context can also carry an absolute deadline, set with
`HTTP.RequestContext(deadline_ns = time_ns() + 5_000_000_000)` or
`HTTP.set_deadline!`. A request still running at the deadline throws
`HTTP.TimeoutError`. `HTTP.request`, the verb helpers, `HTTP.open`, and
`HTTP.do!` all accept `context`.

## Debugging Requests

`verbose = 1` prints a line for each attempt, response, retry, and redirect,
and one for the result. `verbose = 2` also prints the request and response
heads:

```julia
HTTP.get("http://127.0.0.1:8080/v"; verbose = 2)
```

```
[http] request attempt 1 GET http://127.0.0.1:8080/v via h1
[http] request
GET /v HTTP/1.1
Host: 127.0.0.1:8080
Accept-Encoding: gzip, deflate
User-Agent: HTTP.jl/2.0.0
[http] response attempt 1 200 for http://127.0.0.1:8080/v
[http] response
HTTP/1.1 200 OK
Content-Length: 6
[http] done 200 for http://127.0.0.1:8080/v
```

To collect the same information in code, pass a `trace` callback. It receives
these events: [`HTTP.RequestEvent`](@ref), [`HTTP.ResponseHeadEvent`](@ref),
[`HTTP.RetryEvent`](@ref), [`HTTP.RetrySkippedEvent`](@ref),
[`HTTP.RedirectEvent`](@ref), and [`HTTP.DoneEvent`](@ref).

## Avoiding Copies

A byte vector or contiguous byte view passed as the body is sent without being
copied, and retries send the same bytes again. Do not change the bytes until the
call returns.

Pass `copyheaders = false` with an `HTTP.Headers` collection to let
`HTTP.request` or `HTTP.open` use it without copying it first. Do not touch the
collection until the call returns, and do not share it between requests that run
at the same time; its contents afterwards are unspecified. Other header inputs
are always copied.

```julia
payload = read("upload.bin")
headers = HTTP.Headers(["Content-Type" => "application/octet-stream"])
resp = HTTP.put("https://example.com/upload", headers, payload; copyheaders = false)
```

A byte vector or writable byte view passed as `response_stream` receives the
body directly. It must be large enough for the whole body, or the call throws
`ArgumentError`. A `Vector{UInt8}` is resized to the body length. A failing
response leaves it untouched and returns the error body in `resp.body`, so a
`StatusError` still carries it.
