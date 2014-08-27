using HttpCommon
using FactCheck
using HttpServer

facts("HttpServer utility functions") do
    context("HttpServer.write does sensible things") do
        response = Response(200, "Hello World!")
        buf = IOBuffer();
        HttpServer.write(buf, response)
        response_string = takebuf_string(buf)
        vals = split(response_string, "\r\n")
        grep(a::Array, k::String) = filter(x -> ismatch(Regex(k), x), a)[1]
        @fact grep(vals, "HTTP") => "HTTP/1.1 200 OK "
        @fact grep(vals, "Server") => "Server: Julia/$VERSION"
        # default to text/html
        @fact grep(vals, "Content-Type") => "Content-Type: text/html; charset=utf-8"
        # skip date
        @fact grep(vals, "Content-Language") => "Content-Language: en"
        @fact grep(vals, "Hello") => "Hello World!"
    end
end

import Requests

facts("HttpServer run") do
    context("HttpServer can run the example") do
        http = HttpHandler() do req::Request, res::Response
            Response( ismatch(r"^/hello/",req.resource) ? string("Hello ", split(req.resource,'/')[3], "!") : 404 )
        end
        http.events["error"]  = (client, err) -> println(err)
        http.events["listen"] = (port )       -> println("Listening on $port...")

        server = Server(http)
        @async run(server, 8000)
        sleep(1.0)

        ret = Requests.get("http://localhost:8000/hello/travis")
        @fact ret.data => "Hello travis!"
        @fact ret.status => 200

        ret = Requests.get("http://localhost:8000/bad")
        @fact ret.data => ""
        @fact ret.status => 404
    end
end

