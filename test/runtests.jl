using Test, HTTP, JSON

const dir = joinpath(dirname(pathof(HTTP)), "..", "test")

const httpbin = get(ENV, "JULIA_TEST_HTTPBINGO_SERVER", "httpbingo.julialang.org")

isok(r) = r.status == 200

include(joinpath(dir, "resources/TestRequest.jl"))
@testset "HTTP" begin
    testfiles = [
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
    # ARGS can be most easily passed like this:
    # import Pkg; Pkg.test("HTTP"; test_args=`ascii.jl parser.jl`)
    if !isempty(ARGS)
        filter!(in(ARGS), testfiles)
    end
    for filename in testfiles
        filepath = joinpath(dir, filename)
        println("Running $filepath tests...")
        include(filepath)
    end
end
