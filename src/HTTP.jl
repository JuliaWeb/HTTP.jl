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
include("http_server_files.jl")
include("http_server_streams.jl")
include("http2_server.jl")
include("http_stream.jl")
include("http_handlers.jl")
using .Handlers
include("http_sse.jl")
include("http_websockets.jl")

# Declare the documented, non-exported public API via Julia's `public` mechanism
# (Julia 1.11+), so tooling and downstream code can distinguish supported entry
# points (accessed as `HTTP.name`) from internals. Already-exported names
# (e.g. `WebSockets`, `escape`, `Form`) are public by virtue of `export` and are
# not repeated here. The version guard keeps the source parseable on Julia 1.10
# (the `public` keyword does not exist there); `eval(Expr(:public, …))` is valid
# syntax on all versions, so only the evaluation is gated.
@static if Base.VERSION >= v"1.11.0-DEV.469"
    Core.eval(@__MODULE__, Expr(:public,
        Symbol("@client"),
        :AbstractBody, :AddressInUseError, :CallbackBody, :CanceledError, :Client,
        :ConnectError, :DNSError, :DoneEvent, :HTTP2Settings, :HTTPError, :HTTPTimeoutError,
        :Handlers, :Headers, :NoProxy, :ParseError, :ProtocolError, :ProxyConfig,
        :ProxyFromEnvironment, :ProxyURL, :RedirectEvent, :Request, :RequestContext,
        :RequestEvent, :RequestRetryError, :Response, :ResponseHeadEvent, :RetryBucket,
        :RetryEvent, :SSEEvent, :SSEStream, :Server, :StatusError, :Stream, :TLSHandshakeError,
        :TimeoutError, :TooManyRedirectsError, :Transport, :addtrailer, :appendheader,
        :body_close!, :body_closed, :body_read!, :cancel!, :canceled, :canonical_header_key,
        :close_idle_connections!, :defaultheader!, :delete, :do!, :expired, :fileserver,
        :forceclose, :get, :get!, :get_request_context, :hasheader, :head, :header,
        :headercontains, :headers, :idle_connection_count, :isaborted, :isrecoverable,
        :listen, :listen!, :mkheaders, :nobody, :open, :options, :patch, :port, :post, :put,
        :read_request, :removeheader, :request, :retry_attempts, :roundtrip!, :serve, :serve!,
        :servecontent, :servefile, :set_deadline!, :setheader, :setstatus, :sse_stream,
        :startwrite, :streamhandler, :trailers, :write_request!, :write_response!,
    ))
end

if ccall(:jl_generating_output, Cint, ()) == 1
    include("precompile.jl")
end

end
