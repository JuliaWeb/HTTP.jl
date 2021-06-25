"""
Due to compilation, it can take more than a second for the server to respond on the first request.
There are two ways to reduce this time to a few milliseconds.
One way is to use [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl) and another is to trigger compilation, which is shown below.
Note that this trigger is only useful if there is time in between startup and the first request.
For example, this happens when running a user facing server on Heroku.
"""
using HTTP
using Sockets

host = Sockets.localhost
port = 8080

# Retry returns an anonymous function.
const trigger_compilation = retry(; delays=ExponentialBackOff(n=5, first_delay=0.5)) do
    url = "http://$host:$port"
    # Hit "GET /" (and possibly more routes if needed)
    HTTP.get(url)
end

function hello(req::HTTP.Request)
    HTTP.Response(200, "Hello")
end

const ROUTER = HTTP.Router()
HTTP.@register(ROUTER, "GET", "/", hello)

@async trigger_compilation()
println("Starting server at http://$host:$port")
HTTP.serve(ROUTER, host, port)
