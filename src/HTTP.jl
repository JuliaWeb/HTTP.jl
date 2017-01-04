module HTTP

export Request, Response, FIFOBuffer, URI

using MbedTLS

const TLS = MbedTLS

import Base.==

const DEBUG = false

include("statuscodes.jl")
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
    __init__parser()
end

end # module
