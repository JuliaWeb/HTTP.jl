# Migration from HTTP.jl 1.x

If you stayed on top-level request helpers like `HTTP.get`, `HTTP.post`,
`HTTP.request`, and basic `HTTP.serve!` handlers, parts of your code can remain
structurally similar. If you depended on 1.x internals, this is a real major
version migration and you should plan to move onto the documented 2.0 surface.

## What Changed Most

## 1. The internals are substantially different

HTTP 2.0 keeps the familiar high-level request/server workflows, but the
internals and implementation structure are significantly different from 1.x.

Practical consequences:

- transport and TLS behavior now follow the `Reseau` substrate
- internals are organized around explicit request, response, body, transport, and protocol types
- undocumented 1.x internals are poor migration targets

## 2. Runtime expectations moved forward

The package manifest currently targets Julia `1.10` and later. Treat the 2.0
line as a major-version upgrade, not a drop-in minor release.

Practical consequences:

- verify Julia/runtime compatibility before switching production workloads
- re-test environments that depended on older 1.x compatibility assumptions

## 3. Public types are the migration path

If you previously reached into parser, connection, server, or client internals,
plan to move onto these stable 2.0 surfaces instead:

- `Request`, `Response`, `Headers`
- `Client`, `Transport`, `RetryBucket`
- `serve!`, `listen!`, `listen`, `streamhandler`
- `WebSockets`
- `ProxyConfig`, `NoProxy`, `ProxyFromEnvironment`

## What Still Feels Familiar

- top-level verbs: `get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `request`
- streaming via `open`
- basic server setup with `serve!`
- top-level cookies, forms, multipart, and WebSocket helpers

## What You Probably Need To Rewrite

## 1. Code that assumed streamed response bodies

Top-level request helpers buffer `resp.body` into a `Vector{UInt8}` by default:

```julia
resp = HTTP.get(url)
bytes = resp.body
text = String(resp.body)
```

Continue using `response_stream` when you want to stream a response directly
into an `IO` or preallocated byte buffer, and prefer `HTTP.open` when you want
direct stream ownership.

## 2. Code that depended on undocumented connection internals

Move to:

- `Client`
- `Transport`
- `RetryBucket`
- explicit retry and proxy configuration

## 3. Code that reached into parser or framing internals

Move onto the documented client, server, streaming, and WebSocket APIs instead
of targeting parser, connection-pool, HPACK, or HTTP/2 wire internals directly.

## 4. WebSocket code that used ad hoc helpers

Move to `HTTP.WebSockets.open`, `listen!`, `send`, and `receive`.

## 5. Client timeout behavior is richer than 1.x

If you used `HTTP#master`/1.x timeout keywords, this is one of the biggest
behavioral changes to account for.

In 1.x, most callers mainly had:

- `connect_timeout`
- `readtimeout`

In 2.0, the client surface is more explicit and more capable:

- `connect_timeout` covers the whole connection-establishment phase
  including DNS, TCP connect, proxy `CONNECT`, TLS handshake, and HTTP/2
  session setup
- `request_timeout` is a true overall exchange deadline
- `response_header_timeout` separately bounds header waits
- `read_idle_timeout` and `write_idle_timeout` bound inactivity between
  individual read/write progress events
- `expect_continue_timeout` gives explicit control over HTTP/1
  `100-continue` upload waits
- `HTTP.WebSockets.open` now participates in the same handshake timeout model

Compatibility note:

- `readtimeout` is still accepted in 2.0, but it is deprecated and now maps to
  `read_idle_timeout`

This means some old 1.x call sites can migrate mechanically, but the preferred
2.0 migration is usually to replace `readtimeout = ...` with the more precise
timeout that actually matches your operational intent.

## Suggested Migration Order

1. Upgrade simple top-level request call sites first.
2. Migrate server handlers onto `Request`/`Response` and `serve!`/`streamhandler`.
3. Replace internal parser/connection usage with documented client/server APIs.
4. Re-test proxy, retry, WebSocket, and HTTP/2 behavior explicitly if your application depends on them.
