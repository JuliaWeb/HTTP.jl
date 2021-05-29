using Test, HTTP, JSON

const dir = joinpath(dirname(pathof(HTTP)), "..", "test")
include("resources/TestRequest.jl")

@testset "HTTP" begin
    for f in [
              "ascii.jl",
              "chunking.jl",
              "utils.jl",
              "client.jl",
              "multipart.jl",
              "parsemultipart.jl",
              "sniff.jl",
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
              "mwe.jl",
             ]
        file = joinpath(dir, f)
        println("Running $file tests...")
        if isfile(file)
            include(file)
        else
            @show readdir(dirname(file))
        end
    end
end
