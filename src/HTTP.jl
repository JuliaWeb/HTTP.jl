__precompile__(true)
module HTTP

#export Request, Response, FIFOBuffer

#using MbedTLS
#import MbedTLS.SSLContext

const DEBUG_LEVEL = 1

if VERSION > v"0.7.0-DEV.2338"
    using Base64
end

if VERSION < v"0.7.0-DEV.2575"
    const Dates = Base.Dates
else
    import Dates
end

include("debug.jl")
include("Pairs.jl")
include("Strings.jl")
include("IOExtras.jl")

include("uri.jl")
using .URIs
include("cookies.jl")
#using .Cookies
#include("multipart.jl")
#include("types.jl")

#include("sniff.jl")



include("Bodies.jl")
include("Parsers.jl")
include("Messages.jl")

include("Connect.jl")
include("Connections.jl")



include("SendRequest.jl")

#include("client.jl")
#include("handlers.jl")
#using .Handlers
#include("server.jl")
#using .Nitrogen

#include("precompile.jl")

function __init__()
#    global const client_module = module_parent(current_module())
#    global const DEFAULT_CLIENT = Client()
end

abstract type HTTPError <: Exception end

struct StatusError <: HTTPError
    status::Int16
    response::Messages.Response
end
StatusError(r::Messages.Response) = StatusError(r.status, r)

include("RetryRequest.jl")
include("CookieRequest.jl")

end # module
#=
try
    HTTP.parse(HTTP.Response, "HTTP/1.1 200 OK\r\n\r\n")
    HTTP.parse(HTTP.Request, "GET / HTTP/1.1\r\n\r\n")
    HTTP.get(HTTP.Client(nothing), "www.google.com")
end
=#
