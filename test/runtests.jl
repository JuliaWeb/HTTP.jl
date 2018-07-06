using Test
using Distributed
addprocs(5)

using Test
using HTTP


@testset "HTTP" begin
    println("running utils.jl tests..."); include("utils.jl");
    println("running sniff.jl tests..."); include("sniff.jl");
    println("running uri.jl tests..."); include("uri.jl");
    println("running url.jl tests..."); include("url.jl");
    println("running cookies.jl tests..."); include("cookies.jl");
    println("running parser.jl tests..."); include("parser.jl");

    println("running loopback.jl tests..."); include("loopback.jl");
    # println("running WebSockets.jl tests..."); include("WebSockets.jl");
    println("running messages.jl tests..."); include("messages.jl");
    
    println("running download.jl tests...)"; include("download.jl");

    println("running handlers.jl tests..."); include("handlers.jl")
    println("running server.jl tests..."); include("server.jl")

    println("running async.jl tests..."); include("async.jl");
end;
