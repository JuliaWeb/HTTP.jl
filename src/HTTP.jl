__precompile__(true)
module HTTP

export Request, Response, FIFOBuffer

using MbedTLS

const TLS = MbedTLS

import Base.==

const DEBUG = false
const PARSING_DEBUG = false

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

# include("client.jl")
include("client2.jl")
include("routing.jl")
using .Routing
include("server.jl")
using .Nitrogen

function __init__()
    global const DEFAULT_CLIENT = Client()
end

end # module
# @time HTTP.parse(HTTP.Response, "HTTP/1.1 200 OK\r\n\r\n")
# @time HTTP.parse(HTTP.Request, "GET / HTTP/1.1\r\n\r\n")
# @time HTTP.get(HTTP.Client(nothing), "www.google.com")
