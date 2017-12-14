__precompile__(true)
module HTTP

using MbedTLS
import MbedTLS.SSLContext


import Base.== # FIXME rm

const DEBUG_LEVEL = 1

if VERSION > v"0.7.0-DEV.2338"
    using Base64
end

if VERSION < v"0.7.0-DEV.2575"
    const Dates = Base.Dates
else
    import Dates
end

const minimal = false

module RequestStack

    import ..HTTP
    request(m::String, a...; kw...) = request(HTTP.stack(;kw...), m, a...; kw...)

end

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
include("Parsers.jl");                  import .Parsers.ParsingError
include("Connect.jl")
include("ConnectionPool.jl")
include("Messages.jl")


abstract type Layer end
const NoLayer = Union

include("SocketRequest.jl");             using .SocketRequest
include("ConnectionRequest.jl");         using .ConnectionRequest
include("MessageRequest.jl");            using .MessageRequest
                                                                     if !minimal
include("ExceptionRequest.jl");          using .ExceptionRequest
                                         import .ExceptionRequest.StatusError
include("RetryRequest.jl");              using .RetryRequest
include("CookieRequest.jl");             using .CookieRequest
include("BasicAuthRequest.jl");          using .BasicAuthRequest
include("CanonicalizeRequest.jl");       using .CanonicalizeRequest
include("RedirectRequest.jl");           using .RedirectRequest

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
    (retry               ? RetryLayer          : NoLayer){
    (statusexception     ? ExceptionLayer      : NoLayer){
                           MessageLayer{
    (connectionpool      ? ConnectionPoolLayer : ConnectLayer){
                           SocketLayer
    }}}}}}}}
end

                                                                            else
stack(;kw...) = MessageLayer{ConnectLayer{SocketLayer}}
                                                                             end

if !minimal
status(r) = r.status #FIXME
headers(r) = Dict(r.headers) #FIXME
include("types.jl")
include("client.jl")
include("sniff.jl")
include("handlers.jl");                  using .Handlers
include("server.jl");                    using .Nitrogen
end

include("precompile.jl")

end # module
