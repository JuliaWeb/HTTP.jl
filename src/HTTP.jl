"""
    HTTP

HTTP protocol layer built on top of `Reseau` transport, resolver, and TLS
primitives.

The source tree is organized by responsibility:
- `http_core.jl` defines protocol-neutral request, response, header, body,
  and cancellation types shared by client and server code.
- `http1.jl` implements HTTP/1.1 parsing and serialization.
- `hpack.jl` and `http2.jl` implement the internal HPACK and HTTP/2
  wire layers used by higher-level code.
- `http2_client.jl`, `http_client_url.jl`,
  `http_client_redirect.jl`, `http_transport.jl`,
  `http_client.jl`, `http_client_retry.jl`, `http_stream.jl`,
  `http_sse.jl`, `http_server.jl`, and `http_handlers.jl`
  build higher-level client/server behavior on top.
"""
module HTTP

using URIs

const VERSION = v"2.0.0"

include("http_core.jl")
include("http_client_timeouts.jl")
include("http1.jl")
include("hpack.jl")
include("http2.jl")
include("http_client_verbose.jl")
include("http2_client.jl")
include("http_sniff.jl")
include("http_forms.jl")
include("http_cookies.jl")
include("http_proxy.jl")
include("http_request_bodies.jl")
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
include("http_websocket_codec.jl")
include("http_websockets.jl")

if ccall(:jl_generating_output, Cint, ()) == 1
    include("precompile.jl")
end

end
