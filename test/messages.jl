module MessagesTest

using Base.Test
if VERSION > v"0.7.0-DEV.2338"
using Unicode
end

using HTTP.Messages
import HTTP.Messages.appendheader
import HTTP.URI
import HTTP.request

using HTTP.StatusError

using HTTP.MessageRequest.bodylength
using HTTP.MessageRequest.bodybytes
using HTTP.MessageRequest.unknownlength

using JSON

@testset "HTTP.Messages" begin

    @test bodylength(7) == unknownlength
    @test bodylength(UInt8[1,2,3]) == 3
    @test bodylength(view(UInt8[1,2,3], 1:2)) == 2
    @test bodylength("Hello") == 5
    @test bodylength(SubString("World!",1,5)) == 5
    @test bodylength(["Hello", " ", "World!"]) == 12
    @test bodylength(["Hello", " ", SubString("World!",1,5)]) == 11
    @test bodylength([SubString("Hello", 1,5), " ", SubString("World!",1,5)]) == 11
    @test bodylength([UInt8[1,2,3], UInt8[4,5,6]]) == 6
    @test bodylength([UInt8[1,2,3], view(UInt8[4,5,6],1:2)]) == 5
    @test bodylength([view(UInt8[1,2,3],1:2), view(UInt8[4,5,6],1:2)]) == 4
    @test bodylength(IOBuffer("foo")) == 3
    @test bodylength([IOBuffer("foo"), IOBuffer("bar")]) == 6

    @test bodybytes(7) == UInt8[]
    @test bodybytes(UInt8[1,2,3]) == UInt8[1,2,3]
    @test bodybytes(view(UInt8[1,2,3], 1:2)) == UInt8[1,2]
    @test bodybytes("Hello") == Vector{UInt8}("Hello")
    @test bodybytes(SubString("World!",1,5)) == Vector{UInt8}("World")
    @test bodybytes(["Hello", " ", "World!"]) == UInt8[]
    @test bodybytes([UInt8[1,2,3], UInt8[4,5,6]]) == UInt8[]


    req = Request("GET", "/foo", ["Foo" => "Bar"])
    res = Response(200, ["Content-Length" => "5"]; body="Hello", request=req)

    @test req.method == "GET"
    @test res.request.method == "GET"

    #display(req); println()
    #display(res); println()

    @test String(req) == "GET /foo HTTP/1.1\r\nFoo: Bar\r\n\r\n"
    @test String(res) == "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello"

    @test header(req, "Foo") == "Bar"
    @test header(res, "Content-Length") == "5"
    setheader(req, "X" => "Y")
    @test header(req, "X") == "Y"

    appendheader(req, "" => "Z")
    @test header(req, "X") == "YZ"

    appendheader(req, "X" => "more")
    @test header(req, "X") == "YZ, more"

    appendheader(req, "Set-Cookie" => "A")
    appendheader(req, "Set-Cookie" => "B")
    @test filter(x->first(x) == "Set-Cookie", req.headers) ==
        ["Set-Cookie" => "A", "Set-Cookie" => "B"]

    @test Messages.httpversion(req) == "HTTP/1.1"
    @test Messages.httpversion(res) == "HTTP/1.1"

    raw = String(req)
    #@show raw
    req = Request(raw)
    #display(req); println()
    @test String(req) == raw

    req = Request(raw * "xxx")
    @test String(req) == raw

    raw = String(res)
    #@show raw
    res = Response(raw)
    #display(res); println()
    @test String(res) == raw

    res = Response(raw * "xxx")
    @test String(res) == raw

    for sch in ["http", "https"]
        for m in ["GET", "HEAD", "OPTIONS"]
            @test request(m, "$sch://httpbin.org/ip").status == 200
        end
        try
            request("POST", "$sch://httpbin.org/ip")
            @test false
        catch e
            @test isa(e, StatusError)
            @test e.status == 405
        end
    end

#=
    @sync begin
        io = BufferStream()
        @async begin
            for i = 1:100
                sleep(0.1)
                write(io, "Hello!")
            end
            close(io)
        end
        yield()
        r = request("POST", "http://httpbin.org/post", [], io)
        @test r.status == 200
    end
=#

    for sch in ["http", "https"]
        for m in ["POST", "PUT", "DELETE", "PATCH"]

            uri = "$sch://httpbin.org/$(lowercase(m))"
            r = request(m, uri)
            @test r.status == 200
            body = r.body

            io = BufferStream()
            r = request(m, uri, response_stream=io)
            close(io)
            @test r.status == 200
            @test read(io) == body
        end
    end

    for sch in ["http", "https"]
        for m in ["POST", "PUT", "DELETE", "PATCH"]

            uri = "$sch://httpbin.org/$(lowercase(m))"
            io = BufferStream()
            r = request(m, uri, response_stream=io)
            close(io)
            @test r.status == 200
        end

        r = request("POST", "$sch://httpbin.org/post",
                   ["Expect" => "100-continue"], "Hello")
        @test r.status == 200
        r = JSON.parse(String(r.body))
        @test r["data"] == "Hello"
    end

    mktempdir() do d
        cd(d) do

            n = 50
            io = open("result_file", "w")
            r = request("GET", "http://httpbin.org/stream/$n",
                        response_stream=io)
            close(io)
            @show filesize("result_file")
            i = 0
            for l in readlines("result_file")
                x = JSON.parse(l)
                @test i == x["id"]
                i += 1
            end
            @test i == n
        end
    end

end

end # module MessagesTest
