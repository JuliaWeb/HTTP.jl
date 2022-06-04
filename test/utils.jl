import HTTP.Parsers
import HTTP.URIs

@testset "utils.jl" begin
    @test HTTP.Strings.escapehtml("&\"'<>") == "&amp;&quot;&#39;&lt;&gt;"

    @test HTTP.Cookies.isurlchar('\u81')
    @test !HTTP.Cookies.isurlchar('\0')

    @test HTTP.Strings.tocameldash("accept") == "Accept"
    @test HTTP.Strings.tocameldash("Accept") == "Accept"
    @test HTTP.Strings.tocameldash("eXcept-this") == "Except-This"
    @test HTTP.Strings.tocameldash("exCept-This") == "Except-This"
    @test HTTP.Strings.tocameldash("not-valid") == "Not-Valid"
    @test HTTP.Strings.tocameldash("♇") == "♇"
    @test HTTP.Strings.tocameldash("bλ-a") == "Bλ-A"
    @test HTTP.Strings.tocameldash("not fixable") == "Not fixable"
    @test HTTP.Strings.tocameldash("aaaaaaaaaaaaa") == "Aaaaaaaaaaaaa"
    @test HTTP.Strings.tocameldash("conTENT-Length") == "Content-Length"
    @test HTTP.Strings.tocameldash("Sec-WebSocket-Key2") == "Sec-Websocket-Key2"
    @test HTTP.Strings.tocameldash("User-agent") == "User-Agent"
    @test HTTP.Strings.tocameldash("Proxy-authorization") == "Proxy-Authorization"
    @test HTTP.Strings.tocameldash("HOST") == "Host"
    @test HTTP.Strings.tocameldash("ST") == "St"
    @test HTTP.Strings.tocameldash("X-\$PrototypeBI-Version") == "X-\$prototypebi-Version"
    @test HTTP.Strings.tocameldash("DCLK_imp") == "Dclk_imp"

    for (bytes, utf8) in (
            (UInt8[], ""),
            (UInt8[0x00], "\0"),
            (UInt8[0x61], "a"),
            (UInt8[0x63, 0x61, 0x66, 0xe9, 0x20, 0x63, 0x72, 0xe8, 0x6d, 0x65], "café crème"),
            (UInt8[0x6e, 0x6f, 0xeb, 0x6c], "noël"),
            (UInt8[0xc4, 0xc6, 0xe4], "ÄÆä"),
        )
        @test HTTP.Strings.iso8859_1_to_utf8(bytes) == utf8
    end

    withenv("HTTPS_PROXY"=>nothing, "https_proxy"=>nothing) do
        @test HTTP.ConnectionRequest.getproxy("https", "https://julialang.org/") === nothing
    end
    withenv("HTTPS_PROXY"=>"") do
        # to be compatible with Julia 1.0
        @test HTTP.ConnectionRequest.getproxy("https", "https://julialang.org/") === nothing
    end
    withenv("https_proxy"=>"") do
        @test HTTP.ConnectionRequest.getproxy("https", "https://julialang.org/") === nothing
    end
    withenv("HTTPS_PROXY"=>"https://user:pass@server:80") do
        @test HTTP.ConnectionRequest.getproxy("https", "https://julialang.org/") == "https://user:pass@server:80"
    end
    withenv("https_proxy"=>"https://user:pass@server:80") do
        @test HTTP.ConnectionRequest.getproxy("https", "https://julialang.org/") == "https://user:pass@server:80"
    end

    withenv("HTTP_PROXY"=>nothing, "http_proxy"=>nothing) do
        @test HTTP.ConnectionRequest.getproxy("http", "http://julialang.org/") === nothing
    end
    withenv("HTTP_PROXY"=>"") do
        @test HTTP.ConnectionRequest.getproxy("http", "http://julialang.org/") === nothing
    end
    withenv("http_proxy"=>"") do
        @test HTTP.ConnectionRequest.getproxy("http", "http://julialang.org/") === nothing
    end
    withenv("HTTP_PROXY"=>"http://user:pass@server:80") do
        @test HTTP.ConnectionRequest.getproxy("http", "http://julialang.org/") == "http://user:pass@server:80"
    end
    withenv("http_proxy"=>"http://user:pass@server:80") do
        @test HTTP.ConnectionRequest.getproxy("http", "http://julialang.org/") == "http://user:pass@server:80"
    end
end # testset


@testset "Conditions" begin
    function foo(x, y)
        HTTP.@require x > 10
        HTTP.@ensure y > 10
    end

    @test_throws ArgumentError("foo() requires `x > 10`") foo(1, 11)
    @test_throws AssertionError("foo() failed to ensure `y > 10`\ny = 1\n10 = 10") foo(11, 1)
end
