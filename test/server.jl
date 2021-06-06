module test_server

using HTTP, Sockets, Test, MbedTLS

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
    @test_skip !HTTP.hasheader(HTTP.get("http://httpbin.org/redirect-to?url=http://127.0.0.1:8090", ["Authorization"=>"auth"]), "Authorization")

    # test that an Authorization header **is** forwarded to redirect in same domain
    @test_skip HTTP.hasheader(HTTP.get("http://httpbin.org/redirect-to?url=https://httpbin.org/response-headers?Authorization=auth"), "Authorization")

    # 318
    dir = joinpath(dirname(pathof(HTTP)), "../test")
    sslconfig = MbedTLS.SSLConfig(joinpath(dir, "resources/cert.pem"), joinpath(dir, "resources/key.pem"))
    tsk = @async try
        HTTP.listen("127.0.0.1", 8092; sslconfig = sslconfig, verbose=true) do http::HTTP.Stream
            while !eof(http)
                println("body data: ", String(readavailable(http)))
            end
            HTTP.setstatus(http, 200)
            HTTP.startwrite(http)
            write(http, "response body\n")
            write(http, "more response body")
        end
    catch err
        @error err exception = (err, catch_backtrace())
    end
    clientoptions = (;
        require_ssl_verification = false,
    )
    r = HTTP.request("GET", "https://127.0.0.1:8092"; clientoptions...)
    @test_throws HTTP.IOError HTTP.request("GET", "http://127.0.0.1:8092"; clientoptions...)

    # trigger_compilation
    port = 8080
    server = Sockets.listen(Sockets.InetAddr(parse(IPAddr, "127.0.0.1"), port))
    tsk = @async HTTP.listen(handler, "127.0.0.1", port; server=server, trigger_compilation=true)
    sleep(5.0)
    # Using allocations instead of time to make the tests more robust.
    bytes = @allocated HTTP.get("http://127.0.0.1:$port")
    @test bytes < 10_000_000
    close(server)

end # @testset

@testset "HTTP.listen: rate_limit" begin
    io = IOBuffer()
    logger = Base.CoreLogging.SimpleLogger(io)
    server = listen(IPv4(0), 8080)
    @async Base.CoreLogging.with_logger(logger) do
        HTTP.listen("0.0.0.0", 8080; server=server, rate_limit=2//1) do http
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Length" => "0")
            HTTP.startwrite(http)
            HTTP.close(http.stream) # close to force a new connection everytime
        end
    end
    # Test requests from the same IP within the limit
    for _ in 1:5
        sleep(0.6) # rate limit allows 2 per second
        @test HTTP.get("http://127.0.0.1:8080").status == 200
    end
    # Test requests from the same IP over the limit
    try
        for _ in 1:5
            sleep(0.2) # rate limit allows 2 per second
            r = HTTP.get("http://127.0.0.1:8080"; retry=false)
            @test r.status == 200
        end
    catch e
        @test e isa HTTP.IOExtras.IOError
    end

    close(server)
    @test occursin("discarding connection from 127.0.0.1 due to rate limiting", String(take!(io)))

    # # Tests to make sure the correct client IP is used (https://github.com/JuliaWeb/HTTP.jl/pull/701)
    # # This test requires a second machine and thus commented out
    #
    # Machine 1
    # @async HTTP.listen("0.0.0.0", 8080; rate_limit=2//1) do http
    #     HTTP.setstatus(http, 200)
    #     HTTP.setheader(http, "Content-Length" => "0")
    #     HTTP.startwrite(http)
    #     HTTP.close(http.stream) # close to force a new connection everytime
    # end
    # while true
    #     sleep(0.6)
    #     print("#") # to show some progress
    #     HTTP.get("http://$(MACHINE_1_IPV4):8080"; retry=false)
    # end
    #
    # # Machine 2
    # while true
    #     sleep(0.6)
    #     print("#") # to show some progress
    #     HTTP.get("http://$(MACHINE_1_IPV4):8080"; retry=false)
    # end

end

@testset "on_shutdown" begin
    @test HTTP.Servers.shutdown(nothing) === nothing

    IOserver = Sockets.listen(Sockets.InetAddr(parse(IPAddr, "127.0.0.1"), 8052))

    # Shutdown adds 1
    TEST_COUNT = Ref(0)
    shutdown_add() = TEST_COUNT[] += 1
    server = HTTP.Servers.Server(nothing, IOserver, "host", "port", shutdown_add)
    close(server)

    # Shutdown adds 1, performed twice
    @test TEST_COUNT[] == 1
    server = HTTP.Servers.Server(nothing, IOserver, "host", "port", [shutdown_add, shutdown_add])
    close(server)
    @test TEST_COUNT[] == 3

    # First shutdown function errors, second adds 1
    shutdown_throw() = throw(ErrorException("Broken"))
    server = HTTP.Servers.Server(nothing, IOserver, "host", "port", [shutdown_throw, shutdown_add])
    @test_logs (:error, r"shutdown function .* failed") close(server)
    @test TEST_COUNT[] == 4
end # @testset

@testset "access logging" begin
    function handler(http)
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
        l = Sockets.listen(ip"0.0.0.0", 1234)
        logger = Test.TestLogger()
        tsk = @async begin
            Base.CoreLogging.with_logger(logger) do
                HTTP.listen(handler, Sockets.localhost, 1234; server=l, access_log=fmt)
            end
        end
        try
            f()
        finally
            close(l)
        end
        return filter!(x -> x.group == :access, logger.logs)
    end

    # Common Log Format
    logs = with_testserver(common_logfmt) do
        HTTP.get("http://localhost:1234")
        HTTP.get("http://localhost:1234/index.html")
        HTTP.get("http://localhost:1234/index.html?a=b")
        HTTP.head("http://localhost:1234")
        HTTP.get("http://localhost:1234/internal-error"; status_exception=false)
        sleep(1) # necessary to properly forget the closed connection from the previous call
        try HTTP.get("http://localhost:1234/close"; retry=false) catch end
        HTTP.get("http://localhost:1234", ["Connection" => "close"])
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
        HTTP.get("http://localhost:1234", ["Referer" => "julialang.org"])
        HTTP.get("http://localhost:1234/index.html")
        useragent = HTTP.MessageRequest.USER_AGENT[]
        HTTP.setuseragent!(nothing)
        HTTP.get("http://localhost:1234/index.html?a=b")
        HTTP.setuseragent!(useragent)
        HTTP.head("http://localhost:1234")
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
        HTTP.get("http://localhost:1234", ["Accept" => "application/json"])
        HTTP.get("http://localhost:1234/index.html")
        HTTP.get("http://localhost:1234/index.html?a=b")
        HTTP.head("http://localhost:1234")
    end
    @test length(logs) == 4
    @test all(x -> x.group === :access, logs)
    @test occursin(r"^application/json text/plain GET / HTTP/1\.1 GET / 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 12$", logs[1].message)
    @test occursin(r"^\*/\* text/plain GET /index\.html HTTP/1\.1 GET /index\.html 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 12$", logs[2].message)
    @test occursin(r"^\*/\* text/plain GET /index\.html\?a=b HTTP/1\.1 GET /index\.html\?a=b 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 12$", logs[3].message)
    @test occursin(r"^\*/\* text/plain HEAD / HTTP/1\.1 HEAD / 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 0$", logs[4].message)
end

end # module
