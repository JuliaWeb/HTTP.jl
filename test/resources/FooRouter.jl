module FooRouter

using HTTP
const r = HTTP.Router()
f = HTTP.Handlers.RequestHandlerFunction((req) -> HTTP.Response(200))
HTTP.@register(r, "/test", f)

end # module
