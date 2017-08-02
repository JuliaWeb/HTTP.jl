__precompile__()
module HTTP

export Request, Response, FIFOBuffer

using MbedTLS, Compat

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
include("fifobuffer.jl")
include("sniff.jl")
include("uri.jl")
include("cookies.jl")
using .Cookies

include("multipart.jl")
include("types.jl")
include("parser.jl")
include("client.jl")
include("handlers.jl")
using .Handlers
include("server.jl")

end # module
# @time HTTP.parse(HTTP.Response, "HTTP/1.1 200 OK\r\n\r\n")
# @time HTTP.parse(HTTP.Request, "GET / HTTP/1.1\r\n\r\n")
# @time HTTP.get(HTTP.Client(nothing), "www.google.com")