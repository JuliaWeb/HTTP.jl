@testset "Headers helpers" begin
    h = HTTP.Headers()
    HTTP.addheader(h, "x-test-header", "abc")
    HTTP.addheader(h, "content-type", "text/plain")

    @test HTTP.header(h, "X-Test-Header") == "abc"
    @test HTTP.header(h, "missing", "default") == "default"
    @test HTTP.hasheader(h, "x-test-header")
    @test HTTP.headercontains(h, "x-test-header", "abc")

    HTTP.canonicalizeheaders!(h)
    @test any(x -> x.name == "X-Test-Header", h)
    @test any(x -> x.name == "Content-Type", h)
end
