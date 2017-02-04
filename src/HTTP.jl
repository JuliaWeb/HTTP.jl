__precompile__()
module HTTP

if VERSION < v"0.6.0-dev.1256"
    Base.take!(io::Base.AbstractIOBuffer) = takebuf_array(io)
end

export Request, Response, FIFOBuffer

using MbedTLS

const TLS = MbedTLS

import Base.==

const DEBUG = true
const PARSING_DEBUG = true

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

include("types.jl")
include("parser.jl")
include("client.jl")
include("server.jl")

if VERSION >= v"0.4.0-dev+5512"
    include("precompile.jl")
    _precompile_()
end

# package-wide inits
function __init__()
    global const EMPTYBODY = FIFOBuffer()
    global const DEFAULT_PARSER = Parser()
    global const DEFAULT_CLIENT = Client()
    global const MAINTASK = current_task()
end

end # module
