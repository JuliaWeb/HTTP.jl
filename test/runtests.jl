using Test, HTTP, JSON

const dir = joinpath(dirname(pathof(HTTP)), "..", "test")

include(joinpath(dir, "resources/TestRequest.jl"))
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
            "websockets/deno_client/server.jl",
            "websockets/autobahn.jl",
            "messages.jl",
            "handlers.jl",
            "server.jl",
            "async.jl",
            "mwe.jl",
            "try_with_timeout.jl",
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
