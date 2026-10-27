"""
    HTTP

An HTTP client and server library for HTTP/1.1 and HTTP/2, with an opt-in
HTTP/3 client, WebSockets, and server-sent events. Reseau provides the TCP,
DNS, TLS, and QUIC layers.

- `request`, and `get`, `post`, `put`, `patch`, `delete`, `head`, `options`,
  and `query`, send a request and return the response.
- `open` streams a request and its response.
- `serve!` and `serve` run a server whose handler maps a `Request` to a
  `Response`.
- `listen!` and `listen` run a server whose handler reads and writes a
  `Stream`.
- `WebSockets` has the WebSocket client and server.
- `SSEEvent` and `sse_stream` send server-sent events.
"""
module HTTP

using URIs

# `VERSION` is read from Project.toml during precompilation, so the precompiled image has to
# be rebuilt when that file changes, not only when a source file does.
@static if Base.VERSION >= v"1.11"
    include_dependency(joinpath(dirname(@__DIR__), "Project.toml"); track_content=true)
else
    include_dependency(joinpath(dirname(@__DIR__), "Project.toml"))
end
const VERSION = pkgversion(@__MODULE__)

macro _spawn_interactive(ex)
    return esc(:(Threads.@spawn :interactive $ex))
end

export WebSockets
export escape

Base.@deprecate escape escapeuri

include("http_core.jl")
include("http_client_timeouts.jl")
include("http1.jl")
include("hpack.jl")
include("qpack.jl")
include("http3.jl")
include("http2.jl")
include("http2_client.jl")
include("http3_client.jl")
include("http_alt_svc.jl")
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

# Public names that are not exported (exported names are already public).
# `public` is not syntax on Julia 1.10, so build the expression and evaluate it
# on 1.11 and later.
@static if Base.VERSION >= v"1.11.0-DEV.469"
    Core.eval(@__MODULE__, Expr(:public,
        Symbol("@client"),
        :AbstractBody, :AddressInUseError, :CallbackBody, :CanceledError, :Client,
        :ConnectError, :DNSError, :DoneEvent, :HTTP2Settings, :HTTPError, :HTTPTimeoutError,
        :Handlers, :Headers, :NoProxy, :ParseError, :ProtocolError, :ProxyConfig,
        :ProxyFromEnvironment, :ProxyURL, :RedirectEvent, :Request, :RequestContext,
        :RequestEvent, :RequestRetryError, :Response, :ResponseHeadEvent, :RetryBucket,
        :RetryEvent, :RetrySkippedEvent, :SSEEvent, :SSEStream, :Server, :StatusError, :Stream,
        :TLSHandshakeError, :TLSTransportError,
        :TimeoutError, :TooManyRedirectsError, :Transport, :addtrailer, :appendheader, :appendheader!,
        :body_close!, :body_closed, :body_read!, :cancel!, :canceled, :canonical_header_key,
        :close_idle_connections!, :defaultheader!, :delete, :do!, :expired, :fileserver,
        :forceclose, :get, :get!, :get_request_context, :hasheader, :head, :header,
        :headercontains, :headers, :idle_connection_count, :isaborted, :isrecoverable,
        :listen, :listen!, :mkheaders, :nobody, :open, :options, :patch, :peeraddr, :port, :post,
        :put, :query, :read_request, :removeheader, :removeheader!, :request, :retry_attempts, :roundtrip!,
        :serve, :serve!, :servecontent, :servefile, :set_deadline!, :setheader, :setheader!, :setstatus,
        :sse_stream, :startwrite, :streamhandler, :trailers, :write_request!, :write_response!,
    ))
end

# Deprecated `HTTP.Exceptions` module, so code written for HTTP.jl 1.x
# (`HTTP.Exceptions.StatusError` and so on) keeps working (#1314).
module Exceptions
    import ..HTTP
    Base.@deprecate_binding HTTPError    HTTP.HTTPError    false
    Base.@deprecate_binding StatusError  HTTP.StatusError  false
    Base.@deprecate_binding ConnectError HTTP.ConnectError false
    Base.@deprecate_binding TimeoutError HTTP.TimeoutError false
end

if ccall(:jl_generating_output, Cint, ()) == 1
    include("precompile.jl")
end

end
