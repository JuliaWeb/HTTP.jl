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
- `Client`, `Transport`, `ClientTrace`
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

If you previously used `response_stream`, the preferred 2.0 spelling is
`response_body`, and `HTTP.open` is usually the better fit when you want direct
stream ownership.

## 2. Code that depended on undocumented connection internals

Move to:

- `Client`
- `Transport`
- `ClientTrace`
- explicit retry and proxy configuration

## 3. Code that reached into parser or framing internals

Move onto the documented client, server, streaming, and WebSocket APIs instead
of targeting parser, connection-pool, HPACK, or HTTP/2 wire internals directly.

## 4. WebSocket code that used ad hoc helpers

Move to `HTTP.WebSockets.open`, `listen!`, `send`, and `receive`.

## Suggested Migration Order

1. Upgrade simple top-level request call sites first.
2. Migrate server handlers onto `Request`/`Response` and `serve!`/`streamhandler`.
3. Replace internal parser/connection usage with documented client/server APIs.
4. Re-test proxy, retry, WebSocket, and HTTP/2 behavior explicitly if your application depends on them.
