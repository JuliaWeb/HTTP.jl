using Distributed
addprocs(5)

using Test
using HTTP
using JSON

@testset "HTTP" begin
    for f in ["ascii.jl",
              "issue_288.jl",
              "utils.jl",
              "client.jl",
              "sniff.jl",
              "uri.jl",
              "url.jl",
              "cookies.jl",
              "parser.jl",
              "loopback.jl",
              "WebSockets.jl",
              "messages.jl",
              "handlers.jl",
              "server.jl",
              "async.jl",
              "aws4.jl",
              "insert_layers.jl"]

        println("Running $f tests...")
        include(f)
    end
end
