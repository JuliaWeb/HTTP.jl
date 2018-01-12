if VERSION > v"0.7.0-DEV.2338"
using Test
end

using HTTP

import Base.==

==(a::HTTP.Response,b::HTTP.Response) = (a.status  == b.status)    &&
                                        (a.version == b.version)   &&
                                        (a.headers == b.headers)   &&
                                        (a.body    == b.body)

@testset "HTTP.Handler" begin

f = HTTP.HandlerFunction((req, resp) -> HTTP.Response(200))
@test HTTP.handle(f, HTTP.Request(), HTTP.Response()) == HTTP.Response(200)

r = HTTP.Router()
@test length(methods(r.func)) == 1
@test HTTP.handle(r, HTTP.Request(), HTTP.Response()) == HTTP.Response(404)

HTTP.register!(r, "/path/to/greatness", f)
@test length(methods(r.func)) == 2
req = HTTP.Request()
req.uri = "/path/to/greatness"
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(200)

p = "/next/path/to/greatness"
f2 = HTTP.HandlerFunction((req, resp) -> HTTP.Response(201))
HTTP.register!(r, p, f2)
@test length(methods(r.func)) == 3
req = HTTP.Request()
req.uri = "/next/path/to/greatness"
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(201)

r = HTTP.Router()
HTTP.register!(r, "GET", "/sget", f)
HTTP.register!(r, "POST", "/spost", f)
HTTP.register!(r, HTTP.POST, "/tpost", f)
req = HTTP.Request("GET", "/sget")
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(200)
req = HTTP.Request("POST", "/sget")
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(404)
req = HTTP.Request("GET", "/spost")
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(404)
req = HTTP.Request("POST", "/spost")
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(200)
req = HTTP.Request("GET", "/tpost")
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(404)
req = HTTP.Request("POST", "/tpost")
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(200)

r = HTTP.Router()
HTTP.register!(r, "/test", f)
HTTP.register!(r, "/test/*", f2)
f3 = HTTP.HandlerFunction((req, resp) -> HTTP.Response(202))
HTTP.register!(r, "/test/sarv/ghotra", f3)
f4 = HTTP.HandlerFunction((req, resp) -> HTTP.Response(203))
HTTP.register!(r, "/test/*/ghotra/seven", f4)

req = HTTP.Request()
req.uri = "/test"
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(200)

req.uri = "/test/sarv"
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(201)

req.uri = "/test/sarv/ghotra"
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(202)

req.uri = "/test/sar/ghotra/seven"
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(203)

end
