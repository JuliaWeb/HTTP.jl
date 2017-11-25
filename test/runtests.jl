using HTTP
using Compat
using Compat.Dates
using Compat.Test

import Compat.Dates: now, DateTime

@testset "HTTP" begin
    include("utils.jl");
    include("fifobuffer.jl");
    include("sniff.jl");
    include("uri.jl");
    include("cookies.jl");
    include("parser.jl");
    include("types.jl");
    include("handlers.jl")
    include("client.jl");
    include("server.jl")
end;
