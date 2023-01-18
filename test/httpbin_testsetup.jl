@testsetup module HTTPBin
    export httpbin
    const httpbin = get(ENV, "JULIA_TEST_HTTPBINGO_SERVER", "httpbingo.julialang.org")
end
