using HTTP
using HTTP.Dates
using HTTP.Unicode
using HTTP.Test

@testset "HTTP" begin
    include("utils.jl");
    include("fifobuffer.jl");
    include("sniff.jl");
    include("uri.jl");
    include("cookies.jl");
    include("parser.jl");

    include("loopback.jl");
    include("WebSockets.jl");
    include("messages.jl");
    include("client.jl");

    include("handlers.jl")
#    include("server.jl")

    include("async.jl");
end;
