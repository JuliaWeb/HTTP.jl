"""
    HTTP

Client, server, streaming, WebSocket, and Server-Sent Events APIs for HTTP.jl.

The 2.0 API is built around explicit `Request`, `Response`, `Headers`,
`RequestContext`, body, `Client`, `Transport`, `Server`, and `Stream` values.
HTTP.jl owns HTTP message semantics and high-level client/server behavior,
while `Reseau` provides the transport, resolver, and TLS substrate.

Common entrypoints:

- `request`, `get`, `post`, `put`, `patch`, `delete`, `head`, and `options`
  for high-level client requests.
- `open` for client-side request/response streaming.
- `serve!` / `serve` for `Request -> Response` servers.
- `listen!` / `listen` and `streamhandler` for stream-oriented servers.
- `WebSockets` for WebSocket client and server helpers.
- `SSEEvent` and `sse_stream` for Server-Sent Events.

See the migration guide for the most important 1.x to 2.0 API changes.
"""
module HTTP

using URIs

const VERSION = v"2.0.0"

export WebSockets
export escape

Base.@deprecate escape escapeuri

include("http_core.jl")
include("http_client_timeouts.jl")
include("http1.jl")
include("hpack.jl")
include("http2.jl")
include("http2_client.jl")
include("http_sniff.jl")
include("http_forms.jl")
include("http_cookies.jl")
include("http_proxy.jl")
include("http_request_bodies.jl")
include("http_display.jl")
include("http_retry.jl")
include("http_client_url.jl")
include("http_client_redirect.jl")
include("http_transport.jl")
include("http_client.jl")
include("http_client_retry.jl")
include("http_server.jl")
include("http_stream.jl")
include("http_handlers.jl")
using .Handlers
include("http_sse.jl")
include("http_websockets.jl")

if ccall(:jl_generating_output, Cint, ()) == 1
    include("precompile.jl")
end

end
