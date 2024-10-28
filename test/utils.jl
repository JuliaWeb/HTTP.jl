@testset "ascii" begin
    lc = HTTP.ascii_lc
    lceq = HTTP.ascii_lc_isequal

    @testset "UInt8" begin
        for c in UInt8(1):UInt8(127)
            @test lc(c) == UInt8(lowercase(Char(c)))
            @test lceq(c, c)

            @test !lceq(c, UInt8(c+1))
            @test !lceq(c, UInt8(0))
            @test !lceq(c, UInt8(128))
        end
    end

    @testset "Strings" begin
        @test lceq("", "")

        @test lceq("123!", "123!")
        @test lceq("Foo", "Foo")
        @test lceq("Foo", "foo")
        @test lceq("foo", "Foo")
        @test lceq("foo", "FOO")

        @test !lceq("",    "FOO")
        @test !lceq("FOO", "")
        @test !lceq("Foo", "Fo")
        @test !lceq("Foo", "Foox")
        @test !lceq("123",  "123!")
    end

    @testset "Emojis" begin
        @test lceq("NotAscii: 😬", "NotAscii: 😬")
        @test lceq("notascii: 😬", "NotAscii: 😬")
    end
end

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
end # testset