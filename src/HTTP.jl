__precompile__()
module HTTP

export Request, Response, FIFOBuffer

using MbedTLS, Compat

const TLS = MbedTLS

import Base.==

const DEBUG = false
const PARSING_DEBUG = false

immutable ParsingError <: Exception
    msg::String
end
Base.show(io::IO, p::ParsingError) = println("HTTP.ParsingError: ", p.msg)

include("consts.jl")
include("utils.jl")
include("fifobuffer.jl")
include("sniff.jl")
include("uri.jl")
include("cookies.jl")
using .Cookies

include("headers.jl")
include("types.jl")
include("parser.jl")
include("client.jl")
include("server.jl")

if VERSION >= v"0.4.0-dev+5512"
    include("precompile/precompile_Base.jl")
    _precompile_1()
    include("precompile/precompile_Core.jl")
    _precompile_2()
    include("precompile/precompile_MbedTLS.jl")
    _precompile_3()
    # include("precompile/precompile_HTTP.jl")
    # _precompile_4()
end

# package-wide inits
function __init__()
    global const EMPTYBODY = FIFOBuffer()
    global const DEFAULT_PARSER = Parser()
    global const DEFAULT_CLIENT = Client()
    global const MAINTASK = current_task()
    # HTTP.parse(HTTP.Response, "HTTP/1.1 200 OK\r\n\r\n")
    # HTTP.parse(HTTP.Request, "GET / HTTP/1.1\r\n\r\n")
end

end # module
