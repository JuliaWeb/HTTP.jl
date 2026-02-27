@testset "utils.jl" begin
    @test HTTP.escapehtml("&\"'<>") == "&amp;&quot;&#39;&lt;&gt;"

    @test HTTP.tocameldash("accept") == "Accept"
    @test HTTP.tocameldash("Accept") == "Accept"
    @test HTTP.tocameldash("eXcept-this") == "Except-This"
    @test HTTP.tocameldash("exCept-This") == "Except-This"
    @test HTTP.tocameldash("not-valid") == "Not-Valid"
    @test HTTP.tocameldash("♇") == "♇"
    @test HTTP.tocameldash("bλ-a") == "Bλ-A"
    @test HTTP.tocameldash("not fixable") == "Not fixable"
    @test HTTP.tocameldash("aaaaaaaaaaaaa") == "Aaaaaaaaaaaaa"
    @test HTTP.tocameldash("conTENT-Length") == "Content-Length"
    @test HTTP.tocameldash("Sec-WebSocket-Key2") == "Sec-Websocket-Key2"
    @test HTTP.tocameldash("User-agent") == "User-Agent"
    @test HTTP.tocameldash("Proxy-authorization") == "Proxy-Authorization"
    @test HTTP.tocameldash("HOST") == "Host"
    @test HTTP.tocameldash("ST") == "St"
    @test HTTP.tocameldash("X-\$PrototypeBI-Version") == "X-\$prototypebi-Version"
    @test HTTP.tocameldash("DCLK_imp") == "Dclk_imp"

    for (bytes, utf8) in (
            (UInt8[], ""),
            (UInt8[0x00], "\0"),
            (UInt8[0x61], "a"),
            (UInt8[0x63, 0x61, 0x66, 0xe9, 0x20, 0x63, 0x72, 0xe8, 0x6d, 0x65], "café crème"),
            (UInt8[0x6e, 0x6f, 0xeb, 0x6c], "noël"),
            (UInt8[0xc4, 0xc6, 0xe4], "ÄÆä"),
        )
        @test HTTP.iso8859_1_to_utf8(bytes) == utf8
    end

    buf = UInt8[0x01, 0x02]
    @test HTTP.bytes(buf) === buf
    @test collect(HTTP.bytes("hi")) == collect(codeunits("hi"))
    @test HTTP.nbytes("hi") == 2
    @test HTTP.nbytes(buf) == 2
    @test HTTP.nbytes([buf, UInt8[0x03]]) == 3
    @test HTTP.nbytes(["a", "bc"]) == 3
    @test HTTP.nbytes(IOBuffer("abc")) == 3
    @test HTTP.nobytes isa AbstractVector{UInt8}
    @test isempty(HTTP.nobytes)
    @test HTTP.ascii_lc_isequal("AbC", "aBc")
    @test !HTTP.ascii_lc_isequal("abc", "abd")

    err = HTTP.ConnectError("http://example.com", ErrorException("boom"))
    @test err isa HTTP.ConnectError
    @test err.url == "http://example.com"
    @test err.error isa ErrorException
    @test HTTP.TimeoutError(5).readtimeout == 5
    req = HTTP.Request("GET", "/")
    req_err = HTTP.RequestError(req, ErrorException("nope"))
    @test req_err.request === req
    @test req_err.error isa ErrorException
    msg = ""
    try
        error("boom")
    catch
        msg = HTTP.current_exceptions_to_string()
    end
    @test occursin("boom", msg)
    got = false
    HTTP.@try ArgumentError begin
        got = true
        throw(ArgumentError("boom"))
    end
    @test got

    # parseuri now delegates to URIs.jl (no C-level allocator needed)
    @test HTTP.parseuri("http://example.com/path", nothing) isa URIs.URI

    exported = names(HTTP, all=false)
    @test :startwrite in exported
    @test :startread in exported
    @test :closewrite in exported
    @test :closeread in exported
    @test :Stream in exported
    @test :Request in exported
    @test :Response in exported
    @test :Message in exported
    @test :Header in exported
    @test :Headers in exported
    @test :header in exported
    @test :headers in exported
    @test :hasheader in exported
    @test :setheader in exported
    @test :appendheader in exported
    @test :removeheader in exported
    @test :bytes in exported
    @test :nbytes in exported
    @test :nobytes in exported
    @test :escapehtml in exported
    @test :tocameldash in exported
    @test :iso8859_1_to_utf8 in exported
    @test :ascii_lc_isequal in exported

    req = HTTP.Request("GET", "/")
    HTTP.setheader(req, "X-Test" => "a")
    @test HTTP.header(req, "X-Test") == "a"
    HTTP.appendheader(req, "X-Test" => "b")
    @test HTTP.headers(req, "X-Test") == ["a", "b"]
    HTTP.removeheader(req, "X-Test")
    @test HTTP.header(req, "X-Test") == ""
    @test HTTP.nobody isa Vector{UInt8}
    @test isempty(HTTP.nobody)
    @test isdefined(HTTP, :streamhandler)

    @test_deprecated HTTP.escape("a b") == "a%20b"

    @testset "AwsHTTP method mapping" begin
        @test HTTP.AwsHTTP.http_str_to_method("GET") == HTTP.AwsHTTP.HttpMethod.GET
        @test HTTP.AwsHTTP.http_str_to_method("HEAD") == HTTP.AwsHTTP.HttpMethod.HEAD
        @test HTTP.AwsHTTP.http_str_to_method("POST") == HTTP.AwsHTTP.HttpMethod.POST
        @test HTTP.AwsHTTP.http_str_to_method("PUT") == HTTP.AwsHTTP.HttpMethod.PUT
        @test HTTP.AwsHTTP.http_str_to_method("DELETE") == HTTP.AwsHTTP.HttpMethod.DELETE
        @test HTTP.AwsHTTP.http_str_to_method("CONNECT") == HTTP.AwsHTTP.HttpMethod.CONNECT
        @test HTTP.AwsHTTP.http_str_to_method("OPTIONS") == HTTP.AwsHTTP.HttpMethod.OPTIONS
        @test HTTP.AwsHTTP.http_str_to_method("TRACE") == HTTP.AwsHTTP.HttpMethod.TRACE
        @test HTTP.AwsHTTP.http_str_to_method("PATCH") == HTTP.AwsHTTP.HttpMethod.PATCH
        @test HTTP.AwsHTTP.http_str_to_method("post") == HTTP.AwsHTTP.HttpMethod.UNKNOWN
        @test HTTP.AwsHTTP.http_str_to_method("CUSTOM") == HTTP.AwsHTTP.HttpMethod.UNKNOWN
    end

    @testset "download" begin
        server = HTTP.serve!(req -> HTTP.Response(200, ["Content-Disposition" => "attachment; filename=\"hello.txt\""], "hello"); listenany=true)
        try
            port = HTTP.port(server)
            mktempdir() do dir
                file = HTTP.download("http://127.0.0.1:$port/hello.txt", dir)
                @test isfile(file)
                @test basename(file) == "hello.txt"
                @test String(read(file)) == "hello"
            end
        finally
            close(server)
        end
    end
end # testset
