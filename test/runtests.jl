using TestItems, TestItemRunner

@testsetup module Common
    export httpbin
    export isok

    const httpbin = get(ENV, "JULIA_TEST_HTTPBINGO_SERVER", "httpbingo.julialang.org")

    isok(r) = r.status == 200
end

@run_package_tests
