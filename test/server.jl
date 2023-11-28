module test_server

import ..httpbin
using HTTP, HTTP.IOExtras, Sockets, Test, MbedTLS

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

const echohandler = req -> HTTP.Response(200, req.body)
const echostreamhandler = HTTP.streamhandler(echohandler)

@testset "HTTP.listen" begin
    server = HTTP.listen!(echostreamhandler; listenany=true)
    port = HTTP.port(server)
    r = testget("http://127.0.0.1:$port")
    @test r[1].status == 200
    close(server)
    sleep(0.5)
    @test istaskdone(server.task)

    server = HTTP.listen!(echostreamhandler; listenany=true)
    port = HTTP.port(server)
    server2 = HTTP.serve!(echohandler; listenany=true)
    port2 = HTTP.port(server2)

    r = testget("http://127.0.0.1:$port")
    @test r[1].status == 200

    r = testget("http://127.0.0.1:$(port2)")
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
    write(tcp, "GET / HTTP/1.1\r\n$(repeat("Foo: Bar\r\n", 10000))\r\n")
    sleep(0.1)
    try
        resp = String(readavailable(tcp))
        @test occursin(r"HTTP/1.1 431 Request Header Fields Too Large", resp)
    catch
        println("Failed reading bad request response")
    end

    # invalid HTTP
    tcp = Sockets.connect(ip"127.0.0.1", port)
    write(tcp, "GET / HTP/1.1\r\n\r\n")
    sleep(0.1)
    try
        resp = String(readavailable(tcp))
        @test occursin(r"HTTP/1.1 400 Bad Request", resp)
    catch
        println("Failed reading bad request response")
    end

    # no URL
    tcp = Sockets.connect(ip"127.0.0.1", port)
    write(tcp, "SOMEMETHOD HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
    sleep(0.1)
    try
        resp = String(readavailable(tcp))
        @test occursin(r"HTTP/1.1 400 Bad Request", resp)
    catch
        println("Failed reading bad request response")
    end

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

    close(server)
    close(server2)

    # keep-alive vs. close: issue #81
    hello = HTTP.streamhandler(req -> HTTP.Response("Hello"))
    server =  HTTP.listen!(hello; listenany=true, verbose=true)
    port = HTTP.port(server)
    tcp = Sockets.connect(ip"127.0.0.1", port)
    write(tcp, "GET / HTTP/1.0\r\n\r\n")
    sleep(0.5)
    try
        resp = String(readavailable(tcp))
        @test resp == "HTTP/1.1 200 OK\r\n\r\nHello"
    catch
        println("Failed reading bad request response")
    end
    close(server)

    # SO_REUSEPORT
    if HTTP.Servers.supportsreuseaddr()
        println("Testing server port reuse")
        t1 = HTTP.listen!(hello; listeany=true, reuseaddr=true)
        port = HTTP.port(t1)
        println("Starting second server listening on same port")
        t2 = HTTP.listen!(hello, port; reuseaddr=true)
        println("Starting server on same port without port reuse (throws error)")
        try
            HTTP.listen(hello, port)
        catch e
            @test e isa Base.IOError
            @test startswith(e.msg, "listen")
            @test e.code == Base.UV_EADDRINUSE
        end
        close(t1)
        close(t2)
    end

    # test automatic forwarding of non-sensitive headers
    # this is a server that will "echo" whatever headers were sent to it
    t1 = HTTP.listen!(; listenany=true) do http
        request::HTTP.Request = http.message
        request.body = read(http)
        closeread(http)
        request.response::HTTP.Response = HTTP.Response(200, request.headers)
        request.response.request = request
        startwrite(http)
        write(http, request.response.body)
    end
    port = HTTP.port(t1)

    # test that an Authorization header is **not** forwarded to a domain different than initial request
    @test !HTTP.hasheader(HTTP.get("https://$httpbin/redirect-to?url=http://127.0.0.1:$port", ["Authorization"=>"auth"]), "Authorization")

    # test that an Authorization header **is** forwarded to redirect in same domain
    @test HTTP.hasheader(HTTP.get("https://$httpbin/redirect-to?url=https://$httpbin/response-headers?Authorization=auth"), "Authorization")
    close(t1)

    # 318
    dir = joinpath(dirname(pathof(HTTP)), "../test")
    sslconfig = MbedTLS.SSLConfig(joinpath(dir, "resources/cert.pem"), joinpath(dir, "resources/key.pem"))
    server = HTTP.listen!(; listenany=true, sslconfig = sslconfig, verbose=true) do http::HTTP.Stream
        while !eof(http)
            println("body data: ", String(readavailable(http)))
        end
        HTTP.setstatus(http, 200)
        HTTP.startwrite(http)
        write(http, "response body\n")
        write(http, "more response body")
    end
    port = HTTP.port(server)
    r = HTTP.request("GET", "https://127.0.0.1:$port"; require_ssl_verification = false)
    @test_throws HTTP.RequestError HTTP.request("GET", "http://127.0.0.1:$port"; require_ssl_verification = false)
    close(server)

    # HTTP.listen with server kwarg
    let host = Sockets.localhost; port = 8093
        port, server = Sockets.listenany(host, port)
        HTTP.listen!(Sockets.localhost, port; server=server) do http
            HTTP.setstatus(http, 200)
            HTTP.startwrite(http)
        end
        r = HTTP.get("http://$(host):$(port)/"; readtimeout=30)
        @test r.status == 200
        close(server)
    end

    # listen does not break with EOFError during ssl handshake
    let host = Sockets.localhost
        sslconfig = MbedTLS.SSLConfig(joinpath(dir, "resources/cert.pem"), joinpath(dir, "resources/key.pem"))
        server = HTTP.listen!(; listenany=true, sslconfig=sslconfig, verbose=true) do http::HTTP.Stream
            HTTP.setstatus(http, 200)
            HTTP.startwrite(http)
            write(http, "response body\n")
        end

        port = HTTP.port(server)

        sock = connect(host, port)
        close(sock)

        r = HTTP.get("https://$(host):$(port)/"; readtimeout=30, require_ssl_verification = false)
        @test r.status == 200

        close(server)
    end
end # @testset

@testset "on_shutdown" begin
    @test HTTP.Servers.shutdown(nothing) === nothing

    # Shutdown adds 1
    TEST_COUNT = Ref(0)
    shutdown_add() = TEST_COUNT[] += 1
    server = HTTP.listen!(x -> nothing; listenany=true, on_shutdown=shutdown_add)
    close(server)

    # Shutdown adds 1, performed twice
    @test TEST_COUNT[] == 1
    server = HTTP.listen!(x -> nothing; listenany=true, on_shutdown=[shutdown_add, shutdown_add])
    close(server)
    @test TEST_COUNT[] == 3

    # First shutdown function errors, second adds 1
    shutdown_throw() = throw(ErrorException("Broken"))
    server = HTTP.listen!(x -> nothing; listenany=true, on_shutdown=[shutdown_throw, shutdown_add])
    @test_logs (:error, r"shutdown function .* failed.*ERROR: Broken.*"s) close(server)
    @test TEST_COUNT[] == 4
end # @testset

@testset "access logging" begin
    local handler = (http) -> begin
        if http.message.target == "/internal-error"
            error("internal error")
        end
        if http.message.target == "/close"
            HTTP.setstatus(http, 444)
            close(http.stream)
            return
        end
        HTTP.setstatus(http, 200)
        HTTP.setheader(http, "Content-Type" => "text/plain")
        msg = "hello, world"
        HTTP.setheader(http, "Content-Length" => string(sizeof(msg)))
        HTTP.startwrite(http)
        if http.message.method == "GET"
            HTTP.write(http, msg)
        end
    end
    function with_testserver(f, fmt)
        logger = Test.TestLogger()
        server = Base.CoreLogging.with_logger(logger) do
            HTTP.listen!(handler, Sockets.localhost, 32612; access_log=fmt)
        end
        try
            f()
        finally
            close(server)
        end
        return filter!(x -> x.group == :access, logger.logs)
    end

    # Common Log Format
    logs = with_testserver(common_logfmt) do
        HTTP.get("http://localhost:32612")
        HTTP.get("http://localhost:32612/index.html")
        HTTP.get("http://localhost:32612/index.html?a=b")
        HTTP.head("http://localhost:32612")
        HTTP.get("http://localhost:32612/internal-error"; status_exception=false)
        sleep(1) # necessary to properly forget the closed connection from the previous call
        try HTTP.get("http://localhost:32612/close"; retry=false) catch end
        HTTP.get("http://localhost:32612", ["Connection" => "close"])
        sleep(1) # we want to make sure the server has time to finish logging before checking logs
    end
    @test length(logs) == 7
    @test all(x -> x.group === :access, logs)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET / HTTP/1.1\" 200 12$", logs[1].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /index.html HTTP/1.1\" 200 12$", logs[2].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /index.html\?a=b HTTP/1.1\" 200 12$", logs[3].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"HEAD / HTTP/1.1\" 200 0$", logs[4].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /internal-error HTTP/1.1\" 500 \d+$", logs[5].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /close HTTP/1.1\" 444 0$", logs[6].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET / HTTP/1.1\" 200 12$", logs[7].message)

    # Combined Log Format
    logs = with_testserver(combined_logfmt) do
        HTTP.get("http://localhost:32612", ["Referer" => "julialang.org"])
        HTTP.get("http://localhost:32612/index.html")
        useragent = HTTP.HeadersRequest.USER_AGENT[]
        HTTP.setuseragent!(nothing)
        HTTP.get("http://localhost:32612/index.html?a=b")
        HTTP.setuseragent!(useragent)
        HTTP.head("http://localhost:32612")
    end
    @test length(logs) == 4
    @test all(x -> x.group === :access, logs)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET / HTTP/1.1\" 200 12 \"julialang\.org\" \"HTTP\.jl/.*\"$", logs[1].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /index.html HTTP/1.1\" 200 12 \"-\" \"HTTP\.jl/.*\"$", logs[2].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /index.html\?a=b HTTP/1.1\" 200 12 \"-\" \"-\"$", logs[3].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"HEAD / HTTP/1.1\" 200 0 \"-\" \"HTTP\.jl/.*\"$", logs[4].message)

    # Custom log format
    fmt = logfmt"$http_accept $sent_http_content_type $request $request_method $request_uri $remote_addr $remote_port $remote_user $server_protocol $time_iso8601 $time_local $status $body_bytes_sent"
    logs = with_testserver(fmt) do
        HTTP.get("http://localhost:32612", ["Accept" => "application/json"])
        HTTP.get("http://localhost:32612/index.html")
        HTTP.get("http://localhost:32612/index.html?a=b")
        HTTP.head("http://localhost:32612")
    end
    @test length(logs) == 4
    @test all(x -> x.group === :access, logs)
    @test occursin(r"^application/json text/plain GET / HTTP/1\.1 GET / 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 12$", logs[1].message)
    @test occursin(r"^\*/\* text/plain GET /index\.html HTTP/1\.1 GET /index\.html 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 12$", logs[2].message)
    @test occursin(r"^\*/\* text/plain GET /index\.html\?a=b HTTP/1\.1 GET /index\.html\?a=b 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 12$", logs[3].message)
    @test occursin(r"^\*/\* text/plain HEAD / HTTP/1\.1 HEAD / 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 0$", logs[4].message)
end

end # module
