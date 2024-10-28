using Test, HTTP, URIs

const httpbin = get(ENV, "JULIA_TEST_HTTPBINGO_SERVER", "httpbingo.julialang.org")

include("utils.jl")
include("client.jl")
include("handlers.jl")
include("server.jl")