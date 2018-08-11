@static if VERSION >= v"0.7.0-DEV.2915"
using Distributed
end
addprocs(5)

using Base64, Sockets, Dates

using HTTP
using HTTP.Dates


@testset "HTTP" begin
    include("utils.jl");
    include("sniff.jl");
    include("uri.jl");
    include("url.jl");
    include("cookies.jl");
    include("parser.jl");

    include("loopback.jl");
    include("WebSockets.jl");
    include("messages.jl");
    include("client.jl");

    include("handlers.jl")
    include("server.jl")

    include("async.jl");
end;
