using Test, HTTP, JSON

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
              "mwe.jl"]
        println("Running $f tests...")
        include(f)
    end
end
