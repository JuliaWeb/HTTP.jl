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
port = 8080

# Retry returns an anonymous function.
const trigger_compilation = retry(; delays=ExponentialBackOff(n=5, first_delay=0.5)) do
    url = "http://$host:$port"
    # Hit "GET /" (and possibly more routes if needed)
    HTTP.get(url)
end

function status(req::HTTP.Request)
    HTTP.Response(200, "Ok")
end

const ROUTER = HTTP.Router()
HTTP.@register(ROUTER, "GET", "/status", status)

@async trigger_compilation()
println("Starting server at http://$host:$port")
HTTP.serve(ROUTER, host, port)
