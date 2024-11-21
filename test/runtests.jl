using Test, HTTP, JSON

# Using this rather than @__DIR__ because then it's easier to run parts of the
# file at the REPL, which is convenient when developing the package.
const dir = joinpath(dirname(pathof(HTTP)), "..", "test")

# See https://httpbingo.julialang.org/
const httpbin = get(ENV, "JULIA_TEST_HTTPBINGO_SERVER", "httpbingo.julialang.org")

# A convenient test helper used in a few test files.
isok(r) = r.status == 200

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
        "websockets/multiple_writers.jl",
    ]
    # ARGS can be most easily passed like this:
    # import Pkg; Pkg.test("HTTP"; test_args=`ascii.jl parser.jl`)
    if !isempty(ARGS)
        filter!(in(ARGS), testfiles)
    end
    for filename in testfiles
        println("Running $filename tests...")
        include(joinpath(dir, filename))
    end
end
