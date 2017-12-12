__precompile__(true)
module HTTP

using MbedTLS
import MbedTLS.SSLContext
const TLS = MbedTLS


import Base.== # FIXME rm

const DEBUG = false # FIXME rm
const PARSING_DEBUG = false # FIXME rm
const DEBUG_LEVEL = 1

if VERSION > v"0.7.0-DEV.2338"
    using Base64
end

if VERSION < v"0.7.0-DEV.2575"
    const Dates = Base.Dates
else
    import Dates
end

#abstract type RequestLayer{Next} end

module RequestStack
    import ..HTTP
    request(m::String, a...; kw...) = request(HTTP.DefaultStack, m, a...; kw...)
end

#FIXME
status(r) = r.status
headers(r) = Dict(r.headers)

include("debug.jl")
include("Pairs.jl")
include("Strings.jl")
include("IOExtras.jl")

include("consts.jl")
include("utils.jl")

include("uri.jl")
using .URIs
include("fifobuffer.jl")
using .FIFOBuffers
include("cookies.jl")
using .Cookies
include("multipart.jl")

include("Parsers.jl")
import .Parsers.ParsingError
include("Messages.jl")

include("Connect.jl")
include("Connections.jl")

include("SendRequest.jl")
using .SendRequest

include("types.jl")
include("client.jl")
include("sniff.jl")

include("handlers.jl")
using .Handlers
include("server.jl")
using .Nitrogen

#include("precompile.jl")

function __init__()
    global const DEFAULT_CLIENT = Client()
end


include("ExceptionRequest.jl")
using .ExceptionRequest
import .ExceptionRequest.StatusError
include("RetryRequest.jl")
using .RetryRequest
include("CookieRequest.jl")
using .CookieRequest
include("BasicAuthRequest.jl")
using .BasicAuthRequest
include("CanonicalizeRequest.jl")
using .CanonicalizeRequest
include("RedirectRequest.jl")
using .RedirectRequest


const DefaultStack =
    RedirectLayer{
    CanonicalizeLayer{
    BasicAuthLayer{
    CookieLayer{
    RetryLayer{
    ExceptionLayer{
    MessageLayer{
    ConnectLayer{
    #Connect.Connection
    Connections.Connection
    }}}}}}}}




end # module
#=
try
    HTTP.parse(HTTP.Response, "HTTP/1.1 200 OK\r\n\r\n")
    HTTP.parse(HTTP.Request, "GET / HTTP/1.1\r\n\r\n")
    HTTP.get(HTTP.Client(nothing), "www.google.com")
end
=#
