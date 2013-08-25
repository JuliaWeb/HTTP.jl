using HttpCommon
using FactCheck
import HttpServer

facts("HttpServer utility functions") do
    context("render does sensible things") do
        response = Response(200, "Hello World!")
        response_string = HttpServer.render(response)
        vals = split(response_string, "\r\n")
        @fact vals[1] => "HTTP/1.1 200 OK "
        @fact vals[2] => "Server: Julia/$VERSION"
        # default to text/html
        @fact vals[3] => "Content-Type: text/html; charset=utf-8"
        # skip date
        @fact vals[5] => "Content-Language: en"
        @fact vals[7] => "Hello World!"
    end
end
