using Test
using HTTP
using Reseau

const HT = HTTP

function _read_all_handler_bytes(body::HT.AbstractBody)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 64)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
end

_read_all_handler_bytes(body::AbstractVector{UInt8}) = Vector{UInt8}(body)

function _response_with_text(text::AbstractString; status::Integer = 200)::HT.Response
    bytes = collect(codeunits(String(text)))
    return HT.Response(status, HT.BytesBody(bytes); content_length = length(bytes))
end

function _streamhandler_echo_request(req)
    body_text = String(_read_all_handler_bytes(req.body))
    return _response_with_text(isempty(body_text) ? "ping" : body_text)
end

_router_hello_request(req) = _response_with_text("hello:" * HT.getparam(req, "name"))

function _router_echo_request(req)
    payload = String(_read_all_handler_bytes(req.body))
    return _response_with_text("echo:" * HT.getparam(req, "name") * ":" * payload)
end

function _router_stream_request(stream)
    req = HT.startread(stream)
    payload = read(stream, String)
    HT.setstatus(stream, 200)
    HT.setheader(stream, "Content-Type", "text/plain")
    write(stream, "stream:" * HT.getparam(req, "name") * ":" * payload)
    return nothing
end

@testset "HTTP handlers router direct matching" begin
    called = Ref(false)
    middle = handler -> req -> begin
        called[] = true
        return handler(req)
    end
    router = HT.Router(_ -> 0, _ -> -1, middle)

    HT.register!(router, "/test", _ -> 1)
    @test router(HT.Request("GET", "/test")) == 1
    @test called[]

    HT.register!(router, "/path/to/greatness", _ -> 2)
    @test router(HT.Request("GET", "/path/to/greatness")) == 2

    HT.register!(router, "/next/path/to/greatness", _ -> 3)
    @test router(HT.Request("GET", "/next/path/to/greatness")) == 3

    HT.register!(router, "GET", "/sget", _ -> 4)
    HT.register!(router, "POST", "/spost", _ -> 5)
    HT.register!(router, "POST", "/tpost", _ -> 6)
    HT.register!(router, "GET", "/tpost", _ -> 7)
    @test router(HT.Request("GET", "/sget")) == 4
    called[] = false
    @test router(HT.Request("POST", "/sget")) == -1
    @test !called[]
    @test router(HT.Request("GET", "/spost")) == -1
    @test router(HT.Request("POST", "/spost")) == 5
    @test router(HT.Request("POST", "/tpost")) == 6
    @test router(HT.Request("GET", "/tpost")) == 7

    HT.register!(router, "/test/*", _ -> 8)
    HT.register!(router, "/test/sarv/ghotra", _ -> 9)
    HT.register!(router, "/test/*/ghotra/seven", _ -> 10)
    @test router(HT.Request("GET", "/test/sarv")) == 8
    @test router(HT.Request("GET", "/test/sarv/ghotra")) == 9
    @test router(HT.Request("GET", "/test/sarv/ghotra/seven")) == 10
    @test router(HT.Request("GET", "/test/foo")) == 8

    HT.register!(router, "/api/issue/{issue_id}", req -> HT.getparams(req)["issue_id"])
    @test router(HT.Request("GET", "/api/issue/871")) == "871"

    widget_id_router = HT.Router()
    HT.register!(widget_id_router, "/api/widgets/{id}", req -> HT.getparam(req, "id"))
    @test widget_id_router(HT.Request("GET", "/api/widgets/11")) == "11"

    widget_name_router = HT.Router()
    HT.register!(widget_name_router, "/api/widgets/{name}", req -> (HT.getparam(req, "name"), HT.getroute(req)))
    @test widget_name_router(HT.Request("GET", "/api/widgets/11")) == ("11", "/api/widgets/{name}")

    acme_router = HT.Router(_ -> 0, _ -> -1, middle)
    HT.register!(acme_router, "/api/widgets/acme/{id:[a-z]+}", req -> HT.getparam(req, "id"))
    called[] = false
    @test acme_router(HT.Request("GET", "/api/widgets/acme/11")) == 0
    @test acme_router(HT.Request("GET", "/api/widgets/acme/abc123")) == 0
    @test !called[]
    @test acme_router(HT.Request("GET", "/api/widgets/acme/abc")) == "abc"

    numeric_router = HT.Router(_ -> 0, _ -> -1, middle)
    HT.register!(numeric_router, "/users/{id:[0-9]+}", req -> HT.getparam(req, "id"))
    @test numeric_router(HT.Request("GET", "/users/123")) == "123"
    @test numeric_router(HT.Request("GET", "/users/123abc")) == 0
    @test numeric_router(HT.Request("GET", "/users/abc123")) == 0

    HT.register!(router, "/test/**", _ -> 11)
    @test router(HT.Request("GET", "/test/foo/foobar")) == 11
    @test router(HT.Request("GET", "/test/foo/foobar/baz")) == 11
    @test router(HT.Request("GET", "/test/foo/foobar/baz/sailor")) == 11
    @test_throws ErrorException HT.register!(router, "/test/**/foo", _ -> 11)

    subwidget_router = HT.Router()
    HT.register!(subwidget_router, "/api/widgets/{name:[a-z]+}/subwidgetsbyname", _ -> 12)
    HT.register!(subwidget_router, "/api/widgets/{id:[0-9]+}/subwidgetsbyid", _ -> 13)
    HT.register!(subwidget_router, "/api/widgets/{id}", _ -> 14)
    HT.register!(subwidget_router, "/api/widgets/{subId}/subwidget", _ -> 15)
    HT.register!(subwidget_router, "/api/widgets/{subName}/subwidgetname", _ -> 16)
    @test subwidget_router(HT.Request("GET", "/api/widgets/abc/subwidgetsbyname")) == 12
    @test subwidget_router(HT.Request("GET", "/api/widgets/123/subwidgetsbyid")) == 13
    @test subwidget_router(HT.Request("GET", "/api/widgets/234")) == 14
    @test subwidget_router(HT.Request("GET", "/api/widgets/abc/subwidget")) == 15
    @test subwidget_router(HT.Request("GET", "/api/widgets/abc/subwidgetname")) == 16

    query_router = HT.Router()
    HT.register!(query_router, "/api/widgets/{name}", req -> (HT.getparam(req, "name"), HT.getroute(req)))
    @test query_router(HT.Request("GET", "/api/widgets/55?expand=true")) == ("55", "/api/widgets/{name}")
    @test query_router(HT.Request("GET", "http://example.test/api/widgets/77?expand=true")) == ("77", "/api/widgets/{name}")
end

@testset "HTTP handlers cookie middleware" begin
    headers = HT.Headers()
    HT.setheader(headers, "Cookie", "abc=def; mode=test")
    req = HT.Request("GET", "/"; headers = headers)
    cookies = HT.Handlers.cookie_middleware(req -> HT.getcookies(req))(req)
    @test length(cookies) == 2
    @test cookies[1].name == "abc"
    @test cookies[1].value == "def"
    @test cookies[2].name == "mode"
    @test cookies[2].value == "test"
    @test HT.getcookies(req) === cookies
end

@testset "HTTP handlers request timeout middleware" begin
    fast = HT.Handlers.handlertimeout(5.0)(req -> begin
        _ = req
        return _response_with_text("ok")
    end)
    fast_resp = fast(HT.Request("GET", "/"))
    @test fast_resp.status == 200
    @test String(_read_all_handler_bytes(fast_resp.body)) == "ok"

    slow = HT.Handlers.handlertimeout(0.02; status = 504, body = "custom timeout")(req -> begin
        _ = req
        sleep(0.1)
        return _response_with_text("late")
    end)
    slow_resp = slow(HT.Request("GET", "/"))
    @test slow_resp.status == 504
    @test HT.header(slow_resp.headers, "Content-Type") == "text/plain; charset=utf-8"
    @test String(_read_all_handler_bytes(slow_resp.body)) == "custom timeout"
end

@testset "HTTP streamhandler helper" begin
    server = HT.listen!(HT.streamhandler(_streamhandler_echo_request), "127.0.0.1", 0; listenany = true)
    address = HT.server_addr(server)
    try
        resp = HT.get("http://$(address)/")
        @test resp.status == 200
        @test String(_read_all_handler_bytes(resp.body)) == "ping"

        resp = HT.post("http://$(address)/"; body = "echo")
        @test resp.status == 200
        @test String(_read_all_handler_bytes(resp.body)) == "echo"
    finally
        HT.forceclose(server)
        wait(server)
    end
end

@testset "HTTP streamhandler reused String response body" begin
    baked = HT.Response(200, ["Content-Type" => "text/plain"]; body = "baked string body")
    server = HT.listen!(HT.streamhandler(_ -> baked), "127.0.0.1", 0; listenany = true)
    address = HT.server_addr(server)
    try
        resp = HT.get("http://$(address)/")
        @test resp.status == 200
        @test String(_read_all_handler_bytes(resp.body)) == "baked string body"

        reused = HT.get("http://$(address)/"; status_exception = false, retry = false)
        @test reused.status == 500
    finally
        HT.forceclose(server)
        wait(server)
    end
end

@testset "HTTP streamhandler ignores closed bodies when no body is written" begin
    for (method, status, bytes) in (
        ("GET", 200, UInt8[]),
        ("GET", 204, collect(codeunits("ignored body"))),
        ("HEAD", 200, collect(codeunits("head body"))),
    )
        body = HT.BytesBody(bytes)
        HT.body_close!(body)
        baked = HT.Response(status, body; content_length = length(bytes))
        server = HT.listen!(HT.streamhandler(_ -> baked), "127.0.0.1", 0; listenany = true)
        address = HT.server_addr(server)
        try
            resp = HT.request(method, "http://$(address)/"; status_exception = false, retry = false)
            @test resp.status == status
            @test isempty(_read_all_handler_bytes(resp.body))
        finally
            HT.forceclose(server)
            wait(server)
        end
    end
end

@testset "HTTP router live request handler server" begin
    router = HT.Router()
    HT.register!(router, "GET", "/hello/{name}", _router_hello_request)
    HT.register!(router, "QUERY", "/search/{name}", _router_echo_request)
    HT.register!(router, "POST", "/echo/{name}", _router_echo_request)

    server = HT.serve!(router, "127.0.0.1", 0; listenany = true)
    address = HT.server_addr(server)
    try
        hello = HT.get("http://$(address)/hello/jane?lang=en")
        @test hello.status == 200
        @test String(_read_all_handler_bytes(hello.body)) == "hello:jane"

        query = HT.query("http://$(address)/search/jane"; body = (q = "ping",))
        @test query.status == 200
        @test String(_read_all_handler_bytes(query.body)) == "echo:jane:q=ping"

        echo = HT.post("http://$(address)/echo/jane"; body = "ping")
        @test echo.status == 200
        @test String(_read_all_handler_bytes(echo.body)) == "echo:jane:ping"

        missing_method = HT.request("PUT", "http://$(address)/hello/jane"; status_exception = false)
        @test missing_method.status == 405

        missing_route = HT.get("http://$(address)/missing"; status_exception = false)
        @test missing_route.status == 404
    finally
        HT.forceclose(server)
        wait(server)
    end
end

@testset "HTTP router live stream handler server" begin
    router = HT.Router()
    HT.register!(router, "POST", "/stream/{name}", _router_stream_request)

    server = HT.listen!(router, "127.0.0.1", 0; listenany = true)
    address = HT.server_addr(server)
    try
        resp = HT.post("http://$(address)/stream/sam"; body = "pong")
        @test resp.status == 200
        @test String(_read_all_handler_bytes(resp.body)) == "stream:sam:pong"

        wrong_method = HT.get("http://$(address)/stream/sam"; status_exception = false)
        @test wrong_method.status == 405
    finally
        HT.forceclose(server)
        wait(server)
    end
end
