using HttpCommon
using FactCheck
using HttpServer

facts("HttpServer utility functions:") do
    context("`write` correctly writes data response") do
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

import Requests: get, text, statuscode

facts("HttpServer runs") do
    context("using HTTP protocol on 0.0.0.0:8000") do
        http = HttpHandler() do req::Request, res::Response
            res = Response( ismatch(r"^/hello/",req.resource) ? string("Hello ", split(req.resource,'/')[3], "!") : 404 )
            setcookie!(res, "sessionkey", "abc", Dict("Path"=>"/test", "Secure"=>""))
        end
        server = Server(http)
        @async run(server, 8000)
        sleep(1.0)

        ret = Requests.get("http://localhost:8000/hello/travis")
        @fact text(ret) => "Hello travis!"
        @fact statuscode(ret) => 200
        @fact haskey(ret.cookies, "sessionkey") --> true

        let cookie = ret.cookies["sessionkey"]
            @fact cookie.value --> "abc"
            @fact cookie.attrs["Path"] --> "/test"
            @fact haskey(cookie.attrs, "Secure") --> true
        end

        ret = Requests.get("http://localhost:8000/bad")
        @fact text(ret) => ""
        @fact statuscode(ret) => 404
    end

    context("using HTTP protocol on 127.0.0.1:8001") do
        http = HttpHandler() do req::Request, res::Response
            Response( ismatch(r"^/hello/",req.resource) ? string("Hello ", split(req.resource,'/')[3], "!") : 404 )
        end
        server = Server(http)
        @async run(server, host=ip"127.0.0.1", port=8001)
        sleep(1.0)

        ret = Requests.get("http://127.0.0.1:8001/hello/travis")
        @fact text(ret) => "Hello travis!"
        @fact statuscode(ret) => 200
    end
end
