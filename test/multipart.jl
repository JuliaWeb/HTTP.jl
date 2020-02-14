@testset "HTTP.Form for multipart/form-data" begin
    headers = Dict("User-Agent" => "HTTP.jl")
    body = HTTP.Form(Dict())
    uri = "https://httpbin.org/post"

    @testset "Setting of Content-Type" begin
        for r in (HTTP.request("POST", uri, headers, body), HTTP.post(uri, headers, body))
            @test r.status == 200
            json = JSON.parse(IOBuffer(HTTP.payload(r)))
            @test startswith(json["headers"]["Content-Type"], "multipart/form-data; boundary=")
        end
    end

    @testset "Deprecation of HTTP.post without header for body::Form" begin
        @test_logs (:warn, r"deprecated") HTTP.post(uri, body).status == 200
    end
end
