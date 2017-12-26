__precompile__(true)
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
include("parser.jl");                   import .Parsers.ParsingError
include("Connect.jl")
include("ConnectionPool.jl")
include("Messages.jl");                 using .Messages
include("HTTPStreams.jl");              using .HTTPStreams

module RequestStack

    import ..HTTP
    using ..URIs
    import ..Messages.mkheaders
    import ..Messages.Response
    import ..Parsers.Headers

    request(method, uri, headers=[], body=UInt8[]; kw...) =
        request(string(method), URI(uri), mkheaders(headers), body; kw...)

    request(method::String, uri::URI, headers::Headers, body; kw...)::Response =
        request(HTTP.stack(;kw...), method, uri, headers, body; kw...)
end

open(f::Function, method::String, uri, headers=[]; kw...) =
    RequestStack.request(method, uri, headers; iofunction=f, kw...)

httpget(a...; kw...) = RequestStack.request("GET", a..., kw...)
httpput(a...; kw...) = RequestStack.request("PUT", a..., kw...)
httppost(a...; kw...) = RequestStack.request("POST", a..., kw...)
httphead(a...; kw...) = RequestStack.request("HEAD", a..., kw...)


abstract type Layer end
const NoLayer = Union
                                                                     if !minimal
include("RedirectRequest.jl");          using .RedirectRequest
include("BasicAuthRequest.jl");         using .BasicAuthRequest
include("CookieRequest.jl");            using .CookieRequest
include("CanonicalizeRequest.jl");      using .CanonicalizeRequest
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
                cookies=false,
                canonicalizeheaders=false,
                retry=true,
                statusexception=true,
                connectionpool=true,
                kw...)

    (redirect            ? RedirectLayer       : NoLayer){
    (basicauthorization  ? BasicAuthLayer      : NoLayer){
    (cookies             ? CookieLayer         : NoLayer){
    (canonicalizeheaders ? CanonicalizeLayer   : NoLayer){
                           MessageLayer{
    (retry               ? RetryLayer          : NoLayer){
    (statusexception     ? ExceptionLayer      : NoLayer){
    (connectionpool      ? ConnectionPoolLayer : ConnectLayer){
                           StreamLayer
    }}}}}}}}
end

                                                                            else
stack(;kw...) = ExceptionLayer{
                MessageLayer{
                ConnectionPoolLayer{
                #ConnectLayer{
                StreamLayer}}}
import .RequestStack.request
                                                                             end

                                                                     if !minimal
status(r) = r.status #FIXME
headers(r) = Dict(r.headers) #FIXME
import Base.== # FIXME rm
include("types.jl")
include("client.jl")
include("sniff.jl")
include("handlers.jl");                  using .Handlers
include("server.jl");                    using .Nitrogen
include("precompile.jl")
                                                                             end

end # module
