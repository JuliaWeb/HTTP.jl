using Test

using HTTP.Messages
import ..isok, ..httpbin
import HTTP.Messages: appendheader, mkheaders
import HTTP.URI
import HTTP.request
import HTTP: bytes, nbytes
using HTTP: StatusError

using JSON

@testset "HTTP.Messages" begin
    req = Request("GET", "/foo", ["Foo" => "Bar"])
    res = Response(200, ["Content-Length" => "5"]; body="Hello", request=req)

    http_reads = ["GET", "HEAD", "OPTIONS"]
    http_writes = ["POST", "PUT", "DELETE", "PATCH"]

    @testset "Invalid headers" begin
        @test_throws ArgumentError mkheaders(["hello"])
        @test_throws ArgumentError mkheaders([(1,2,3,4,5)])
        @test_throws ArgumentError mkheaders([1, 2])
        @test_throws ArgumentError mkheaders(["hello", "world"])
    end

    @testset "Body Length" begin
        @test nbytes(7) === nothing
        @test nbytes(UInt8[1,2,3]) == 3
        @test nbytes(view(UInt8[1,2,3], 1:2)) == 2
        @test nbytes("Hello") == 5
        @test nbytes(SubString("World!",1,5)) == 5
        @test nbytes(["Hello", " ", "World!"]) == 12
        @test nbytes(["Hello", " ", SubString("World!",1,5)]) == 11
        @test nbytes([SubString("Hello", 1,5), " ", SubString("World!",1,5)]) == 11
        @test nbytes([UInt8[1,2,3], UInt8[4,5,6]]) == 6
        @test nbytes([UInt8[1,2,3], view(UInt8[4,5,6],1:2)]) == 5
        @test nbytes([view(UInt8[1,2,3],1:2), view(UInt8[4,5,6],1:2)]) == 4
        @test nbytes(IOBuffer("foo")) == 3
        @test nbytes([IOBuffer("foo"), IOBuffer("bar")]) == 6
    end

    @testset "Body Bytes" begin
        @test bytes(7) == 7
        @test bytes(UInt8[1,2,3]) == UInt8[1,2,3]
        @test bytes(view(UInt8[1,2,3], 1:2)) == UInt8[1,2]
        @test bytes("Hello") == codeunits("Hello")
        @test bytes(SubString("World!",1,5)) == codeunits("World")
        @test bytes(["Hello", " ", "World!"]) == ["Hello", " ", "World!"]
        @test bytes([UInt8[1,2,3], UInt8[4,5,6]]) == [UInt8[1,2,3], UInt8[4,5,6]]
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
        removeheader(req, "X")
        @test header(req, "X") == ""
        setheader(req, "X" => "Y")
    end

    @testset "Response" begin
        @test HTTP.Response(HTTP.Response(200).status).status == 200
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

    @testset "Header default" begin
        @test !hasheader(req, "Null")
        @test header(req, "Null") == ""
        @test header(req, "Null", nothing) === nothing
    end

    @testset "HTTP message parsing" begin
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

    @testset "Read methods" for method in http_reads
        @test isok(request(method, "https://$httpbin/ip", verbose=1))
    end

    @testset "Body - Response Stream" for method in http_writes
        uri = "https://$httpbin/$(lowercase(method))"
        r = request(method, uri, verbose=1)
        @test isok(r)
        r1 = JSON.parse(String(r.body))
        io = IOBuffer()
        r = request(method, uri, response_stream=io, verbose=1)
        seekstart(io)
        @test isok(r)
        r2 = JSON.parse(io)
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

    @testset "Body - JSON Parse" for method in http_writes
        uri = "https://$httpbin/$(lowercase(method))"
        io = IOBuffer()
        r = request(method, uri, response_stream=io, verbose=1)
        @test isok(r)

        r = request("POST",
            "https://$httpbin/post",
            ["Expect" => "100-continue"],
            "Hello",
            verbose=1)

        @test isok(r)
        r = JSON.parse(String(r.body))
        @test r["data"] == "Hello"
    end

    @testset "Write to file" begin
        cd(mktempdir()) do

            line_count = 0
            num_lines = 50
            open("result_file", "w") do io
                r = request("GET",
                    "https://$httpbin/stream/$num_lines",
                    response_stream=io,
                    verbose=1)
                @test isok(r)
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
        for body_show_max in (Messages.BODY_SHOW_MAX[], 100)
            Messages.set_show_max(body_show_max)
            @test repr(Response(200, []; body="Hello world.\n"*'x'^10000)) == "Response:\n\"\"\"\nHTTP/1.1 200 OK\r\n\r\nHello world.\n"*'x'^(body_show_max-13)*"\n⋮\n10013-byte body\n\"\"\""
        end

        # don't display raw binary (non-Unicode) data:
        @test repr(Response(200, []; body=String([0xde,0xad,0xc1,0x71,0x1c]))) == "Response:\n\"\"\"\nHTTP/1.1 200 OK\r\n\r\n\n⋮\n5-byte body\n\"\"\""

        # https://github.com/JuliaWeb/HTTP.jl/issues/828
        # don't include empty headers in request when writing
        @test repr(Request("GET", "/", ["Accept" => ""])) == "Request:\n\"\"\"\nGET / HTTP/1.1\r\n\r\n\"\"\""

        # Test that sensitive header values are masked when `show`ing HTTP.Request and HTTP.Response
        for H in ["Authorization", "Proxy-Authorization", "Cookie", "Set-Cookie"], h in (lowercase(H), H)
            req = HTTP.Request("GET", "https://xyz.com", [h => "secret", "User-Agent" => "HTTP.jl"])
            req_str = sprint(show, req)
            @test !occursin("secret", req_str)
            @test occursin("$h: ******", req_str)
            @test occursin("HTTP.jl", req_str)
            resp = HTTP.Response(200, [h => "secret", "Server" => "HTTP.jl"])
            resp_str = sprint(show, resp)
            @test !occursin("secret", resp_str)
            @test occursin("$h: ******", req_str)
            @test occursin("HTTP.jl", resp_str)
        end
    end

    @testset "queryparams" begin
        no_params = Request("GET", "http://google.com")
        with_params = Request("GET", "http://google.com?q=123&l=345")

        @test HTTP.queryparams(no_params) == Dict{String, String}()
        @test HTTP.queryparams(with_params) == Dict("q" => "123", "l" => "345")

        @test HTTP.queryparams(Response(200; body="", request=with_params)) == Dict("q" => "123", "l" => "345")
        @test isnothing(HTTP.queryparams(Response(200; body="")))
    end
end
