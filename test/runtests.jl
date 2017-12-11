using HTTP
using Base.Test

if VERSION < v"0.7.0-DEV.2575"
    const Dates = Base.Dates
else
    import Dates
end

@testset "HTTP" begin
    include("utils.jl");
    include("fifobuffer.jl");
    include("sniff.jl");
    include("uri.jl");
    include("cookies.jl");
    include("parser.jl");
    include("body.jl");
    include("messages.jl");
#    include("types.jl");
#    include("handlers.jl")
    include("client.jl");
#    include("server.jl")
end;
