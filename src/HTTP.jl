module HTTP

if VERSION < v"0.6.0-dev.1256"
    Base.take!(io::Base.AbstractIOBuffer) = takebuf_array(io)
end

export Request, Response, FIFOBuffer

using MbedTLS

const TLS = MbedTLS

import Base.==

const DEBUG = true

const MAINTASK = current_task()

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

# package-wide inits
function __init__()

end

end # module
