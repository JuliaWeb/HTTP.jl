```@meta
CurrentModule = HTTP
```

# Server Guide

`HTTP.serve!` calls your function with each [`HTTP.Request`](@ref) and sends
the [`HTTP.Response`](@ref) it returns. `HTTP.listen!` calls your function with
an [`HTTP.Stream`](@ref) instead, so it can read the request body and write the
response in pieces. Both return an [`HTTP.Server`](@ref) right away; `HTTP.serve`
and `HTTP.listen` take the same arguments and block until the server closes.

## Request Handlers

```julia
using HTTP

server = HTTP.serve!("127.0.0.1", 8080) do req
    return HTTP.Response(200; headers = ["Content-Type" => "text/plain"], body = "handled " * req.target)
end

resp = HTTP.get("http://127.0.0.1:8080/health")
String(resp.body)  # "handled /health"
HTTP.forceclose(server)
```

A handler that throws sends the client a `500 Internal Server Error`.

### Reading the request

`req.method` and `req.target` hold the request line, and `HTTP.header(req,
"Content-Type")` reads a header. `String(req.body)` returns the body as text.

`req.target` holds the path and the query string. Split them with `HTTP.URI`
and decode the query with `HTTP.queryparams`, which returns a `Dict`, or
`HTTP.queryparampairs`, which keeps the order and repeated keys. A form body
(`application/x-www-form-urlencoded`) uses the same encoding, so
`HTTP.queryparams` decodes it too:

```julia
HTTP.serve!("127.0.0.1", 8080) do req
    query = HTTP.queryparams(HTTP.URI(req.target).query)
    form = HTTP.queryparams(String(req.body))
    return HTTP.Response(200; body = "page $(get(query, "page", "1")), user $(get(form, "user", "?"))")
end
```

Use [`HTTP.parse_multipart_form`](@ref) for a `multipart/form-data` body.

`serve!` reads the whole request body into memory before it calls the handler.
`max_body_bytes` limits the size, 64 MiB by default; a larger body gets
`413 Content Too Large`. Pass `max_body_bytes = 0` for no limit, or use a
stream handler to read large bodies in pieces.

### Reusing responses

A `Response` with a `String` or `Vector{UInt8}` body is not used up when it is
sent, so a handler can return the same response object every time:

```julia
const HEALTH = HTTP.Response(200; headers = ["Content-Type" => "text/plain"], body = "ok")
handler(req) = HEALTH
```

A streamed body, such as an [`HTTP.CallbackBody`](@ref), can be sent only once.
Sending it again gives the client a `500 Internal Server Error`.

## Stream Handlers

A stream handler reads the request and writes the response itself:

```julia
server = HTTP.listen!("127.0.0.1", 8080) do stream
    req = HTTP.startread(stream)  # the request line and headers
    body = read(stream)           # the request body
    HTTP.setstatus(stream, 200)
    HTTP.setheader(stream, "Content-Type" => "text/plain")
    write(stream, "got $(length(body)) bytes for $(req.target)")
end
```

Set the status and headers before the first `write`. A response without a
`Content-Length` header is sent with chunked encoding, and
[`HTTP.addtrailer`](@ref) adds trailers to it. `HTTP.streamhandler(f)` turns a
request handler `f` into a stream handler.

### Fixed-length responses

A stream handler that sets `Content-Length` on an HTTP/1 response and writes
without calling `HTTP.startwrite` has its body held in memory until it
returns or calls `closewrite`. Until then nothing is sent, so if the handler
throws or writes the wrong number of bytes, the client gets an error response
instead.

To stream a large body, call `HTTP.startwrite` first. The server still holds
the first 4 KiB, so a small response goes out in one write with its head. Once
the body passes 4 KiB, the head and the held bytes are sent, and each later
`write` goes straight to the connection:

```julia
HTTP.listen!("127.0.0.1", 8080) do stream
    HTTP.setheader(stream, "Content-Length" => string(filesize(path)))
    HTTP.startwrite(stream)
    open(io -> write(stream, io), path)
end
```

Once the head is sent, a failure can only close the connection. Either way,
writing more than `Content-Length` bytes throws. `HTTP.streamhandler` streams
a response body this way when it is not already in memory, such as a
`fileserver` file.

## Interactive Thread Pool

HTTP.jl runs its server tasks, including your handlers, on Julia's
`:interactive` thread pool. That keeps the server answering requests, health
checks included, while compute-heavy tasks keep the `:default` pool busy.

Start a production server with at least one interactive thread. This command
starts four default threads and one interactive thread:

```sh
julia --threads=4,1 --project=. server.jl
```

`JULIA_NUM_THREADS=4,1` does the same. Without an interactive thread, Julia runs
these tasks on the default pool, where tasks that never yield can stall the
server.

Do not run long computations directly in a handler: they hold an interactive
thread. Run them on the default pool and wait for the result:

```julia
result = fetch(Threads.@spawn :default expensive_work())
```

## Server Lifecycle

Keep the `Server` that `serve!` or `listen!` returns:

- `HTTP.port(server)` returns the bound port, which is useful with port `0`.
- `wait(server)` blocks until the server stops accepting connections.
- `close(server)` stops accepting connections and waits for the requests in
  progress to finish.
- `HTTP.forceclose(server)` stops at once and closes every connection.

### Timeouts

All server timeouts are off by default. Each keyword takes seconds, and a
variant ending in `_ns`, such as `read_timeout_ns`, takes nanoseconds:

```julia
server = HTTP.serve!(
    handler,
    "127.0.0.1",
    8080;
    read_header_timeout = 5,
    read_timeout = 30,
    write_timeout = 30,
    idle_timeout = 120,
)
```

For HTTP/1 connections, `read_header_timeout` limits reading the request line
and headers. After the headers, `read_timeout` starts a fresh limit for reading
the body. Between requests on a kept-alive connection, `idle_timeout` applies
until the next request starts to arrive; the header limit starts then. When the
header or idle setting is `0`, it falls back to `read_timeout`.

When a header or body read times out, the server answers
`408 Request Timeout` and closes the connection. An idle timeout closes the
connection without a response.

### TLS

To serve HTTPS, pass `serve!` or `listen!` a TLS listener from Reseau. List
`"h2"` in `alpn_protocols` to offer HTTP/2 to clients:

```julia
using HTTP, Reseau

config = Reseau.TLS.Config(;
    cert_file = "cert.pem",
    key_file = "key.pem",
    alpn_protocols = ["h2", "http/1.1"],
)
server = HTTP.serve!(handler, Reseau.TLS.listen("tcp", "127.0.0.1:8443", config))
```

See the [Protocols guide](protocols.md) for HTTP/2 on plain connections.

## Routing and Middleware

[`HTTP.Router`](@ref HTTP.Handlers.Router) matches a request's method and path
against registered routes:

```julia
using HTTP

router = HTTP.Router()

HTTP.register!(router, "GET", "/users/{id}") do req
    id = HTTP.getparam(req, "id")
    return HTTP.Response(200; body = "user " * id)
end

server = HTTP.serve!(router, "127.0.0.1", 8080)
```

Read the matched route and its path variables with `HTTP.getroute`,
`HTTP.getparams`, and `HTTP.getparam`. A path that matches no route gets
`404 Not Found`, and a path that matches with another method gets
`405 Method Not Allowed`. Each path segment is percent-decoded before it is
matched, so `/%61dmin` takes the route `/admin`, and path variables hold
decoded text.

Middleware is a function that takes a handler and returns a new handler. The
third argument of `Router` wraps every route registered on it. This router
gives each handler 5 seconds:

```julia
timeout = HTTP.Handlers.handlertimeout(5.0; status = 503)
router = HTTP.Router(
    req -> HTTP.Response(404),
    req -> HTTP.Response(405),
    timeout,
)
```

### Request logging

`HTTP.Handlers.logging_middleware` wraps a handler and logs one record per
request through Julia's logging system:

```julia
using HTTP, Logging

server = HTTP.serve!(HTTP.Handlers.logging_middleware(router), "127.0.0.1", 8080)
```

With the default `ConsoleLogger`, each request prints a record like:

```
┌ Info: GET /users/42 200 0.412ms
│   method = "GET"
│   target = "/users/42"
│   status = 200
│   elapsed_ms = 0.412
└   length = 7
```

`length` is the response body length when it is known without reading the
body. A handler that throws is logged at `Logging.Error` with the exception,
which is then rethrown, so the client still gets an error response. Pass
`level` to log successful requests at another level, and `logger` to send the
records to a specific logger:

```julia
access_log = HTTP.Handlers.logging_middleware(router; level = Logging.Debug)
```

The middleware also wraps stream handlers; their records add the client's
`peer` address. Every record is in the `:access` log group, so it is easy to
filter or route with a package such as LoggingExtras.jl.

## Static Files

`HTTP.fileserver(root)` returns a request handler that serves the files under
the directory `root`:

```julia
using HTTP

handler = HTTP.fileserver("public"; spa_fallback = "index.html")
server = HTTP.serve!(handler, "127.0.0.1", 8080)
```

It serves `index.html` for a directory and redirects to the canonical path of a
file or directory. `spa_fallback` serves the given file for a missing path that
does not look like a file name, as a single-page app needs. It answers
`If-Modified-Since` and single `Range` requests, and also `If-None-Match` when
you pass `etag`.

A path with a `..` segment, an encoded slash (`%2F`), or a backslash gets
`400 Bad Request`. Routes are case-sensitive, but the default file systems on
macOS and Windows are not, so there `/ADMIN/x` serves `admin/x` even when a
route guards `/admin/**`; check access in the handler when that matters.

[`HTTP.servefile`](@ref) serves one file for a request, and
[`HTTP.servecontent`](@ref) serves bytes or a seekable `IO` that you already
have, with the same conditional and range handling. For a string, pass
`codeunits(str)`.

## Server-Sent Events

`HTTP.sse_stream` builds a `text/event-stream` response. Write
[`HTTP.SSEEvent`](@ref) values in its `do` block, which runs on its own task;
the stream ends when the block returns:

```julia
using HTTP

server = HTTP.serve!("127.0.0.1", 8080) do req
    return HTTP.sse_stream(200) do stream
        write(stream, HTTP.SSEEvent("ready"; event = "status", id = "1"))
    end
end
```

A client reads the events with the `sse_callback` keyword of `HTTP.request`.

## HTTP/2

`serve!` and `listen!` speak HTTP/2 to clients that ask for it, through TLS
(see [TLS](#TLS)) or cleartext prior knowledge. The [Protocols
guide](protocols.md#HTTP/2) covers the details and the `http2_settings`
keyword.
