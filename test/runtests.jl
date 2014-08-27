using HttpCommon
using FactCheck
import HttpServer

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
