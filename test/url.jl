using JSON
using HTTP
using Test

@testset "HTTP.URL" begin
    tests = JSON.parse(String(read("resources/cweb-urls.json")))["tests"]["group"]

    @testset " - $test - $group" for group in tests, test in group["test"]
        name = group["name"]

        url = get(test, "url", nothing)

        if url !== nothing
            uri = nothing

            try
                uri = HTTP.URIs.parse_uri_reference(url; strict=true)
            catch e
                if e isa HTTP.URIs.ParseError || e isa AssertionError
                    continue
                else
                    rethrow(e)
                end
            end

            if haskey(test, "expect_protocol")
                @test uri.scheme == test["expect_protocol"][1:end-1]
            end

            if haskey(test, "expect_hostname")
                @test uri.host == test["expect_hostname"]
            end

            if haskey(test, "expect_port")
                @test uri.port == test["expect_port"]
            end
        end
    end
end
