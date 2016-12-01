module HTTP

export Request, Response, URI

using MbedTLS

const TLS = MbedTLS

import Base.==

include("statuscodes.jl")
include("utils.jl")
include("uri.jl")
include("types.jl")
include("parser.jl")
include("server.jl")

# package-wide inits
function __init__()
    __init__parser()
end

end # module
