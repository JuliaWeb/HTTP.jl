reload("HTTP")
using Base.Test

@testset "HTTP.HTTP" begin

function f(req, res)
    return HTTP.Response(200)
end

function mathstest(req, res)
    var = HTTP.Vars
    body = string(var["subject"], " ", var["sem"])
    return HTTP.Response(body)
end

function phytest(req, res)
    var = HTTP.Vars
    body = string(var["subject"], " ", var["sem"])
    return HTTP.Response(body)
end

r = HTTP.Router()

# Test for path HTTP.
# The order of register defines the priorit of matching if there are more than
# one match. So HTTP with more specific conditions should be registered
# above than others.
HTTP.register!(r, ((req, res) -> HTTP.Response(203)), "/test/{subject}")
HTTP.register!(r, mathstest, "/test/{subject}/sem/{sem:[1-3]+}")
HTTP.register!(r, phytest, "/test/{subject}/sem/{sem}")
HTTP.register!(r, ((req, res) -> HTTP.Response(204)), "/test", ["post"])
HTTP.register!(r, ((req, res) -> HTTP.Response(200)), "/test")

# simple path HTTP
req = HTTP.Request()
req.uri = HTTP.URI("/test")
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(200)

# default matching, when nothing matches. By default default handler is 404
req = HTTP.Request()
req.uri = HTTP.URI("/default")
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(404)

# default handler can be set explicitly
HTTP.setdefaulthandler(r, ((req, res) -> HTTP.Response(201)))
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(201)

# test for variable paths
req = HTTP.Request()
req.uri = HTTP.URI("/test/maths")
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(203)

# test for the value extraction from the path variables
req = HTTP.Request()
req.uri = HTTP.URI("/test/maths/sem/7")
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response("maths 7")

# test for regular expression, only matches if sem value is 1-3
req = HTTP.Request()
req.uri = HTTP.URI("/test/phy/sem/3")
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response("phy 3")

# test for method based HTTP
req = HTTP.Request()
req.uri = HTTP.URI("/test")
req.method = "POST"
@test HTTP.handle(r, req, HTTP.Response()) == HTTP.Response(204)

end
