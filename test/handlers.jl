module TestHandlers

using HTTP
using Test
import Base.==

==(a::HTTP.Response,b::HTTP.Response) = (a.status  == b.status)    &&
                                        (a.version == b.version)   &&
                                        (a.headers == b.headers)   &&
                                        (a.body    == b.body)

@testset "Handlers" begin
    @testset "FooRouter" begin
        r = HTTP.Router()
        f = HTTP.Handlers.RequestHandlerFunction((req) -> HTTP.Response(200))
        HTTP.@register(r, "/test", f)
        req = HTTP.Request()
        req.target = "/test"
        @test HTTP.handle(r, req) == HTTP.Response(200)
    end

    @testset "HTTP Router" begin
        f = HTTP.Handlers.RequestHandlerFunction((req) -> HTTP.Response(200))
        @test HTTP.handle(f, HTTP.Request()) == HTTP.Response(200)

        r = HTTP.Router()
        @test isempty(r.routes)
        @test HTTP.handle(r, HTTP.Request()) == HTTP.Response(404)

        HTTP.@register(r, "/path/to/greatness", f)
        req = HTTP.Request()
        req.target = "/path/to/greatness"
        @test HTTP.handle(r, req) == HTTP.Response(200)

        f2 = HTTP.Handlers.RequestHandlerFunction((req) -> HTTP.Response(201))
        HTTP.@register(r, "/next/path/to/greatness", f2)
        req = HTTP.Request()
        req.target = "/next/path/to/greatness"
        @test HTTP.handle(r, req) == HTTP.Response(201)

        r = HTTP.Router()
        HTTP.@register(r, "GET", "/sget", f)
        HTTP.@register(r, "POST", "/spost", f)
        HTTP.@register(r, "POST", "/tpost", f)
        req = HTTP.Request("GET", "/sget")
        @test HTTP.handle(r, req) == HTTP.Response(200)
        req = HTTP.Request("POST", "/sget")
        @test HTTP.handle(r, req) == HTTP.Response(404)
        req = HTTP.Request("GET", "/spost")
        @test HTTP.handle(r, req) == HTTP.Response(404)
        req = HTTP.Request("POST", "/spost")
        @test HTTP.handle(r, req) == HTTP.Response(200)
        req = HTTP.Request("GET", "/tpost")
        @test HTTP.handle(r, req) == HTTP.Response(404)
        req = HTTP.Request("POST", "/tpost")
        @test HTTP.handle(r, req) == HTTP.Response(200)

        r = HTTP.Router()
        HTTP.@register(r, "/test", f)
        HTTP.@register(r, "/test/*", f2)
        f3 = HTTP.Handlers.RequestHandlerFunction((req) -> HTTP.Response(202))
        HTTP.@register(r, "/test/sarv/ghotra", f3)
        f4 = HTTP.Handlers.RequestHandlerFunction((req) -> HTTP.Response(203))
        HTTP.@register(r, "/test/*/ghotra/seven", f4)

        req = HTTP.Request()
        req.target = "/test"
        @test HTTP.handle(r, req) == HTTP.Response(200)

        req.target = "/test/sarv"
        @test HTTP.handle(r, req) == HTTP.Response(201)

        req.target = "/test/sarv/ghotra"
        @test HTTP.handle(r, req) == HTTP.Response(202)

        req.target = "/test/sar/ghotra/seven"
        @test HTTP.handle(r, req) == HTTP.Response(203)
    end

end

end # module