function test_multipart(r, body)
    @test isok(r)
    json = JSON.parse(IOBuffer(HTTP.payload(r)))
    @test startswith(json["headers"]["Content-Type"][1], "multipart/form-data; boundary=")
    reset(body); mark(body)
end

@testset "HTTP.Form for multipart/form-data" begin
    headers = Dict("User-Agent" => "HTTP.jl")
    body = HTTP.Form(Dict())
    mark(body)
    @testset "Setting of Content-Type" begin
        test_multipart(HTTP.request("POST", "https://$httpbin/post", headers, body), body)
        test_multipart(HTTP.post("https://$httpbin/post", headers, body), body)
        test_multipart(HTTP.request("PUT", "https://$httpbin/put", headers, body), body)
        test_multipart(HTTP.put("https://$httpbin/put", headers, body), body)
    end
    @testset "HTTP.Multipart ensure show() works correctly" begin
        # testing that there is no error in printing when nothing is set for filename
        str = sprint(show, (HTTP.Multipart(nothing, IOBuffer("some data"), "plain/text", "", "testname")))
        @test findfirst("contenttype=\"plain/text\"", str) !== nothing
    end
    @testset "HTTP.Multipart test constructor" begin
        @test_nowarn HTTP.Multipart(nothing, IOBuffer("some data"), "plain/text", "", "testname")
        @test_throws MethodError HTTP.Multipart(nothing, "some data", "plain/text", "", "testname")
    end

    @testset "Boundary" begin
        @test HTTP.Form(Dict()) isa HTTP.Form
        @test HTTP.Form(Dict(); boundary="a") isa HTTP.Form
        @test HTTP.Form(Dict(); boundary=" Aa1'()+,-.:=?") isa HTTP.Form
        @test HTTP.Form(Dict(); boundary='a'^70) isa HTTP.Form
        @test_throws ArgumentError HTTP.Form(Dict(); boundary="")
        @test_throws ArgumentError HTTP.Form(Dict(); boundary='a'^71)
        @test_throws ArgumentError HTTP.Form(Dict(); boundary="a ")
    end
end
