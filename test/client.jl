module TestClient

using HTTP, HTTP.Exceptions, MbedTLS, OpenSSL
using HTTP: IOExtras
include(joinpath(dirname(pathof(HTTP)), "../test/resources/TestRequest.jl"))
import ..isok, ..httpbin
using .TestRequest
using .TestRequest2
using Sockets
using JSON
using Test
using URIs
using InteractiveUtils: @which
using ConcurrentUtilities

# ConcurrentUtilities changed a fieldname from max to limit in 2.3.0
const max_or_limit = :max in fieldnames(ConcurrentUtilities.Pool) ? (:max) : (:limit)

# test we can adjust default_connection_limit
for x in (10, 12)
    HTTP.set_default_connection_limit!(x)
    @test getfield(HTTP.Connections.TCP_POOL[], max_or_limit) == x
    @test getfield(HTTP.Connections.MBEDTLS_POOL[], max_or_limit) == x
    @test getfield(HTTP.Connections.OPENSSL_POOL[], max_or_limit) == x
end

@testset "@client macro" begin
    @eval module MyClient
        using HTTP
        HTTP.@client () ()
    end
    # Test the `@client` sets the location info to the definition site, i.e. this file.
    meth = @which MyClient.get()
    file = String(meth.file)
    @test file == @__FILE__
end

@testset "Custom HTTP Stack" begin
   @testset "Low-level Request" begin
        wasincluded = Ref(false)
        result = TestRequest.get("https://$httpbin/ip"; httptestlayer=wasincluded)
        @test isok(result)
        @test wasincluded[]
    end
    @testset "Low-level Request" begin
        TestRequest2.get("https://$httpbin/ip")
        # tests included in the layers themselves
    end
end

@testset "Client.jl" for tls in [MbedTLS.SSLContext, OpenSSL.SSLStream]
    @testset "GET, HEAD, POST, PUT, DELETE, PATCH" begin
        @test isok(HTTP.get("https://$httpbin/ip", socket_type_tls=tls))
        @test isok(HTTP.head("https://$httpbin/ip", socket_type_tls=tls))
        @test HTTP.post("https://$httpbin/patch"; status_exception=false, socket_type_tls=tls).status == 405
        @test isok(HTTP.post("https://$httpbin/post", socket_type_tls=tls))
        @test isok(HTTP.put("https://$httpbin/put", socket_type_tls=tls))
        @test isok(HTTP.delete("https://$httpbin/delete", socket_type_tls=tls))
        @test isok(HTTP.patch("https://$httpbin/patch", socket_type_tls=tls))
    end

    @testset "decompress" begin
        r = HTTP.get("https://$httpbin/gzip", socket_type_tls=tls)
        @test isok(r)
        @test isascii(String(r.body))
        r = HTTP.get("https://$httpbin/gzip"; decompress=false, socket_type_tls=tls)
        @test isok(r)
        @test !isascii(String(r.body))
        r = HTTP.get("https://$httpbin/gzip"; decompress=false, socket_type_tls=tls)
        @test isascii(String(HTTP.decode(r, "gzip")))
    end

    @testset "ASync Client Requests" begin
        @test isok(fetch(@async HTTP.get("https://$httpbin/ip", socket_type_tls=tls)))
        @test isok(HTTP.get("https://$httpbin/encoding/utf8", socket_type_tls=tls))
    end

    @testset "Query to URI" begin
        r = HTTP.get(URI(HTTP.URI("https://$httpbin/response-headers"); query=Dict("hey"=>"dude")))
        h = Dict(r.headers)
        @test (haskey(h, "Hey") ? h["Hey"] == "dude" : h["hey"] == "dude")
    end

    @testset "Cookie Requests" begin
        empty!(HTTP.COOKIEJAR)
        url = "https://$httpbin/cookies"
        r = HTTP.get(url, cookies=true, socket_type_tls=tls)
        @test String(r.body) == "{}"
        cookies = HTTP.Cookies.getcookies!(HTTP.COOKIEJAR, URI(url))
        @test isempty(cookies)

        url = "https://$httpbin/cookies/set?hey=sailor&foo=bar"
        r = HTTP.get(url, cookies=true, socket_type_tls=tls)
        @test isok(r)
        cookies = HTTP.Cookies.getcookies!(HTTP.COOKIEJAR, URI(url))
        @test length(cookies) == 2

        url = "https://$httpbin/cookies/delete?hey"
        r = HTTP.get(url, socket_type_tls=tls)
        cookies = HTTP.Cookies.getcookies!(HTTP.COOKIEJAR, URI(url))
        @test length(cookies) == 1
    end

    @testset "Client Streaming Test" begin
        r = HTTP.post("https://$httpbin/post"; body="hey", socket_type_tls=tls)
        @test isok(r)

        # stream, but body is too small to actually stream
        r = HTTP.post("https://$httpbin/post"; body="hey", stream=true, socket_type_tls=tls)
        @test isok(r)

        r = HTTP.get("https://$httpbin/stream/100", socket_type_tls=tls)
        @test isok(r)

        bytes = r.body
        a = [JSON.parse(l) for l in split(chomp(String(bytes)), "\n")]
        totallen = length(bytes) # number of bytes to expect

        io = IOBuffer()
        r = HTTP.get("https://$httpbin/stream/100"; response_stream=io, socket_type_tls=tls)
        seekstart(io)
        @test isok(r)

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

        # pass pre-allocated buffer
        body = zeros(UInt8, 100)
        r = HTTP.get("https://$httpbin/bytes/100"; response_stream=body, socket_type_tls=tls)
        @test body === r.body

        # wrapping pre-allocated buffer in IOBuffer will write to buffer directly
        io = IOBuffer(body; write=true)
        r = HTTP.get("https://$httpbin/bytes/100"; response_stream=io, socket_type_tls=tls)
        @test Base.mightalias(body, r.body.data)

        # if provided buffer is too small, we won't grow it for user
        body = zeros(UInt8, 10)
        @test_throws HTTP.RequestError HTTP.get("https://$httpbin/bytes/100"; response_stream=body, socket_type_tls=tls, retry=false)

        # also won't shrink it if buffer provided is larger than response body
        body = zeros(UInt8, 10)
        r = HTTP.get("https://$httpbin/bytes/5"; response_stream=body, socket_type_tls=tls)
        @test body === r.body
        @test length(body) == 10
        @test HTTP.header(r, "Content-Length") == "5"

        # but if you wrap it in a writable IOBuffer, we will grow it
        io = IOBuffer(body; write=true)
        r = HTTP.get("https://$httpbin/bytes/100"; response_stream=io, socket_type_tls=tls)
        # might be a new Array, resized larger
        body = take!(io)
        @test length(body) == 100

        # and you can reuse it
        seekstart(io)
        r = HTTP.get("https://$httpbin/bytes/100"; response_stream=io, socket_type_tls=tls)
        # `take!` should have given it a new Array
        @test !Base.mightalias(body, r.body.data)
        body = take!(io)
        @test length(body) == 100

        # we respect ptr and size
        body = zeros(UInt8, 100)
        io = IOBuffer(body; write=true, append=true) # size=100, ptr=1
        r = HTTP.get("https://$httpbin/bytes/100"; response_stream=io, socket_type_tls=tls)
        body = take!(io)
        @test length(body) == 200

        body = zeros(UInt8, 100)
        io = IOBuffer(body, write=true, append=false)
        write(io, body) # size=100, ptr=101
        r = HTTP.get("https://$httpbin/bytes/100"; response_stream=io, socket_type_tls=tls)
        body = take!(io)
        @test length(body) == 200

    end

    @testset "Client Body Posting - Vector{UTF8}, String, IOStream, IOBuffer, BufferStream, Dict, NamedTuple" begin
        @test isok(HTTP.post("https://$httpbin/post"; body="hey", socket_type_tls=tls))
        @test isok(HTTP.post("https://$httpbin/post"; body=UInt8['h','e','y'], socket_type_tls=tls))
        io = IOBuffer("hey"); seekstart(io)
        @test isok(HTTP.post("https://$httpbin/post"; body=io, socket_type_tls=tls))
        tmp = tempname()
        open(f->write(f, "hey"), tmp, "w")
        io = open(tmp)
        @test isok(HTTP.post("https://$httpbin/post"; body=io, enablechunked=false, socket_type_tls=tls))
        close(io); rm(tmp)
        f = Base.BufferStream()
        write(f, "hey")
        close(f)
        @test isok(HTTP.post("https://$httpbin/post"; body=f, enablechunked=false, socket_type_tls=tls))
        resp = HTTP.post("https://$httpbin/post"; body=Dict("name" => "value"), socket_type_tls=tls)
        @test isok(resp)
        x = JSON.parse(IOBuffer(resp.body))
        @test x["form"] == Dict("name" => ["value"])
        resp = HTTP.post("https://$httpbin/post"; body=(name="value with spaces",), socket_type_tls=tls)
        @test isok(resp)
        x = JSON.parse(IOBuffer(resp.body))
        @test x["form"] == Dict("name" => ["value with spaces"])
    end

    @testset "Chunksize" begin
        #     https://github.com/JuliaWeb/HTTP.jl/issues/60
        #     Currently $httpbin responds with 411 status and “Length Required”
        #     message to any POST/PUT requests that are sent using chunked encoding
        #     See https://github.com/kennethreitz/httpbin/issues/340#issuecomment-330176449
        @test isok(HTTP.post("https://$httpbin/post"; body="hey", socket_type_tls=tls, #=chunksize=2=#))
        @test isok(HTTP.post("https://$httpbin/post"; body=UInt8['h','e','y'], socket_type_tls=tls, #=chunksize=2=#))
        io = IOBuffer("hey"); seekstart(io)
        @test isok(HTTP.post("https://$httpbin/post"; body=io, socket_type_tls=tls, #=chunksize=2=#))
        tmp = tempname()
        open(f->write(f, "hey"), tmp, "w")
        io = open(tmp)
        @test isok(HTTP.post("https://$httpbin/post"; body=io, socket_type_tls=tls, #=chunksize=2=#))
        close(io); rm(tmp)
        f = Base.BufferStream()
        write(f, "hey")
        close(f)
        @test isok(HTTP.post("https://$httpbin/post"; body=f, socket_type_tls=tls, #=chunksize=2=#))
    end

    @testset "ASync Client Request Body" begin
        f = Base.BufferStream()
        write(f, "hey")
        t = @async HTTP.post("https://$httpbin/post"; body=f, enablechunked=false, socket_type_tls=tls)
        #fetch(f) # fetch for the async call to write it's first data
        write(f, " there ") # as we write to f, it triggers another chunk to be sent in our async request
        write(f, "sailor")
        close(f) # setting eof on f causes the async request to send a final chunk and return the response
        @test isok(fetch(t))
    end

    @testset "Client Redirect Following - $read_method" for read_method in ["GET", "HEAD"]
        @test isok(HTTP.request(read_method, "https://$httpbin/redirect/1", socket_type_tls=tls))
        @test HTTP.request(read_method, "https://$httpbin/redirect/1", redirect=false, socket_type_tls=tls).status == 302
        @test HTTP.request(read_method, "https://$httpbin/redirect/6", socket_type_tls=tls).status == 302 #over max number of redirects
        @test isok(HTTP.request(read_method, "https://$httpbin/relative-redirect/1", socket_type_tls=tls))
        @test isok(HTTP.request(read_method, "https://$httpbin/absolute-redirect/1", socket_type_tls=tls))
        @test isok(HTTP.request(read_method, "https://$httpbin/redirect-to?url=http%3A%2F%2Fgoogle.com", socket_type_tls=tls))
    end

    @testset "Client Basic Auth" begin
        @test isok(HTTP.get("https://user:pwd@$httpbin/basic-auth/user/pwd", socket_type_tls=tls))
        @test isok(HTTP.get("https://user:pwd@$httpbin/hidden-basic-auth/user/pwd", socket_type_tls=tls))
        @test isok(HTTP.get("https://test:%40test@$httpbin/basic-auth/test/%40test", socket_type_tls=tls))
    end

    @testset "Misc" begin
        @test isok(HTTP.post("https://$httpbin/post"; body="√", socket_type_tls=tls))
        r = HTTP.request("GET", "https://$httpbin/ip", socket_type_tls=tls)
        @test isok(r)

        uri = HTTP.URI("https://$httpbin/ip")
        r = HTTP.request("GET", uri, socket_type_tls=tls)
        @test isok(r)
        r = HTTP.get(uri)
        @test isok(r)

        r = HTTP.request("GET", "https://$httpbin/ip", socket_type_tls=tls)
        @test isok(r)

        uri = HTTP.URI("https://$httpbin/ip")
        r = HTTP.request("GET", uri, socket_type_tls=tls)
        @test isok(r)

        r = HTTP.get("https://$httpbin/image/png", socket_type_tls=tls)
        @test isok(r)

        # ensure we can use AbstractString for requests
        r = HTTP.get(SubString("https://$httpbin/ip",1), socket_type_tls=tls)

        # canonicalizeheaders
        @test isok(HTTP.get("https://$httpbin/ip"; canonicalizeheaders=false, socket_type_tls=tls))

        # Ensure HEAD requests stay the same through redirects by default
        r = HTTP.head("https://$httpbin/redirect/1")
        @test r.request.method == "HEAD"
        @test iszero(length(r.body))
        # But if explicitly requested, GET can be used instead
        r = HTTP.head("https://$httpbin/redirect/1"; redirect_method="GET")
        @test r.request.method == "GET"
        @test length(r.body) > 0
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
        HTTP.Connections.closeall()
    end
end

@testset "HTTP.open accepts method::Symbol" begin
    @test isok(HTTP.open(x -> x, :GET, "http://$httpbin/ip"))
end

@testset "readtimeout" begin
    @test_throws HTTP.TimeoutError begin
        HTTP.get("http://$httpbin/delay/5"; readtimeout=1, retry=false)
    end
    HTTP.get("http://$httpbin/delay/1"; readtimeout=2, retry=false)
end

@testset "connect_timeout does not include the time needed to acquire a connection from the pool" begin
    connection_limit = getfield(HTTP.Connections.TCP_POOL[], max_or_limit)
    try
        dummy_conn = HTTP.Connection(Sockets.TCPSocket())
        HTTP.set_default_connection_limit!(1)
        @assert getfield(HTTP.Connections.TCP_POOL[], max_or_limit) == 1
        # drain the pool
        acquire(()->dummy_conn, HTTP.Connections.TCP_POOL[], HTTP.Connections.connectionkey(dummy_conn))
        # Put it back in 10 seconds
        Timer(t->HTTP.Connections.releaseconnection(dummy_conn, false), 10; interval=0)
        # If we count the time it takes to acquire the connection from the pool, we'll get a timeout error.
        HTTP.get("https://$httpbin/get"; connect_timeout=5, retry=false, socket_type_tls=Sockets.TCPSocket)
        @test true # if we get here, we didn't timeout
    finally
        HTTP.set_default_connection_limit!(connection_limit)
    end
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
                resp = HTTP.get("http://localhost:8080")
                @test isok(resp)
                @test String(resp.body) == "hello, world"
            finally
                @try Base.IOError close(server)
                HTTP.Connections.closeall()
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
        HTTP.Connections.closeall()
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
        old_user_agent = HTTP.HeadersRequest.USER_AGENT[]
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
        HTTP.Connections.closeall()
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
            @test isok(HTTP.get(url; require_ssl_verification=false))
        end
        withenv(env..., "JULIA_NO_VERIFY_HOSTS" => "localhost") do
            @test !NetworkOptions.verify_host(url)
            @test !NetworkOptions.verify_host(url, "SSL")
            @test isok(HTTP.get(url))
            @test_throws HTTP.ConnectError HTTP.get(url; require_ssl_verification=true, retries=1)
            @test isok(HTTP.get(url; require_ssl_verification=false))
        end
        withenv(env..., "JULIA_SSL_NO_VERIFY_HOSTS" => "localhost") do
            @test NetworkOptions.verify_host(url)
            @test !NetworkOptions.verify_host(url, "SSL")
            @test isok(HTTP.get(url))
            @test_throws HTTP.ConnectError HTTP.get(url; require_ssl_verification=true, retries=1)
            @test isok(HTTP.get(url; require_ssl_verification=false))
        end
    finally
        @try Base.IOError close(server)
        HTTP.Connections.closeall()
    end
end

@testset "Public entry point of HTTP.request and friends (e.g. issue #463)" begin
    headers = Dict("User-Agent" => "HTTP.jl")
    query = Dict("hello" => "world")
    body = UInt8[1, 2, 3]
    stack = HTTP.stack()
    function test(r, m)
        @test isok(r)
        d = JSON.parse(IOBuffer(HTTP.payload(r)))
        @test d["headers"]["User-Agent"] == ["HTTP.jl"]
        @test d["data"] == "\x01\x02\x03"
        @test endswith(d["url"], "?hello=world")
    end
    for uri in ("https://$httpbin/anything", HTTP.URI("https://$httpbin/anything"))
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
            HTTP.Connections.closeall()
        end
    end
end

@testset "Retry with request/response body streams" begin
    shouldfail = Ref(true)
    status = Ref(200)
    server = HTTP.listen!(8080) do http
        @assert !eof(http)
        msg = String(read(http))
        if shouldfail[]
            shouldfail[] = false
            error("500 unexpected error")
        end
        HTTP.setstatus(http, status[])
        if status[] != 200
            HTTP.startwrite(http)
            HTTP.write(http, "$(status[]) unexpected error")
            status[] = 200
        end
        HTTP.startwrite(http)
        HTTP.write(http, msg)
    end
    try
        req_body = IOBuffer("hey there sailor")
        seekstart(req_body)
        res_body = IOBuffer()
        resp = HTTP.get("http://localhost:8080/retry"; body=req_body, response_stream=res_body)
        @test isok(resp)
        @test String(take!(res_body)) == "hey there sailor"
        # ensure if retry=false, that we write the response body immediately
        shouldfail[] = true
        seekstart(req_body)
        resp = HTTP.get("http://localhost:8080/retry"; body=req_body, response_stream=res_body, retry=false, status_exception=false)
        @test resp.status == 500
        # even if StatusError, we should still get the right response body
        shouldfail[] = true
        seekstart(req_body)
        try
            resp = HTTP.get("http://localhost:8080/retry"; body=req_body, response_stream=res_body, retry=false, forcenew=true)
        catch e
            @test e isa HTTP.StatusError
            @test e.status == 500
        end
        # don't throw a 500, but set status to status we don't retry by default
        shouldfail[] = false
        status[] = 404
        seekstart(req_body)
        checked = Ref(0)
        @test !HTTP.retryable(404)
        check = (s, ex, req, resp, resp_body) -> begin
            checked[] += 1
            str = String(resp_body)
            if str != "404 unexpected error" || resp.status != 404
                @error "unexpected response body" str
                return false
            end
            @test str == "404 unexpected error"
            return resp.status == 404
        end
        resp = HTTP.get("http://localhost:8080/retry"; body=req_body, response_stream=res_body, retry_check=check)
        @test isok(resp)
        @test String(take!(res_body)) == "hey there sailor"
        @test checked[] >= 1
    finally
        close(server)
        HTTP.Connections.closeall()
    end
end

@testset "Don't retry on internal exceptions" begin
    kws = (retry_delays = [10, 20, 30], retries=3) # ~ 60 secs
    max_wait = 30

    function test_finish_within(f, secs)
        timedout = Ref(false)
        t = Timer((t)->(timedout[] = true), secs)
        try
            f()
        finally
            close(t)
        end
        @test !timedout[]
    end

    expected = ErrorException("request")
    test_finish_within(max_wait) do
        @test_throws expected ErrorRequest.get("https://$httpbin/ip"; request_exception=expected, kws...)
    end
    expected = ArgumentError("request")
    test_finish_within(max_wait) do
        @test_throws expected ErrorRequest.get("https://$httpbin/ip"; request_exception=expected, kws...)
    end

    test_finish_within(max_wait) do
        expected = ErrorException("stream")
        e = try
            ErrorRequest.get("https://$httpbin/ip"; stream_exception=expected, kws...)
        catch e
            e
        end
        @assert e isa HTTP.RequestError
        @test e.error == expected
    end

    test_finish_within(max_wait) do
        expected = ArgumentError("stream")
        e = try
            ErrorRequest.get("https://$httpbin/ip"; stream_exception=expected, kws...)
        catch e
            e
        end
        @assert e isa HTTP.RequestError
        @test e.error == expected
    end
end

@testset "Retry with ConnectError" begin
    mktemp() do path, io
        redirect_stdout(io) do
            redirect_stderr(io) do
                try
                    HTTP.request("GET", "http://n0nexist3nthost/"; verbose=true)
                catch
                    # ignore
                end
            end
        end
        close(io)
        logs = read(path, String)

        if occursin("EAI_NODATA", logs)
            @test occursin("No Retry: GET / HTTP/1.1", logs)
        elseif occursin("EAI_EAGAIN", logs)
            # interestingly some environments also result in EAGAIN in these cases
            @test occursin("Retry HTTP.Exceptions.ConnectError", logs)
        end
    end

    # isrecoverable tests
    @test !HTTP.RetryRequest.isrecoverable(nothing)

    @test !HTTP.RetryRequest.isrecoverable(ErrorException(""))
    @test !HTTP.RetryRequest.isrecoverable(ArgumentError("yikes"))
    @test HTTP.RetryRequest.isrecoverable(ArgumentError("stream is closed or unusable"))

    @test HTTP.RetryRequest.isrecoverable(HTTP.RequestError(nothing, ArgumentError("stream is closed or unusable")))
    @test !HTTP.RetryRequest.isrecoverable(HTTP.RequestError(nothing, ArgumentError("yikes")))

    @test HTTP.RetryRequest.isrecoverable(CapturedException(ArgumentError("stream is closed or unusable"), Any[]))

    recoverable_dns_error = Sockets.DNSError("localhost", Base.UV_EAI_AGAIN)
    unrecoverable_dns_error = Sockets.DNSError("localhost", Base.UV_EAI_NONAME)
    @test HTTP.RetryRequest.isrecoverable(recoverable_dns_error)
    @test !HTTP.RetryRequest.isrecoverable(unrecoverable_dns_error)
    @test HTTP.RetryRequest.isrecoverable(HTTP.Exceptions.ConnectError("http://localhost", recoverable_dns_error))
    @test !HTTP.RetryRequest.isrecoverable(HTTP.Exceptions.ConnectError("http://localhost", unrecoverable_dns_error))
    @test HTTP.RetryRequest.isrecoverable(CompositeException([
        recoverable_dns_error,
        HTTP.Exceptions.ConnectError("http://localhost", recoverable_dns_error),
    ]))
    @test HTTP.RetryRequest.isrecoverable(CompositeException([
        recoverable_dns_error,
        HTTP.Exceptions.ConnectError("http://localhost", recoverable_dns_error),
        CompositeException([recoverable_dns_error])
    ]))
    @test !HTTP.RetryRequest.isrecoverable(CompositeException([
        recoverable_dns_error,
        HTTP.Exceptions.ConnectError("http://localhost", unrecoverable_dns_error),
    ]))
    @test !HTTP.RetryRequest.isrecoverable(CompositeException([
        recoverable_dns_error,
        HTTP.Exceptions.ConnectError("http://localhost", recoverable_dns_error),
        CompositeException([unrecoverable_dns_error])
    ]))
end

findnewline(bytes) = something(findfirst(==(UInt8('\n')), bytes), 0)

@testset "IOExtras.readuntil on Stream" begin
    HTTP.open(:GET, "https://$httpbin/stream/5") do io
        while !eof(io)
            bytes = IOExtras.readuntil(io, findnewline)
            isempty(bytes) && break
            x = JSON.parse(IOBuffer(bytes))
        end
    end
end

@testset "CA_BUNDEL env" begin
    resp = withenv("HTTP_CA_BUNDLE" => HTTP.MbedTLS.MozillaCACerts_jll.cacert) do
        HTTP.get("https://$httpbin/ip"; socket_type_tls=SSLStream)
    end
    @test isok(resp)
    resp = withenv("HTTP_CA_BUNDLE" => HTTP.MbedTLS.MozillaCACerts_jll.cacert) do
        HTTP.get("https://$httpbin/ip")
    end
    @test isok(resp)
end

end # module
