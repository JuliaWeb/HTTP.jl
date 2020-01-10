using Distributed
addprocs(5)

using Test
using HTTP
using JSON

@testset "HTTP" begin
    for f in ["ascii.jl",
              "chunking.jl",
              "utils.jl",
              "client.jl",
              "multipart.jl",
              "sniff.jl",
              "uri.jl",
              "url.jl",
              "cookies.jl",
              "parser.jl",
              "loopback.jl",
              "websockets.jl",
              "messages.jl",
              "handlers.jl",
              "server.jl",
              "async.jl",
              "aws4.jl",
              "insert_layers.jl",
              "mwe.jl"
              "parsemultipart.jl"]
        println("Running $f tests...")
        include(f)
    end
end
