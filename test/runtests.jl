using Test, HTTP, URIs

const httpbin = get(ENV, "JULIA_TEST_HTTPBINGO_SERVER", "httpbingo.julialang.org")
isok(r) = r.status == 200

include("utils.jl")
include("client.jl")
include("handlers.jl")
include("server.jl")