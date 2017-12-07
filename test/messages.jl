
using HTTP.Messages

using JSON

@testset "HTTP.Messages" begin

    req = Request("GET", "/foo", ["Foo" => "Bar"])
    res = Response(200, ["Content-Length" => "5"]; body=Body("Hello"), parent=req)

    @test req.method == "GET"
    @test method(res) == "GET"

    #display(req); println()
    #display(res); println()

    @test String(req) == "GET /foo HTTP/1.1\r\nFoo: Bar\r\n\r\n"
    @test String(res) == "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHello"

    @test header(req, "Foo") == "Bar"
    @test header(res, "Content-Length") == "5"
    setheader(req, "X" => "Y")
    @test header(req, "X") == "Y"

    HTTP.Messages.appendheader(req, "" => "Z")
    @test header(req, "X") == "YZ"

    HTTP.Messages.appendheader(req, "X" => "more")
    @test header(req, "X") == "YZ, more"

    HTTP.Messages.appendheader(req, "Set-Cookie" => "A")
    HTTP.Messages.appendheader(req, "Set-Cookie" => "B")
    @test filter(x->first(x) == "Set-Cookie", req.headers) == 
        ["Set-Cookie" => "A", "Set-Cookie" => "B"]

    @test HTTP.Messages.httpversion(req) == "HTTP/1.1"
    @test HTTP.Messages.httpversion(res) == "HTTP/1.1"

    raw = String(req)
    #@show raw
    req = Request()
    read!(IOBuffer(raw), req) 
    #display(req); println()
    @test String(req) == raw

    req = Request()
    read!(IOBuffer(raw * "xxx"), req) 
    @test String(req) == raw

    raw = String(res)
    #@show raw
    res = Response()
    read!(IOBuffer(raw), res) 
    #display(res); println()
    @test String(res) == raw

    res = Response()
    read!(IOBuffer(raw * "xxx"), res) 
    @test String(res) == raw

    for sch in ["http", "https"]
        for m in ["GET", "HEAD", "OPTIONS"]
            @test request(m, "$sch://httpbin.org/ip").status == 200
        end
        @test request("POST", "$sch://httpbin.org/ip").status == 405
    end

    for sch in ["http", "https"]
        for m in ["POST", "PUT", "DELETE", "PATCH"]

            uri = "$sch://httpbin.org/$(lowercase(m))"
            r = request(m, uri)
            @test r.status == 200
            body = take!(r.body)

            io = BufferStream()
            r = request(m, uri, response_stream=io)
            @test r.status == 200
            @test read(io) == body
        end
    end
    for sch in ["http", "https"]
        for m in ["POST", "PUT", "DELETE", "PATCH"]

            uri = "$sch://httpbin.org/$(lowercase(m))"
            io = BufferStream()
            r = request(m, uri, response_stream=io)
            @test r.status == 200
        end
    end

    for sch in ["http", "https"]

        log_buffer = Vector{String}()

        function log(s::String)
            println(s)
            push!(log_buffer, s)
        end

        function async_get(url)
            io = BufferStream()
            q = HTTP.query(HTTP.URI(url))
            log("GET $q")
            r = request("GET", url, response_stream=io)
            @async begin
                s = String(read(io))
                s = split(s, "\n")[end-1]
                x = JSON.parse(s)
                log("GOT $q: $(x["args"]["req"])")
            end
        end

        @sync begin
            async_get("$sch://httpbin.org/stream/100?req=1")
            async_get("$sch://httpbin.org/stream/100?req=2")
            async_get("$sch://httpbin.org/stream/100?req=3")
            async_get("$sch://httpbin.org/stream/100?req=4")
            async_get("$sch://httpbin.org/stream/100?req=5")
        end

        @test log_buffer == ["GET req=1",
                             "GET req=2",
                             "GOT req=1: 1",
                             "GET req=3",
                             "GOT req=2: 2",
                             "GET req=4",
                             "GOT req=3: 3",
                             "GET req=5",
                             "GOT req=4: 4",
                             "GOT req=5: 5"]

    end


    mktempdir() do d
        cd(d) do

            n = 50
            io = open("result_file", "w")
            r = request("GET", "http://httpbin.org/stream/$n",
                        response_stream=io)
            @test stat("result_file").size == 0
            while stat("result_file").size <= 1000
                sleep(0.1)
            end
            @test stat("result_file").size > 1000
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
