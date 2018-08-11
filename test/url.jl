using Test
using JSON

using HTTP

@testset "HTTP.URL" begin

    tests = JSON.parse(String(read("cweb-urls.json")))["tests"]["group"]

for group in tests

    name = group["name"]
    @testset "HTTP.URL.$name" begin

        println(name)

        for test in group["test"]

            if !haskey(test, "url")
                continue
            end
            println("$(test["id"]). $(test["url"]) $(test["name"])")

            url = test["url"]
            uri = nothing
            try
                uri = HTTP.URIs.parse_uri_reference(url; strict=true)
            catch e
                if e isa HTTP.URIs.ParseError
                    println(e)
                    continue
                elseif e isa AssertionError
                    println(e)
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
    

end # @testset "HTTP.URL"
