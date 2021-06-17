"""
Due to compilation, it can take more than a second for the server to respond on the first request.
There are two ways to reduce this time to a few milliseconds.
One way is to use [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl) and another is to trigger compilation, which is shown below.
Note that this trigger is only useful in situations where the server is not connected to immediately after starting it.
For example, this happens when running a server on Heroku.
"""
using HTTP
using Sockets

host = Sockets.localhost

function trigger_compilation(port)
    sleep(0.5)
    url = "http://$host:$port/"
    HTTP.get(url)
end

function status(req::HTTP.Request)
    HTTP.Response(200, "Ok")
end

const ROUTER = HTTP.Router()
HTTP.@register(ROUTER, "GET", "/status", status)

port = 8080
@async trigger_compilation(port)
HTTP.serve(ROUTER, host, port)
