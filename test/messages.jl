using ..Test

using HTTP.Messages
import HTTP.Messages.appendheader
import HTTP.URI
import HTTP.request
import HTTP: bytes

using HTTP: StatusError

using HTTP.MessageRequest: bodylength
using HTTP.MessageRequest: bodybytes
using HTTP.MessageRequest: unknown_length

using JSON

@testset "HTTP.Messages" begin
    req = Request("GET", "/foo", ["Foo" => "Bar"])
    res = Response(200, ["Content-Length" => "5"]; body="Hello", request=req)

    protocols = ["http", "https"]
    http_reads = ["GET", "HEAD", "OPTIONS"]
    http_writes = ["POST", "PUT", "DELETE", "PATCH"]

    @testset "Body Length" begin
        @test bodylength(7) == unknown_length
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
    end

    @testset "Body Bytes" begin
        @test bodybytes(7) == UInt8[]
        @test bodybytes(UInt8[1,2,3]) == UInt8[1,2,3]
        @test bodybytes(view(UInt8[1,2,3], 1:2)) == UInt8[1,2]
        @test bodybytes("Hello") == bytes("Hello")
        @test bodybytes(SubString("World!",1,5)) == bytes("World")
        @test bodybytes(["Hello", " ", "World!"]) == UInt8[]
        @test bodybytes([UInt8[1,2,3], UInt8[4,5,6]]) == UInt8[]
    end

    @testset "Request" begin
        @test req.method == "GET"
        @test res.request.method == "GET"

        @test String(req) == "GET /foo HTTP/1.1\r\nFoo: Bar\r\n\r\n"
        @test String(res) == "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello"

        @test header(req, "Foo") == "Bar"
        @test header(res, "Content-Length") == "5"

        setheader(req, "X" => "Y")
        @test header(req, "X") == "Y"
    end

    @testset "Header Append" begin
        append_header(m, h) = appendheader(m, SubString(h[1]) => SubString(h[2]))

        append_header(req, "X" => "Z")
        @test header(req, "X") == "Y, Z"
        @test hasheader(req, "X", "Y, Z")
        @test headercontains(req, "X", "Y")
        @test headercontains(req, "X", "Z")
        @test !headercontains(req, "X", "more")

        append_header(req, "X" => "more")
        @test header(req, "X") == "Y, Z, more"
        @test hasheader(req, "X", "Y, Z, more")
        @test headercontains(req, "X", "Y")
        @test headercontains(req, "X", "Z")
        @test headercontains(req, "X", "more")

        append_header(req, "Set-Cookie" => "A")
        append_header(req, "Set-Cookie" => "B")
        @test filter(x->first(x) == "Set-Cookie", req.headers) == ["Set-Cookie" => "A", "Set-Cookie" => "B"]
    end

    @testset "HTTP Version" begin
        @test Messages.httpversion(req) == "HTTP/1.1"
        @test Messages.httpversion(res) == "HTTP/1.1"

        raw = String(req)
        req = parse(Request,raw)
        @test String(req) == raw

        req = parse(Request, raw * "xxx")
        @test String(req) == raw

        raw = String(res)
        res = parse(Response,raw)
        @test String(res) == raw

        res = parse(Response,raw * "xxx")
        @test String(res) == raw
    end

    @testset "Read methods" for protocol in protocols, method in http_reads
        @test request(method, "$protocol://httpbin.org/ip", verbose=1).status == 200
    end

    @testset "Body - Response Stream" for protocol in protocols, method in http_writes
        uri = "$protocol://httpbin.org/$(lowercase(method))"
        r = request(method, uri, verbose=1)
        @test r.status == 200
        r1 = JSON.parse(String(r.body))

        io = Base.BufferStream()
        r = request(method, uri, response_stream=io, verbose=1)
        @test r.status == 200
        r2 = JSON.parse(IOBuffer(read(io)))
        for (k, v) in r1
            if k == "headers"
                for (k2, v2) in r1[k]
                    if k2 != "X-Amzn-Trace-Id"
                        @test r1[k][k2] == r2[k][k2]
                    end
                end
            else
                @test r1[k] == r2[k]
            end
        end
    end

    @testset "Body - JSON Parse" for protocol in protocols, method in http_writes
        uri = "$protocol://httpbin.org/$(lowercase(method))"
        io = Base.BufferStream()
        r = request(method, uri, response_stream=io, verbose=1)
        @test r.status == 200

        r = request("POST",
            "$protocol://httpbin.org/post",
            ["Expect" => "100-continue"],
            "Hello",
            verbose=1)

        @test r.status == 200
        r = JSON.parse(String(r.body))
        @test r["data"] == "Hello"
    end

    @testset "Write to file" begin
        cd(mktempdir()) do

            line_count = 0
            num_lines = 50

            open("result_file", "w") do io
                r = request("GET",
                    "http://httpbin.org/stream/$num_lines",
                    response_stream=io,
                    verbose=1)
            end

            for line in readlines("result_file")
                line_parsed = JSON.parse(line)
                @test line_count == line_parsed["id"]
                line_count += 1
            end

            @test line_count == num_lines
        end
    end

    @testset "Display" begin
        @test repr(Response(200, []; body="Hello world.")) == "Response:\n\"\"\"\nHTTP/1.1 200 OK\r\n\r\nHello world.\"\"\""

        # truncation of long bodies
        for body_show_max in (Messages.body_show_max, 100)
            Messages.set_show_max(body_show_max)
            @test repr(Response(200, []; body="Hello world.\n"*'x'^10000)) == "Response:\n\"\"\"\nHTTP/1.1 200 OK\r\n\r\nHello world.\n"*'x'^(body_show_max-13)*"\n⋮\n10013-byte body\n\"\"\""
        end

        # don't display raw binary (non-Unicode) data:
        @test repr(Response(200, []; body=String([0xde,0xad,0xc1,0x71,0x1c]))) == "Response:\n\"\"\"\nHTTP/1.1 200 OK\r\n\r\n\n⋮\n5-byte body\n\"\"\""
    end
end