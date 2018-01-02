__precompile__()
module HTTP

using MbedTLS
import MbedTLS.SSLContext


const DEBUG_LEVEL = 0
const minimal = false

include("compat.jl")

include("debug.jl")
include("Pairs.jl")
include("Strings.jl")
include("IOExtras.jl")
include("uri.jl");                      using .URIs
                                                                     if !minimal
include("consts.jl")
include("utils.jl")
include("fifobuffer.jl");               using .FIFOBuffers
include("cookies.jl");                  using .Cookies
include("multipart.jl")
                                                                             end
include("parser.jl");                   import .Parsers: ParsingError, Headers
include("Connect.jl")
include("ConnectionPool.jl")
include("Messages.jl");                 using .Messages
                                        import .Messages: header, hasheader
include("HTTPStreams.jl");              using .HTTPStreams
include("WebSockets.jl");               using .WebSockets


request(method, uri, headers=[], body=UInt8[]; kw...)::Response =
    request(string(method), URI(uri), mkheaders(headers), body; kw...)

request(method::String, uri::URI, headers::Headers, body; kw...)::Response =
    request(HTTP.stack(;kw...), method, uri, headers, body; kw...)

open(f::Function, method::String, uri, headers=[]; kw...)::Response =
    request(method, uri, headers; iofunction=f, kw...)

get(a...; kw...) = request("GET", a..., kw...)
put(a...; kw...) = request("PUT", a..., kw...)
post(a...; kw...) = request("POST", a..., kw...)
head(a...; kw...) = request("HEAD", a..., kw...)


abstract type Layer end
                                                                     if !minimal
include("RedirectRequest.jl");          using .RedirectRequest
include("BasicAuthRequest.jl");         using .BasicAuthRequest
include("AWS4AuthRequest.jl");          using .AWS4AuthRequest
include("CookieRequest.jl");            using .CookieRequest
include("CanonicalizeRequest.jl");      using .CanonicalizeRequest
include("TimeoutRequest.jl");           using .TimeoutRequest
                                                                             end
include("MessageRequest.jl");           using .MessageRequest
include("ExceptionRequest.jl");         using .ExceptionRequest
                                        import .ExceptionRequest.StatusError
include("RetryRequest.jl");             using .RetryRequest
include("ConnectionRequest.jl");        using .ConnectionRequest
include("StreamRequest.jl");            using .StreamRequest
                                                                     if !minimal

function stack(;redirect=true,
                basicauthorization=false,
                awsauthorization=false,
                cookies=false,
                canonicalizeheaders=false,
                retry=true,
                statusexception=true,
                timeout=0,
                kw...)

    NoLayer = Union

    (redirect            ? RedirectLayer       : NoLayer){
    (basicauthorization  ? BasicAuthLayer      : NoLayer){
    (cookies             ? CookieLayer         : NoLayer){
    (canonicalizeheaders ? CanonicalizeLayer   : NoLayer){
                           MessageLayer{
    (awsauthorization    ? AWS4AuthLayer       : NoLayer){
    (retry               ? RetryLayer          : NoLayer){
    (statusexception     ? ExceptionLayer      : NoLayer){
                           ConnectionPoolLayer{
    (timeout > 0         ? TimeoutLayer        : NoLayer){
                           StreamLayer
    }}}}}}}}}}
end

                                                                            else
stack(;kw...) = MessageLayer{
                ExceptionLayer{
                ConnectionPoolLayer{
                StreamLayer}}}
                                                                             end

                                                                     if !minimal
include("client.jl")
include("sniff.jl")
include("handlers.jl");                  using .Handlers
include("server.jl");                    using .Nitrogen
include("precompile.jl")
                                                                             end

end # module
