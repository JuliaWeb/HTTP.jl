include("resources/TestRequest.jl")
using ..TestRequest
using HTTP
using JSON
using Test

status(r) = r.status
@testset "Custom HTTP Stack" begin
   @testset "Low-level Request" begin
        custom_stack = insert(stack(), StreamLayer, TestLayer)
        result = request(custom_stack, "GET", "https://httpbin.org/ip")

        @test status(result) == 200
    end
end

@testset "Client.jl - $sch" for sch in ["http", "https"]
    @testset "GET, HEAD, POST, PUT, DELETE, PATCH" begin
        @test status(HTTP.get("$sch://httpbin.org/ip")) == 200
        @test status(HTTP.head("$sch://httpbin.org/ip")) == 200
        @test status(HTTP.post("$sch://httpbin.org/ip"; status_exception=false)) == 405
        @test status(HTTP.post("$sch://httpbin.org/post")) == 200
        @test status(HTTP.put("$sch://httpbin.org/put")) == 200
        @test status(HTTP.delete("$sch://httpbin.org/delete")) == 200
        @test status(HTTP.patch("$sch://httpbin.org/patch")) == 200
    end

    @testset "ASync Client Requests" begin
        @test status(fetch(@async HTTP.get("$sch://httpbin.org/ip"))) == 200
        @test status(HTTP.get("$sch://httpbin.org/encoding/utf8")) == 200
    end

    @testset "Query to URI" begin
        r = HTTP.get(merge(HTTP.URI("$sch://httpbin.org/response-headers"); query=Dict("hey"=>"dude")))
        h = Dict(r.headers)
        @test (haskey(h, "Hey") ? h["Hey"] == "dude" : h["hey"] == "dude")
    end

    @testset "Cookie Requests" begin
        empty!(HTTP.CookieRequest.default_cookiejar[1])
        r = HTTP.get("$sch://httpbin.org/cookies", cookies=true)

        body = String(r.body)
        @test replace(replace(body, " "=>""), "\n"=>"")  == "{\"cookies\":{}}"

        r = HTTP.get("$sch://httpbin.org/cookies/set?hey=sailor&foo=bar", cookies=true)
        @test status(r) == 200

        body = String(r.body)
        @test replace(replace(body, " "=>""), "\n"=>"")  == "{\"cookies\":{\"foo\":\"bar\",\"hey\":\"sailor\"}}"

        r = HTTP.get("$sch://httpbin.org/cookies/delete?hey")
        @test isempty(JSON.parse(String(r.body))["cookies"])
    end

    @testset "Client Streaming Test" begin
        r = HTTP.post("$sch://httpbin.org/post"; body="hey")
        @test status(r) == 200

        # stream, but body is too small to actually stream
        r = HTTP.post("$sch://httpbin.org/post"; body="hey", stream=true)
        @test status(r) == 200

        r = HTTP.get("$sch://httpbin.org/stream/100")
        @test status(r) == 200

        bytes = r.body
        a = [JSON.parse(l) for l in split(chomp(String(bytes)), "\n")]
        totallen = length(bytes) # number of bytes to expect

        io = Base.BufferStream()
        r = HTTP.get("$sch://httpbin.org/stream/100"; response_stream=io)
        @test status(r) == 200

        b = [JSON.parse(l) for l in eachline(io)]
        @test all(zip(a, b)) do (x, y)
            x["args"] == y["args"] &&
            x["id"] == y["id"] &&
            x["url"] == y["url"] &&
            x["origin"] == y["origin"] &&
            x["headers"]["Content-Length"] == y["headers"]["Content-Length"] &&
            x["headers"]["Host"] == y["headers"]["Host"] &&
            x["headers"]["User-Agent"] == y["headers"]["User-Agent"]
        end
    end

    @testset "Client Body Posting - Vector{UTF8}, String, IOStream, IOBuffer, BufferStream" begin
        @test status(HTTP.post("$sch://httpbin.org/post"; body="hey")) == 200
        @test status(HTTP.post("$sch://httpbin.org/post"; body=UInt8['h','e','y'])) == 200
        io = IOBuffer("hey"); seekstart(io)
        @test status(HTTP.post("$sch://httpbin.org/post"; body=io)) == 200
        tmp = tempname()
        open(f->write(f, "hey"), tmp, "w")
        io = open(tmp)
        @test status(HTTP.post("$sch://httpbin.org/post"; body=io, enablechunked=false)) == 200
        close(io); rm(tmp)
        f = Base.BufferStream()
        write(f, "hey")
        close(f)
        @test status(HTTP.post("$sch://httpbin.org/post"; body=f, enablechunked=false)) == 200
    end

    @testset "Chunksize" begin
        #     https://github.com/JuliaWeb/HTTP.jl/issues/60
        #     Currently httpbin.org responds with 411 status and “Length Required”
        #     message to any POST/PUT requests that are sent using chunked encoding
        #     See https://github.com/kennethreitz/httpbin/issues/340#issuecomment-330176449
        println("client transfer-encoding chunked")
        @test status(HTTP.post("$sch://httpbin.org/post"; body="hey", #=chunksize=2=#)) == 200
        @test status(HTTP.post("$sch://httpbin.org/post"; body=UInt8['h','e','y'], #=chunksize=2=#)) == 200
        io = IOBuffer("hey"); seekstart(io)
        @test status(HTTP.post("$sch://httpbin.org/post"; body=io, #=chunksize=2=#)) == 200
        tmp = tempname()
        open(f->write(f, "hey"), tmp, "w")
        io = open(tmp)
        @test status(HTTP.post("$sch://httpbin.org/post"; body=io, #=chunksize=2=#)) == 200
        close(io); rm(tmp)
        f = Base.BufferStream()
        write(f, "hey")
        close(f)
        @test status(HTTP.post("$sch://httpbin.org/post"; body=f, #=chunksize=2=#)) == 200
    end

    @testset "ASync Client Request Body" begin
        f = Base.BufferStream()
        write(f, "hey")
        t = @async HTTP.post("$sch://httpbin.org/post"; body=f, enablechunked=false)
        #fetch(f) # fetch for the async call to write it's first data
        write(f, " there ") # as we write to f, it triggers another chunk to be sent in our async request
        write(f, "sailor")
        close(f) # setting eof on f causes the async request to send a final chunk and return the response
        @test status(fetch(t)) == 200
    end

    @testset "Client Redirect Following - $read_method" for read_method in ["GET", "HEAD"]
        @test status(HTTP.request(read_method, "$sch://httpbin.org/redirect/1")) ==200
        @test status(HTTP.request(read_method, "$sch://httpbin.org/redirect/1", redirect=false)) == 302
        @test status(HTTP.request(read_method, "$sch://httpbin.org/redirect/6")) == 302 #over max number of redirects
        @test status(HTTP.request(read_method, "$sch://httpbin.org/relative-redirect/1")) == 200
        @test status(HTTP.request(read_method, "$sch://httpbin.org/absolute-redirect/1")) == 200
        @test status(HTTP.request(read_method, "$sch://httpbin.org/redirect-to?url=http%3A%2F%2Fgoogle.com")) == 200
    end

    @testset "Client Basic Auth" begin
        @test status(HTTP.get("$sch://user:pwd@httpbin.org/basic-auth/user/pwd")) == 200
        @test status(HTTP.get("$sch://user:pwd@httpbin.org/hidden-basic-auth/user/pwd")) == 200
        @test status(HTTP.get("$sch://test:%40test@httpbin.org/basic-auth/test/%40test")) == 200
    end

    @testset "Misc" begin
        @test status(HTTP.post("$sch://httpbin.org/post"; body="√")) == 200
        r = HTTP.request("GET", "$sch://httpbin.org/ip")
        @test status(r) == 200

        uri = HTTP.URI("$sch://httpbin.org/ip")
        r = HTTP.request("GET", uri)
        @test status(r) == 200
        r = HTTP.get(uri)
        @test status(r) == 200

        r = HTTP.request("GET", "$sch://httpbin.org/ip")
        @test status(r) == 200

        uri = HTTP.URI("$sch://httpbin.org/ip")
        r = HTTP.request("GET", uri)
        @test status(r) == 200

        r = HTTP.get("$sch://httpbin.org/image/png")
        @test status(r) == 200

        # ensure we can use AbstractString for requests
        r = HTTP.get(SubString("http://httpbin.org/ip",1))

        # canonicalizeheaders
        @test status(HTTP.get("$sch://httpbin.org/ip"; canonicalizeheaders=false)) == 200
    end

    @testset "openraw client method - $socket_protocol" for socket_protocol in ["wss", "ws"]
        # WebSockets require valid headers.
        headers = Dict(
            "Upgrade" => "websocket",
            "Connection" => "Upgrade",
            "Sec-WebSocket-Key" => "dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version" => "13")

        socket, response = HTTP.openraw("GET", "$sch://echo.websocket.org", headers)

        @test response.status == 101

        # This is an example text frame from RFC 6455, section 5.7. It sends the text "Hello" to the
        # echo server, and so we expect "Hello" back, in an unmasked frame.
        frame = UInt8[0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]

        write(socket, frame)

        # The frame we expect back looks like `expectedframe`.
        expectedframe = UInt8[0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f]

        # Note the spec for read says:
        #     read(s::IO, nb=typemax(Int))
        # Read at most nb bytes from s, returning a Vector{UInt8} of the bytes read.
        # ... so read will return less than 7 bytes unless we wait first:
        eof(socket)
        actualframe = read(socket, 7)
        @test expectedframe == actualframe

        close(socket)
    end
end

@testset "HTTP.open accepts method::Symbol" begin
    @test status(HTTP.open(x -> x, :GET, "http://httpbin.org/ip")) == 200
end

@testset "Public entry point of HTTP.request and friends (e.g. issue #463)" begin
    headers = Dict("User-Agent" => "HTTP.jl")
    query = Dict("hello" => "world")
    body = UInt8[1, 2, 3]
    stack = HTTP.stack()
    function test(r, m)
        @test r.status == 200
        d = JSON.parse(IOBuffer(HTTP.payload(r)))
        @test d["headers"]["User-Agent"] == "HTTP.jl"
        @test d["data"] == "\x01\x02\x03"
        @test endswith(d["url"], "?hello=world")
        @test d["method"] == m
    end
    for uri in ("https://httpbin.org/anything", HTTP.URI("https://httpbin.org/anything"))
        # HTTP.request
        test(HTTP.request("GET", uri; headers=headers, body=body, query=query), "GET")
        test(HTTP.request("GET", uri, headers; body=body, query=query), "GET")
        test(HTTP.request("GET", uri, headers, body; query=query), "GET")
        !isa(uri, HTTP.URI) && test(HTTP.request(stack, "GET", uri; headers=headers, body=body, query=query), "GET")
        test(HTTP.request(stack, "GET", uri, headers; body=body, query=query), "GET")
        test(HTTP.request(stack, "GET", uri, headers, body; query=query), "GET")
        # HTTP.get
        test(HTTP.get(uri; headers=headers, body=body, query=query), "GET")
        test(HTTP.get(uri, headers; body=body, query=query), "GET")
        test(HTTP.get(uri, headers, body; query=query), "GET")
        # HTTP.put
        test(HTTP.put(uri; headers=headers, body=body, query=query), "PUT")
        test(HTTP.put(uri, headers; body=body, query=query), "PUT")
        test(HTTP.put(uri, headers, body; query=query), "PUT")
        # HTTP.post
        test(HTTP.post(uri; headers=headers, body=body, query=query), "POST")
        test(HTTP.post(uri, headers; body=body, query=query), "POST")
        test(HTTP.post(uri, headers, body; query=query), "POST")
        # HTTP.patch
        test(HTTP.patch(uri; headers=headers, body=body, query=query), "PATCH")
        test(HTTP.patch(uri, headers; body=body, query=query), "PATCH")
        test(HTTP.patch(uri, headers, body; query=query), "PATCH")
        # HTTP.delete
        test(HTTP.delete(uri; headers=headers, body=body, query=query), "DELETE")
        test(HTTP.delete(uri, headers; body=body, query=query), "DELETE")
        test(HTTP.delete(uri, headers, body; query=query), "DELETE")
    end
end
