using Test, HTTP, URIs, JSON, Reseau

const httpbin = get(ENV, "JULIA_TEST_HTTPBINGO_SERVER", "httpbingo.julialang.org")
isok(r) = r.status == 200
const HAVE_HTTPBIN = let
    try
        resp = HTTP.get("http://$httpbin/ip"; readtimeout=2, max_retries=0)
        isok(resp)
    catch
        false
    end
end

include("utils.jl")
include("headers.jl")
include("httpversion.jl")
include("sniff.jl")
include("multipart.jl")
include("client.jl")
include("handlers.jl")
include("server.jl")
include("websockets_basic.jl")
if get(ENV, "HTTP_RUN_AWSHTTP_VENDORED_TESTS", "0") == "1"
    include("awshttp_vendor.jl")
end
include("trim_compile_tests.jl")
