__precompile__(true)
module HTTP

export Request, Response, FIFOBuffer

using MbedTLS

const TLS = MbedTLS

import Base.==

const DEBUG = false
const PARSING_DEBUG = false

if VERSION > v"0.7.0-DEV.2338"
    using Base64
end

@static if VERSION >= v"0.7.0-DEV.2915"
    using Unicode
end

macro uninit(expr)
    if !isdefined(Base, :uninitialized)
        splice!(expr.args, 2)
    end
    return esc(expr)
end

if !isdefined(Base, :pairs)
    pairs(x) = x
end

if VERSION < v"0.7.0-DEV.2575"
    const Dates = Base.Dates
else
    import Dates
end

struct ParsingError <: Exception
    msg::String
end
Base.show(io::IO, p::ParsingError) = println("HTTP.ParsingError: ", p.msg)

const CRLF = "\r\n"

include("consts.jl")
include("utils.jl")
include("uri.jl")
using .URIs
include("fifobuffer.jl")
using .FIFOBuffers
include("cookies.jl")
using .Cookies
include("multipart.jl")
include("types.jl")

include("parser.jl")
include("sniff.jl")

include("client.jl")
include("handlers.jl")
using .Handlers
include("server.jl")
using .Nitrogen

include("precompile.jl")

function __init__()
    global const DEFAULT_CLIENT = Client()
end

end # module
try
    HTTP.parse(HTTP.Response, "HTTP/1.1 200 OK\r\n\r\n")
    HTTP.parse(HTTP.Request, "GET / HTTP/1.1\r\n\r\n")
    HTTP.get(HTTP.Client(nothing), "www.google.com")
end
