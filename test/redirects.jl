@testset "redirects.jl" begin
    @test HTTP.get("https://en.wikipedia.org/api/rest_v1/page/summary/Potato"; redirect = false).status == 200
    @test HTTP.get("https://en.wikipedia.org/api/rest_v1/page/summary/Potato"; redirect = true).status == 200
    @test HTTP.get("https://en.wikipedia.org/api/rest_v1/page/summary/Potatoes"; redirect = false).status == 302
    @test HTTP.get("https://en.wikipedia.org/api/rest_v1/page/summary/Potatoes"; redirect = true).status == 200
end
