__precompile__(true)
module HTTP

export Request, Response, FIFOBuffer

using MbedTLS
import MbedTLS.SSLContext
const TLS = MbedTLS

import Base.==

const DEBUG = false # FIXME rm
const PARSING_DEBUG = false # FIXME rm
const DEBUG_LEVEL = 2

if VERSION > v"0.7.0-DEV.2338"
    using Base64
end

if VERSION < v"0.7.0-DEV.2575"
    const Dates = Base.Dates
else
    import Dates
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

include("Bodies.jl")
include("Parsers.jl")
import .Parsers.ParsingError
include("Messages.jl")

include("Connect.jl")
include("Connections.jl")

include("SendRequest.jl")
import .SendRequest.StatusError

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
