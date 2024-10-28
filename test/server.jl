using Test, HTTP

@testset "HTTP.serve" begin
    server = HTTP.serve!(req -> HTTP.Response(200, "Hello, World!"))
    @test server.state == :running
    resp = HTTP.get("http://127.0.0.1:8080")
    @test resp.status == 200
    @test String(resp.body) == "Hello, World!"
end