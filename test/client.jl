module TestClient

using HTTP, HTTP.Exceptions, MbedTLS, OpenSSL
include(joinpath(dirname(pathof(HTTP)), "../test/resources/TestRequest.jl"))
using .TestRequest
using .TestRequest2
using Sockets
using JSON
using Test
using URIs

status(r) = r.status
@testset "Custom HTTP Stack" begin
   @testset "Low-level Request" begin
        wasincluded = Ref(false)
        result = TestRequest.get("https://httpbin.org/ip"; httptestlayer=wasincluded)
        @test status(result) == 200
        @test wasincluded[]
    end
    @testset "Low-level Request" begin
        TestRequest2.get("https://httpbin.org/ip")
        # tests included in the layers themselves
    end
end

@testset "Client.jl - $sch" for sch in ["http", "https"], tls in [MbedTLS.SSLContext, OpenSSL.SSLSTream]
    @testset "GET, HEAD, POST, PUT, DELETE, PATCH" begin
        @test status(HTTP.get("$sch://httpbin.org/ip", socket_type_tls=tls)) == 200
        @test status(HTTP.head("$sch://httpbin.org/ip", socket_type_tls=tls)) == 200
        @test status(HTTP.post("$sch://httpbin.org/ip"; status_exception=false, socket_type_tls=tls)) == 405
        @test status(HTTP.post("$sch://httpbin.org/post", socket_type_tls=tls)) == 200
        @test status(HTTP.put("$sch://httpbin.org/put", socket_type_tls=tls)) == 200
        @test status(HTTP.delete("$sch://httpbin.org/delete", socket_type_tls=tls)) == 200
        @test status(HTTP.patch("$sch://httpbin.org/patch", socket_type_tls=tls)) == 200
    end

    @testset "decompress" begin
        r = HTTP.get("$sch://httpbin.org/gzip", socket_type_tls=tls)
        @test status(r) == 200
        @test isascii(String(r.body))
        r = HTTP.get("$sch://httpbin.org/gzip"; decompress=false, socket_type_tls=tls)
        @test status(r) == 200
        @test !isascii(String(r.body))
        r = HTTP.get("$sch://httpbin.org/gzip"; decompress=false, socket_type_tls=tls)
        @test isascii(String(HTTP.decode(r, "gzip")))
    end

    @testset "ASync Client Requests" begin
        @test status(fetch(@async HTTP.get("$sch://httpbin.org/ip", socket_type_tls=tls))) == 200
        @test status(HTTP.get("$sch://httpbin.org/encoding/utf8", socket_type_tls=tls)) == 200
    end

    @testset "Query to URI" begin
        r = HTTP.get(URI(HTTP.URI("$sch://httpbin.org/response-headers"); query=Dict("hey"=>"dude")))
        h = Dict(r.headers)
        @test (haskey(h, "Hey") ? h["Hey"] == "dude" : h["hey"] == "dude")
    end

    @testset "Cookie Requests" begin
        empty!(HTTP.COOKIEJAR)
        r = HTTP.get("$sch://httpbin.org/cookies", cookies=true, socket_type_tls=tls)

        body = String(r.body)
        @test replace(replace(body, " "=>""), "\n"=>"")  == "{\"cookies\":{}}"

        r = HTTP.get("$sch://httpbin.org/cookies/set?hey=sailor&foo=bar", cookies=true, socket_type_tls=tls)
        @test status(r) == 200

        body = String(r.body)
        @test replace(replace(body, " "=>""), "\n"=>"")  == "{\"cookies\":{\"foo\":\"bar\",\"hey\":\"sailor\"}}"

        r = HTTP.get("$sch://httpbin.org/cookies/delete?hey", socket_type_tls=tls)
        cookies = JSON.parse(String(r.body))["cookies"]
        @test length(cookies) == 1
        @test cookies["foo"] == "bar"
    end

    @testset "Client Streaming Test" begin
        r = HTTP.post("$sch://httpbin.org/post"; body="hey", socket_type_tls=tls)
        @test status(r) == 200

        # stream, but body is too small to actually stream
        r = HTTP.post("$sch://httpbin.org/post"; body="hey", stream=true, socket_type_tls=tls)
        @test status(r) == 200

        r = HTTP.get("$sch://httpbin.org/stream/100", socket_type_tls=tls)
        @test status(r) == 200

        bytes = r.body
        a = [JSON.parse(l) for l in split(chomp(String(bytes)), "\n")]
        totallen = length(bytes) # number of bytes to expect

        io = IOBuffer()
        r = HTTP.get("$sch://httpbin.org/stream/100"; response_stream=io, socket_type_tls=tls)
        seekstart(io)
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

    @testset "Client Body Posting - Vector{UTF8}, String, IOStream, IOBuffer, BufferStream, Dict, NamedTuple" begin
        @test status(HTTP.post("$sch://httpbin.org/post"; body="hey", socket_type_tls=tls)) == 200
        @test status(HTTP.post("$sch://httpbin.org/post"; body=UInt8['h','e','y'], socket_type_tls=tls)) == 200
        io = IOBuffer("hey"); seekstart(io)
        @test status(HTTP.post("$sch://httpbin.org/post"; body=io, socket_type_tls=tls)) == 200
        tmp = tempname()
        open(f->write(f, "hey"), tmp, "w")
        io = open(tmp)
        @test status(HTTP.post("$sch://httpbin.org/post"; body=io, enablechunked=false, socket_type_tls=tls)) == 200
        close(io); rm(tmp)
        f = Base.BufferStream()
        write(f, "hey")
        close(f)
        @test status(HTTP.post("$sch://httpbin.org/post"; body=f, enablechunked=false, socket_type_tls=tls)) == 200
        resp = HTTP.post("$sch://httpbin.org/post"; body=Dict("name" => "value"), socket_type_tls=tls)
        x = JSON.parse(IOBuffer(resp.body))
        @test status(resp) == 200
        @test x["form"] == Dict("name" => "value")
        resp = HTTP.post("$sch://httpbin.org/post"; body=(name="value with spaces",), socket_type_tls=tls)
        x = JSON.parse(IOBuffer(resp.body))
        @test status(resp) == 200
        @test x["form"] == Dict("name" => "value with spaces")
    end

    @testset "Chunksize" begin
        #     https://github.com/JuliaWeb/HTTP.jl/issues/60
        #     Currently httpbin.org responds with 411 status and “Length Required”
        #     message to any POST/PUT requests that are sent using chunked encoding
        #     See https://github.com/kennethreitz/httpbin/issues/340#issuecomment-330176449
        @test status(HTTP.post("$sch://httpbin.org/post"; body="hey", socket_type_tls=tls, #=chunksize=2=#)) == 200
        @test status(HTTP.post("$sch://httpbin.org/post"; body=UInt8['h','e','y'], socket_type_tls=tls, #=chunksize=2=#)) == 200
        io = IOBuffer("hey"); seekstart(io)
        @test status(HTTP.post("$sch://httpbin.org/post"; body=io, socket_type_tls=tls, #=chunksize=2=#)) == 200
        tmp = tempname()
        open(f->write(f, "hey"), tmp, "w")
        io = open(tmp)
        @test status(HTTP.post("$sch://httpbin.org/post"; body=io, socket_type_tls=tls, #=chunksize=2=#)) == 200
        close(io); rm(tmp)
        f = Base.BufferStream()
        write(f, "hey")
        close(f)
        @test status(HTTP.post("$sch://httpbin.org/post"; body=f, socket_type_tls=tls, #=chunksize=2=#)) == 200
    end

    @testset "ASync Client Request Body" begin
        f = Base.BufferStream()
        write(f, "hey")
        t = @async HTTP.post("$sch://httpbin.org/post"; body=f, enablechunked=false, socket_type_tls=tls)
        #fetch(f) # fetch for the async call to write it's first data
        write(f, " there ") # as we write to f, it triggers another chunk to be sent in our async request
        write(f, "sailor")
        close(f) # setting eof on f causes the async request to send a final chunk and return the response
        @test status(fetch(t)) == 200
    end

    @testset "Client Redirect Following - $read_method" for read_method in ["GET", "HEAD"]
        @test status(HTTP.request(read_method, "$sch://httpbin.org/redirect/1", socket_type_tls=tls)) ==200
        @test status(HTTP.request(read_method, "$sch://httpbin.org/redirect/1", redirect=false, socket_type_tls=tls)) == 302
        @test status(HTTP.request(read_method, "$sch://httpbin.org/redirect/6", socket_type_tls=tls)) == 302 #over max number of redirects
        @test status(HTTP.request(read_method, "$sch://httpbin.org/relative-redirect/1", socket_type_tls=tls)) == 200
        @test status(HTTP.request(read_method, "$sch://httpbin.org/absolute-redirect/1", socket_type_tls=tls)) == 200
        @test status(HTTP.request(read_method, "$sch://httpbin.org/redirect-to?url=http%3A%2F%2Fgoogle.com", socket_type_tls=tls)) == 200
    end

    @testset "Client Basic Auth" begin
        @test status(HTTP.get("$sch://user:pwd@httpbin.org/basic-auth/user/pwd", socket_type_tls=tls)) == 200
        @test status(HTTP.get("$sch://user:pwd@httpbin.org/hidden-basic-auth/user/pwd", socket_type_tls=tls)) == 200
        @test status(HTTP.get("$sch://test:%40test@httpbin.org/basic-auth/test/%40test", socket_type_tls=tls)) == 200
    end

    @testset "Misc" begin
        @test status(HTTP.post("$sch://httpbin.org/post"; body="√", socket_type_tls=tls)) == 200
        r = HTTP.request("GET", "$sch://httpbin.org/ip", socket_type_tls=tls)
        @test status(r) == 200

        uri = HTTP.URI("$sch://httpbin.org/ip", socket_type_tls=tls)
        r = HTTP.request("GET", uri)
        @test status(r) == 200
        r = HTTP.get(uri)
        @test status(r) == 200

        r = HTTP.request("GET", "$sch://httpbin.org/ip", socket_type_tls=tls)
        @test status(r) == 200

        uri = HTTP.URI("$sch://httpbin.org/ip", socket_type_tls=tls)
        r = HTTP.request("GET", uri)
        @test status(r) == 200

        r = HTTP.get("$sch://httpbin.org/image/png", socket_type_tls=tls)
        @test status(r) == 200

        # ensure we can use AbstractString for requests
        r = HTTP.get(SubString("$sch://httpbin.org/ip",1), socket_type_tls=tls)

        # canonicalizeheaders
        @test status(HTTP.get("$sch://httpbin.org/ip"; canonicalizeheaders=false, socket_type_tls=tls)) == 200
    end
end

@testset "Incomplete response with known content length" begin
    server = nothing
    try
        server = HTTP.listen!("0.0.0.0", 8080) do http
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Length" => "64") # Promise 64 bytes...
            HTTP.startwrite(http)
            HTTP.write(http, rand(UInt8, 63)) # ...but only send 63 bytes.
            # Close the stream so that eof(stream) is true and the client isn't
            # waiting forever for the last byte.
            HTTP.close(http.stream)
        end

        err = try
            HTTP.get("http://localhost:8080"; retry=false)
        catch err
            err
        end
        @test err isa HTTP.RequestError
        @test err.error isa EOFError
    finally
        # Shutdown
        @try Base.IOError close(server)
        HTTP.ConnectionPool.closeall()
    end
end

if !isempty(get(ENV, "PIE_SOCKET_API_KEY", "")) && get(ENV, "JULIA_VERSION", "") == "1"
    println("found pie socket api key, running websocket tests")
    pie_socket_api_key = ENV["PIE_SOCKET_API_KEY"]
    @testset "openraw client method - $socket_protocol" for socket_protocol in ["wss", "ws"]
        # WebSockets require valid headers.
        headers = Dict(
            "Upgrade" => "websocket",
            "Connection" => "Upgrade",
            "Sec-WebSocket-Key" => "dGhlIHNhbXBsZSBub25jZQ==",
            "Sec-WebSocket-Version" => "13")

        socket, response = HTTP.openraw("GET", "$socket_protocol://free3.piesocket.com/v3/http_test_channel?api_key=$pie_socket_api_key&notify_self", headers)

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

@testset "readtimeout" begin
    @test_throws HTTP.TimeoutError begin
        HTTP.get("http://httpbin.org/delay/5"; readtimeout=1, retry=false)
    end
    HTTP.get("http://httpbin.org/delay/1"; readtimeout=2, retry=false)
end

@testset "Retry all resolved IP addresses" begin
    # See issue https://github.com/JuliaWeb/HTTP.jl/issues/672
    # Bit tricky to test, but can at least be tested if localhost
    # resolves to both IPv4 and IPv6 by listening to the respective
    # interface
    alladdrs = getalladdrinfo("localhost")
    if ip"127.0.0.1" in alladdrs && ip"::1" in alladdrs
        for interface in (IPv4(0), IPv6(0))
            server = nothing
            try
                server = HTTP.listen!(string(interface), 8080) do http
                    HTTP.setstatus(http, 200)
                    HTTP.startwrite(http)
                    HTTP.write(http, "hello, world")
                end
                req = HTTP.get("http://localhost:8080")
                @test req.status == 200
                @test String(req.body) == "hello, world"
            finally
                @try Base.IOError close(server)
                HTTP.ConnectionPool.closeall()
            end
        end
    end
end

@testset "Sockets.get(sock|peer)name(::HTTP.Stream)" begin
    server = nothing
    try
        server = HTTP.listen!("0.0.0.0", 8080) do http
            sock = Sockets.getsockname(http)
            peer = Sockets.getpeername(http)
            str = sprint() do io
                print(io, sock[1], ":", sock[2], " - ", peer[1], ":", peer[2])
            end
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Length" => string(sizeof(str)))
            HTTP.startwrite(http)
            HTTP.write(http, str)
        end

        # Tests for Stream{TCPSocket}
        HTTP.open("GET", "http://localhost:8080") do http
            # Test server peer/sock
            reg = r"^127\.0\.0\.1:8080 - 127\.0\.0\.1:(\d+)$"
            m = match(reg, read(http, String))
            @test m !== nothing
            server_peerport = parse(Int, m[1])
            # Test client peer/sock
            sock = Sockets.getsockname(http)
            @test sock[1] == ip"127.0.0.1"
            @test sock[2] == server_peerport
            peer = Sockets.getpeername(http)
            @test peer[1] == ip"127.0.0.1"
            @test peer[2] == 8080
        end
    finally
        @try Base.IOError close(server)
        HTTP.ConnectionPool.closeall()
    end

    # Tests for Stream{SSLContext}
    HTTP.open("GET", "https://julialang.org") do http
        sock = Sockets.getsockname(http)
        if VERSION >= v"1.2.0"
            @test sock[1] in Sockets.getipaddrs()
        end
        peer = Sockets.getpeername(http)
        @test peer[1] in Sockets.getalladdrinfo("julialang.org")
        @test peer[2] == 443
    end
end

@testset "input verification of bad URLs" begin
    # HTTP.jl#527, HTTP.jl#545
    url = "julialang.org"
    @test_throws ArgumentError("missing or unsupported scheme in URL (expected http(s) or ws(s)): $(url)") HTTP.get(url)
    url = "ptth://julialang.org"
    @test_throws ArgumentError("missing or unsupported scheme in URL (expected http(s) or ws(s)): $(url)") HTTP.get(url)
    url = "http:julialang.org"
    @test_throws ArgumentError("missing host in URL: $(url)") HTTP.get(url)
end

@testset "Implicit request headers" begin
    server = nothing
    try
        server = HTTP.listen!("0.0.0.0", 8080) do http
            data = Dict{String,String}(http.message.headers)
            HTTP.setstatus(http, 200)
            HTTP.startwrite(http)
            HTTP.write(http, sprint(JSON.print, data))
        end
        old_user_agent = HTTP.DefaultHeadersRequest.USER_AGENT[]
        default_user_agent = "HTTP.jl/$VERSION"
        # Default values
        HTTP.setuseragent!(default_user_agent)
        d = JSON.parse(IOBuffer(HTTP.get("http://localhost:8080").body))
        @test d["Host"] == "localhost:8080"
        @test d["Accept"] == "*/*"
        @test d["User-Agent"] == default_user_agent
        # Overwriting behavior
        headers = ["Host" => "http.jl", "Accept" => "application/json"]
        HTTP.setuseragent!("HTTP.jl test")
        d = JSON.parse(IOBuffer(HTTP.get("http://localhost:8080", headers).body))
        @test d["Host"] == "http.jl"
        @test d["Accept"] == "application/json"
        @test d["User-Agent"] == "HTTP.jl test"
        # No User-Agent
        HTTP.setuseragent!(nothing)
        d = JSON.parse(IOBuffer(HTTP.get("http://localhost:8080").body))
        @test !haskey(d, "User-Agent")

        HTTP.setuseragent!(old_user_agent)
    finally
        @try Base.IOError close(server)
        HTTP.ConnectionPool.closeall()
    end
end

import NetworkOptions, MbedTLS
@testset "NetworkOptions for host verification" begin
    # Set up server with self-signed cert
    server = nothing
    try
        cert, key = joinpath.(dirname(pathof(HTTP)), "../test", "resources", ("cert.pem", "key.pem"))
        sslconfig = MbedTLS.SSLConfig(cert, key)
        server = HTTP.listen!("0.0.0.0", 8443; sslconfig=sslconfig) do http
            HTTP.setstatus(http, 200)
            HTTP.startwrite(http)
            HTTP.write(http, "hello, world")
        end
        url = "https://localhost:8443"
        env = ["JULIA_NO_VERIFY_HOSTS" => nothing, "JULIA_SSL_NO_VERIFY_HOSTS" => nothing, "JULIA_ALWAYS_VERIFY_HOSTS" => nothing]
        withenv(env...) do
            @test NetworkOptions.verify_host(url)
            @test NetworkOptions.verify_host(url, "SSL")
            @test_throws HTTP.ConnectError HTTP.get(url; retries=1)
            @test_throws HTTP.ConnectError HTTP.get(url; require_ssl_verification=true, retries=1)
            @test HTTP.get(url; require_ssl_verification=false).status == 200
        end
        withenv(env..., "JULIA_NO_VERIFY_HOSTS" => "localhost") do
            @test !NetworkOptions.verify_host(url)
            @test !NetworkOptions.verify_host(url, "SSL")
            @test HTTP.get(url).status == 200
            @test_throws HTTP.ConnectError HTTP.get(url; require_ssl_verification=true, retries=1)
            @test HTTP.get(url; require_ssl_verification=false).status == 200
        end
        withenv(env..., "JULIA_SSL_NO_VERIFY_HOSTS" => "localhost") do
            @test NetworkOptions.verify_host(url)
            @test !NetworkOptions.verify_host(url, "SSL")
            @test HTTP.get(url).status == 200
            @test_throws HTTP.ConnectError HTTP.get(url; require_ssl_verification=true, retries=1)
            @test HTTP.get(url; require_ssl_verification=false).status == 200
        end
    finally
        @try Base.IOError close(server)
        HTTP.ConnectionPool.closeall()
    end
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

@testset "HTTP CONNECT Proxy" begin
    @testset "Host header" begin
        # Stores the http request passed by the client
        req = String[]

        # Trivial implementation of a proxy server
        # We are only interested in the request passed in by the client
        # Returns 400 after reading the http request into req
        proxy = listen(IPv4(0), 8082)
        try
            @async begin
                sock = accept(proxy)
                while isopen(sock)
                    line = readline(sock)
                    isempty(line) && break

                    push!(req, line)
                end
                write(sock, "HTTP/1.1 400 Bad Request\r\n\r\n")
            end

            # Make the HTTP request
            HTTP.get("https://example.com"; proxy="http://localhost:8082", retry=false, status_exception=false)

            # Test if the host header exist in the request
            @test "Host: example.com:443" in req
        finally
            close(proxy)
            HTTP.ConnectionPool.closeall()
        end
    end
end

@testset "Retry with request/response body streams" begin
    shouldfail = Ref(true)
    server = HTTP.listen!(8080) do http
        @assert !eof(http)
        msg = String(read(http))
        if shouldfail[]
            shouldfail[] = false
            error("500 unexpected error")
        end
        HTTP.startwrite(http)
        HTTP.write(http, msg)
    end
    try
        req_body = IOBuffer("hey there sailor")
        seekstart(req_body)
        res_body = IOBuffer()
        resp = HTTP.get("http://localhost:8080/retry"; body=req_body, response_stream=res_body)
        @test resp.status == 200
        @test String(take!(res_body)) == "hey there sailor"
        # ensure if retry=false, that we write the response body immediately
        shouldfail[] = true
        seekstart(req_body)
        resp = HTTP.get("http://localhost:8080/retry"; body=req_body, response_stream=res_body, retry=false, status_exception=false)
        @test String(take!(res_body)) == "500 unexpected error"
        # when retrying, we can still get access to the most recent failed response body in the response's request context
        shouldfail[] = true
        seekstart(req_body)
        println("making 3rd request")
        resp = HTTP.get("http://localhost:8080/retry"; body=req_body, response_stream=res_body)
        @test resp.status == 200
        @test String(take!(res_body)) == "hey there sailor"
        @test String(resp.request.context[:response_body]) == "500 unexpected error"
    finally
        close(server)
        HTTP.ConnectionPool.closeall()
    end
end

findnewline(bytes) = something(findfirst(==(UInt8('\n')), bytes), 0)

@testset "readuntil on Stream" begin

    HTTP.open(:GET, "http://httpbin.org/stream/5") do io
        while !eof(io)
            bytes = readuntil(io, findnewline)
            isempty(bytes) && break
            x = JSON.parse(IOBuffer(bytes))
            @show x
        end
    end

end

end # module
