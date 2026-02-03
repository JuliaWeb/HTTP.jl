@testset "Headers helpers" begin
    h = HTTP.Headers()
    HTTP.addheader(h, "x-test-header", "abc")
    HTTP.addheader(h, "content-type", "text/plain")

    @test HTTP.header(h, "X-Test-Header") == "abc"
    @test HTTP.header(h, "missing", "default") == "default"
    @test HTTP.hasheader(h, "x-test-header")
    @test HTTP.headercontains(h, "x-test-header", "abc")

    HTTP.canonicalizeheaders!(h)
    @test any(x -> first(x) == "X-Test-Header", h)
    @test any(x -> first(x) == "Content-Type", h)
end

@testset "Headers vector compatibility" begin
    h = HTTP.Headers()
    push!(h, "a" => "1")
    push!(h, "b" => "2")
    @test h[1] == ("a" => "1")
    h[2] = "b" => "3"
    @test h[2] == ("b" => "3")
    insert!(h, 2, "c" => "4")
    @test h[2] == ("c" => "4")

    req = HTTP.Request("GET", "/")
    req.headers = ["x" => "1", "y" => "2"]
    @test length(req.headers) == 2
    req.headers = ["z" => "3"]
    @test length(req.headers) == 1
    @test HTTP.header(req, "z") == "3"

    hdrs = req.headers
    push!(hdrs, "w" => "4")
    @test HTTP.header(req, "w") == "4"
end
