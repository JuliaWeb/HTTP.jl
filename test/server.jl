using Test, HTTP, Logging

@testset "HTTP.serve" begin
    server = HTTP.serve!(req -> HTTP.Response(200, "Hello, World!"); listenany=true)
    try
        @test server.state == :running
        resp = HTTP.get("http://127.0.0.1:8080")
        @test resp.status == 200
        @test String(resp.body) == "Hello, World!"
    finally
        close(server)
    end
end

@testset "access logging" begin
    local handler = (req) -> begin
        if req.target == "/internal-error"
            error("internal error")
        end
        if req.target == "/close"
            return HTTP.Response(444, ["content-type" => "text/plain"], nothing)
        end
        return HTTP.Response(200, ["content-type" => "text/plain"], "hello, world")
    end
    function with_testserver(f, fmt)
        logger = Test.TestLogger()
        with_logger(logger) do
            server = HTTP.serve!(handler; listenany=true, access_log=fmt)
            port = HTTP.port(server)
            try
                f(port)
            finally
                close(server)
            end
        end
        return filter!(x -> x.group == :access, logger.logs)
    end

    # Common Log Format
    logs = with_testserver(common_logfmt) do port
        HTTP.get("http://127.0.0.1:$port")
        HTTP.get("http://127.0.0.1:$port/index.html")
        HTTP.get("http://127.0.0.1:$port/index.html?a=b")
        HTTP.head("http://127.0.0.1:$port")
        HTTP.get("http://127.0.0.1:$port/internal-error"; status_exception=false)
        # sleep(1) # necessary to properly forget the closed connection from the previous call
        try HTTP.get("http://127.0.0.1:$port/close"; retry=false) catch end
        HTTP.get("http://127.0.0.1:$port", ["Connection" => "close"])
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
    logs = with_testserver(combined_logfmt) do port
        HTTP.get("http://127.0.0.1:$port", ["Referer" => "julialang.org"])
        HTTP.get("http://127.0.0.1:$port/index.html")
        useragent = HTTP.USER_AGENT[]
        HTTP.setuseragent!(nothing)
        HTTP.get("http://127.0.0.1:$port/index.html?a=b")
        HTTP.setuseragent!(useragent)
        HTTP.head("http://127.0.0.1:$port")
    end
    @test length(logs) == 4
    @test all(x -> x.group === :access, logs)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET / HTTP/1.1\" 200 12 \"julialang\.org\" \"HTTP\.jl/.*\"$", logs[1].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /index.html HTTP/1.1\" 200 12 \"-\" \"HTTP\.jl/.*\"$", logs[2].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /index.html\?a=b HTTP/1.1\" 200 12 \"-\" \"-\"$", logs[3].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"HEAD / HTTP/1.1\" 200 0 \"-\" \"HTTP\.jl/.*\"$", logs[4].message)

    # Custom log format
    fmt = logfmt"$http_accept $sent_http_content_type $request $request_method $request_uri $remote_addr $remote_port $remote_user $server_protocol $time_iso8601 $time_local $status $body_bytes_sent"
    logs = with_testserver(fmt) do port
        HTTP.get("http://127.0.0.1:$port", ["Accept" => "application/json"])
        HTTP.get("http://127.0.0.1:$port/index.html")
        HTTP.get("http://127.0.0.1:$port/index.html?a=b")
        HTTP.head("http://127.0.0.1:$port")
    end
    @test length(logs) == 4
    @test all(x -> x.group === :access, logs)
    @test occursin(r"^application/json text/plain GET / HTTP/1\.1 GET / 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 12$", logs[1].message)
    @test occursin(r"^\*/\* text/plain GET /index\.html HTTP/1\.1 GET /index\.html 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 12$", logs[2].message)
    @test occursin(r"^\*/\* text/plain GET /index\.html\?a=b HTTP/1\.1 GET /index\.html\?a=b 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 12$", logs[3].message)
    @test occursin(r"^\*/\* text/plain HEAD / HTTP/1\.1 HEAD / 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 0$", logs[4].message)
end