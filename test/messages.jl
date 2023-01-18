@testitem "Invalid headers" begin
    using HTTP.Messages: mkheaders
    @test_throws ArgumentError mkheaders(["hello"])
    @test_throws ArgumentError mkheaders([(1,2,3,4,5)])
    @test_throws ArgumentError mkheaders([1, 2])
    @test_throws ArgumentError mkheaders(["hello", "world"])
end

@testitem "Body Length" begin
    using HTTP: nbytes
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

@testitem "Body Bytes" begin
    using HTTP: bytes
    @test bytes(7) == 7
    @test bytes(UInt8[1,2,3]) == UInt8[1,2,3]
    @test bytes(view(UInt8[1,2,3], 1:2)) == UInt8[1,2]
    @test bytes("Hello") == codeunits("Hello")
    @test bytes(SubString("World!",1,5)) == codeunits("World")
    @test bytes(["Hello", " ", "World!"]) == ["Hello", " ", "World!"]
    @test bytes([UInt8[1,2,3], UInt8[4,5,6]]) == [UInt8[1,2,3], UInt8[4,5,6]]
end

@testitem "Request" begin
    using HTTP: header, removeheader, setheader
    req = HTTP.Request("GET", "/foo", ["Foo" => "Bar"])
    res = HTTP.Response(200, ["Content-Length" => "5"]; body="Hello", request=req)

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

@testitem "Response" begin
    @test HTTP.Response(HTTP.Response(200).status).status == 200
end

@testitem "Header Append" begin
    using HTTP: header, appendheader, hasheader, headercontains

    append_header(m, h) = appendheader(m, SubString(h[1]) => SubString(h[2]))
    req = HTTP.Request("GET", "/foo", ["Foo" => "Bar"])
    res = HTTP.Response(200, ["Content-Length" => "5"]; body="Hello", request=req)

    append_header(req, "X" => "Z")
    @test header(req, "X") == "Z"
    @test hasheader(req, "X", "Z")
    @test headercontains(req, "X", "Z")
    @test !headercontains(req, "X", "more")

    append_header(req, "X" => "more")
    @test header(req, "X") == "Z, more"
    @test hasheader(req, "X", "Z, more")
    @test headercontains(req, "X", "Z")
    @test headercontains(req, "X", "more")

    append_header(req, "Set-Cookie" => "A")
    append_header(req, "Set-Cookie" => "B")
    @test filter(x->first(x) == "Set-Cookie", req.headers) == ["Set-Cookie" => "A", "Set-Cookie" => "B"]
end

@testitem "Header default" begin
    using HTTP: hasheader, header
    req = HTTP.Request("GET", "/foo", ["Foo" => "Bar"])
    res = HTTP.Response(200, ["Content-Length" => "5"]; body="Hello", request=req)

    @test !hasheader(req, "Null")
    @test header(req, "Null") == ""
    @test header(req, "Null", nothing) === nothing
end

@testitem "HTTP message parsing" begin
    req = HTTP.Request("GET", "/foo", ["Foo" => "Bar"])
    res = HTTP.Response(200, ["Content-Length" => "5"]; body="Hello", request=req)

    raw = String(req)
    req = parse(HTTP.Request,raw)
    @test String(req) == raw

    req = parse(HTTP.Request, raw * "xxx")
    @test String(req) == raw

    raw = String(res)
    res = parse(HTTP.Response,raw)
    @test String(res) == raw

    res = parse(HTTP.Response,raw * "xxx")
    @test String(res) == raw
end

@testitem "Read methods" setup=[Common] begin
    @testset for method in ("GET", "HEAD", "OPTIONS")
        @test isok(HTTP.request(method, "https://$httpbin/ip", verbose=1))
    end
end

@testitem "Body - Response Stream" setup=[Common] begin
    using JSON
    @testset for method in ("POST", "PUT", "DELETE", "PATCH")
        uri = "https://$httpbin/$(lowercase(method))"
        r = HTTP.request(method, uri, verbose=1)
        @test isok(r)
        r1 = JSON.parse(String(r.body))
        io = IOBuffer()
        r = HTTP.request(method, uri, response_stream=io, verbose=1)
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
end

@testitem "Body - JSON Parse" setup=[Common] begin
    using JSON
    @testset for method in ("POST", "PUT", "DELETE", "PATCH")
        uri = "https://$httpbin/$(lowercase(method))"
        io = IOBuffer()
        r = HTTP.request(method, uri, response_stream=io, verbose=1)
        @test isok(r)

        r = HTTP.request("POST",
            "https://$httpbin/post",
            ["Expect" => "100-continue"],
            "Hello",
            verbose=1)

        @test isok(r)
        r = JSON.parse(String(r.body))
        @test r["data"] == "Hello"
    end
end

@testitem "Write to file" setup=[Common] begin
    using JSON

    cd(mktempdir()) do
        line_count = 0
        num_lines = 50
        open("result_file", "w") do io
            r = HTTP.request("GET",
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

@testitem "Display" begin
    using HTTP: Messages, Request, Response

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
end
