using HTTP
@static if VERSION < v"0.7.0-DEV.2005"
    using Base.Test
else
    using Test
end

if VERSION < v"0.7.0-DEV.2575"
    const Dates = Base.Dates
else
    import Dates
end
if !isdefined(Base, :pairs)
    pairs(x) = x
end


@testset "HTTP" begin
    include("utils.jl");
    include("fifobuffer.jl");
    include("sniff.jl");
    include("uri.jl");
    include("cookies.jl");
    include("parser.jl");

    include("loopback.jl");
    include("WebSockets.jl");
    include("async.jl");
    include("messages.jl");
    include("client.jl");

#    include("handlers.jl")
#    include("server.jl")
end;
