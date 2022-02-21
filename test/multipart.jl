@testset "HTTP.Form for multipart/form-data" begin
    headers = Dict("User-Agent" => "HTTP.jl")
    body = HTTP.Form(Dict())
    uri = "https://httpbin.org/post"
    uri_put = "https://httpbin.org/put"
    @testset "Setting of Content-Type" begin
        for r in (HTTP.request("POST", uri, headers, body), HTTP.post(uri, headers, body),
                  HTTP.request("PUT", uri_put, headers, body), HTTP.put(uri_put, headers, body))
            @test r.status == 200
            json = JSON.parse(IOBuffer(HTTP.payload(r)))
            @test startswith(json["headers"]["Content-Type"], "multipart/form-data; boundary=")
        end
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
