using Test, HTTP, JSON

const dir = joinpath(dirname(pathof(HTTP)), "..", "test")

const httpbin = get(ENV, "JULIA_TEST_HTTPBINGO_SERVER", "httpbingo.julialang.org")

isok(r) = r.status == 200

include(joinpath(dir, "resources/TestRequest.jl"))
@testset "HTTP" begin
    for f in [
            "ascii.jl",
            "chunking.jl",
            "utils.jl",
            "client.jl",
            # "download.jl",
            "multipart.jl",
            "parsemultipart.jl",
            "sniff.jl",
            "cookies.jl",
            "parser.jl",
            "loopback.jl",
            "websockets/deno_client/server.jl",
            "messages.jl",
            "handlers.jl",
            "server.jl",
            "async.jl",
            "mwe.jl",
            "httpversion.jl",
            "websockets/autobahn.jl",
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
