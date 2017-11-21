@testset "utils.jl" begin

@test HTTP.escapeHTML("&\"'<>") == "&amp;&quot;&#39;&lt;&gt;"

@test HTTP.isurlchar('\u81')
@test !HTTP.isurlchar('\0')

for c = '\0':'\x7f'
    if c in ('.', '-', '_', '~')
        @test HTTP.ishostchar(c)
        @test HTTP.ismark(c)
        @test HTTP.isuserinfochar(c)
    elseif c in ('-', '_', '.', '!', '~', '*', '\'', '(', ')')
        @test HTTP.ismark(c)
        @test HTTP.isuserinfochar(c)
    else
        @test !HTTP.ismark(c)
    end
end

@test HTTP.isalphanum('a')
@test HTTP.isalphanum('1')
@test !HTTP.isalphanum(']')

@test HTTP.ishex('a')
@test HTTP.ishex('1')
@test !HTTP.ishex(']')

@test HTTP.tocameldash!("accept") == "Accept"
@test HTTP.tocameldash!("Accept") == "Accept"
@test HTTP.tocameldash!("eXcept-this") == "Except-This"
@test HTTP.tocameldash!("exCept-This") == "Except-This"
@test HTTP.tocameldash!("not-valid") == "Not-Valid"
@test HTTP.tocameldash!("♇") == "♇"
@test HTTP.tocameldash!("bλ-a") == "Bλ-A"
@test HTTP.tocameldash!("not fixable") == "Not fixable"
@test HTTP.tocameldash!("aaaaaaaaaaaaa") == "Aaaaaaaaaaaaa"
@test HTTP.tocameldash!("conTENT-Length") == "Content-Length"
@test HTTP.tocameldash!("Sec-WebSocket-Key2") == "Sec-Websocket-Key2"
@test HTTP.tocameldash!("User-agent") == "User-Agent"
@test HTTP.tocameldash!("Proxy-authorization") == "Proxy-Authorization"
@test HTTP.tocameldash!("HOST") == "Host"
@test HTTP.tocameldash!("ST") == "St"
@test HTTP.tocameldash!("X-\$PrototypeBI-Version") == "X-\$prototypebi-Version"
@test HTTP.tocameldash!("DCLK_imp") == "Dclk_imp"


for (bytes, utf8) in (
        (UInt8[], ""),
        (UInt8[0x00], "\0"),
        (UInt8[0x61], "a"),
        (UInt8[0x63, 0x61, 0x66, 0xe9, 0x20, 0x63, 0x72, 0xe8, 0x6d, 0x65], "café crème"),
        (UInt8[0x6e, 0x6f, 0xeb, 0x6c], "noël"),
        # (UInt8[0x6e, 0x6f, 0xeb, 0x6c, 0x20, 0xa4], "noël €"),
        (UInt8[0xc4, 0xc6, 0xe4], "ÄÆä"),
    )
    @test HTTP.iso8859_1_to_utf8(bytes) == utf8
end

# using StringEncodings
# println(encode("ÄÆä", "ISO-8859-15"))

end
