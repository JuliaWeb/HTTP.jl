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

    context("updateresponse sets the status") do
        response = Response(200, "Hello World!")
        response = HttpServer.updateresponse(response, 500)
        @fact response.status => 500
    end

    context("updateresponse sets the data") do
        response = Response(200, "Hello World!")
        response = HttpServer.updateresponse(response, "Goodbye, World!")
        @fact response.data => "Goodbye, World!"
    end

    context("updateresponse sets both status and data") do
        response = Response(200, "Hello World!")
        response = HttpServer.updateresponse(response, (302, "Goodbye, World!"))
        @fact response.status => 302
        @fact response.data => "Goodbye, World!"
    end
end

