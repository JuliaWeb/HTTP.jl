module test_server

using HTTP, Sockets, Test

function testget(url, m=1)
    r = []
    @sync for i in 1:m
        l = rand([0,0,10,1000,10000])
        body = Vector{UInt8}(rand('A':'Z', l))
        # println("sending request...")
        @async push!(r, HTTP.request("GET", "$url/$i", [], body))
    end
    return r
end

@testset "HTTP.listen" begin
    port = 8087 # rand(8000:8999)

    # echo response
    handler = (http) -> begin
        request::HTTP.Request = http.message
        request.body = read(http)
        closeread(http)
        request.response::HTTP.Response = HTTP.Response(request.body)
        request.response.request = request
        startwrite(http)
        write(http, request.response.body)
    end

    server = Sockets.listen(Sockets.InetAddr(parse(IPAddr, "127.0.0.1"), port))
    tsk = @async HTTP.listen(handler, "127.0.0.1", port; server=server)
    sleep(3.0)
    @test !istaskdone(tsk)
    r = testget("http://127.0.0.1:$port")
    @test r[1].status == 200
    close(server)
    sleep(0.5)
    @test istaskdone(tsk)

    server = Sockets.listen(Sockets.InetAddr(parse(IPAddr, "127.0.0.1"), port))
    tsk = @async HTTP.listen(handler, "127.0.0.1", port; server=server)

    handler2 = HTTP.Handlers.RequestHandlerFunction(req->HTTP.Response(200, req.body))

    server2 = Sockets.listen(Sockets.InetAddr(parse(IPAddr, "127.0.0.1"), port+100))
    tsk2 = @async HTTP.serve(handler2, "127.0.0.1", port+100; server=server2)
    sleep(0.5)
    @test !istaskdone(tsk)
    @test !istaskdone(tsk2)

    r = testget("http://127.0.0.1:$port")
    @test r[1].status == 200

    r = testget("http://127.0.0.1:$(port+100)")
    @test r[1].status == 200

    rs = testget("http://127.0.0.1:$port/", 20)
    foreach(rs) do r
        @test r.status == 200
    end

    r = HTTP.get("http://127.0.0.1:$port/"; readtimeout=30)
    @test r.status == 200
    @test String(r.body) == ""

    # large headers
    tcp = Sockets.connect(ip"127.0.0.1", port)
    x = "GET / HTTP/1.1\r\n$(repeat("Foo: Bar\r\n", 10000))\r\n";
    @show length(x)
    write(tcp, "GET / HTTP/1.1\r\n$(repeat("Foo: Bar\r\n", 10000))\r\n")
    sleep(0.1)
    @test occursin(r"HTTP/1.1 413 Request Entity Too Large", String(read(tcp)))

    # invalid HTTP
    tcp = Sockets.connect(ip"127.0.0.1", port)
    write(tcp, "GET / HTP/1.1\r\n\r\n")
    sleep(0.1)
    @test occursin(r"HTTP/1.1 400 Bad Request", String(readavailable(tcp)))

    # no URL
    tcp = Sockets.connect(ip"127.0.0.1", port)
    write(tcp, "SOMEMETHOD HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
    sleep(0.1)
    r = String(readavailable(tcp))
    @test occursin(r"HTTP/1.1 400 Bad Request", r)

    # Expect: 100-continue
    tcp = Sockets.connect(ip"127.0.0.1", port)
    write(tcp, "POST / HTTP/1.1\r\nContent-Length: 15\r\nExpect: 100-continue\r\n\r\n")
    sleep(0.1)
    client = String(readavailable(tcp))
    @test client == "HTTP/1.1 100 Continue\r\n\r\n"

    write(tcp, "Body of Request")
    sleep(0.1)
    client = String(readavailable(tcp))

    println("client:")
    println(client)
    @test occursin("HTTP/1.1 200 OK\r\n", client)
    @test occursin("Transfer-Encoding: chunked\r\n", client)
    @test occursin("Body of Request", client)

    hello = (http) -> begin
        request::HTTP.Request = http.message
        request.body = read(http)
        closeread(http)
        request.response::HTTP.Response = HTTP.Response("Hello")
        request.response.request = request
        startwrite(http)
        write(http, request.response.body)
    end
    close(server)
    close(server2)

    # keep-alive vs. close: issue #81
    port += 1
    server = Sockets.listen(Sockets.InetAddr(parse(IPAddr, "127.0.0.1"), port))
    tsk = @async HTTP.listen(hello, "127.0.0.1", port; server=server, verbose=true)
    sleep(0.5)
    @test !istaskdone(tsk)
    tcp = Sockets.connect(ip"127.0.0.1", port)
    write(tcp, "GET / HTTP/1.0\r\n\r\n")
    sleep(0.5)
    client = String(readavailable(tcp))
    @show client
    @test client == "HTTP/1.1 200 OK\r\n\r\nHello"

    # SO_REUSEPORT
    println("Testing server port reuse")
    t1 = @async HTTP.listen(hello, "127.0.0.1", 8089; reuseaddr=true)
    sleep(0.5)
    @test !istaskdone(t1)

    println("Starting second server listening on same port")
    t2 = @async HTTP.listen(hello, "127.0.0.1", 8089; reuseaddr=true)
    sleep(0.5)
    @test Sys.iswindows() ? istaskdone(t2) : !istaskdone(t2)

    println("Starting server on same port without port reuse (throws error)")
    try
        HTTP.listen(hello, "127.0.0.1", 8089)
    catch e
        @test e isa Base.IOError
        @test startswith(e.msg, "listen")
        @test e.code == Base.UV_EADDRINUSE
    end

    # test automatic forwarding of non-sensitive headers
    # this is a server that will "echo" whatever headers were sent to it
    t1 = @async HTTP.listen("127.0.0.1", 8090) do http
        request::HTTP.Request = http.message
        request.body = read(http)
        closeread(http)
        request.response::HTTP.Response = HTTP.Response(200, request.headers)
        request.response.request = request
        startwrite(http)
        write(http, request.response.body)
    end

    sleep(0.5)
    @test !istaskdone(t1)

    # test that an Authorization header is **not** forwarded to a domain different than initial request
    # r = HTTP.get("http://httpbin.org/redirect-to?url=http://127.0.0.1:8090", ["Authorization"=>"auth"])
    # @test !HTTP.hasheader(r, "Authorization")

    # # test that an Authorization header **is** forwarded to redirect in same domain
    # r = HTTP.get("http://httpbin.org/redirect-to?url=https://httpbin.org/response-headers?Authorization=auth")
    # @test HTTP.hasheader(r, "Authorization")
end # @testset

end # module
