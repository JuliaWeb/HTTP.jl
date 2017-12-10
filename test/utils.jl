@testset "utils.jl" begin

import HTTP.Parsers

@test HTTP.Strings.escapehtml("&\"'<>") == "&amp;&quot;&#39;&lt;&gt;"

@test Parsers.isurlchar('\u81')
@test !Parsers.isurlchar('\0')

for c = '\0':'\x7f'
    if c in ('.', '-', '_', '~')
        @test Parsers.ishostchar(c)
        @test Parsers.ismark(c)
        @test Parsers.isuserinfochar(c)
    elseif c in ('-', '_', '.', '!', '~', '*', '\'', '(', ')')
        @test Parsers.ismark(c)
        @test Parsers.isuserinfochar(c)
    else
        @test !Parsers.ismark(c)
    end
end

@test Parsers.isalphanum('a')
@test Parsers.isalphanum('1')
@test !Parsers.isalphanum(']')

@test Parsers.ishex('a')
@test Parsers.ishex('1')
@test !Parsers.ishex(']')

@test HTTP.Strings.tocameldash!("accept") == "Accept"
@test HTTP.Strings.tocameldash!("Accept") == "Accept"
@test HTTP.Strings.tocameldash!("eXcept-this") == "Except-This"
@test HTTP.Strings.tocameldash!("exCept-This") == "Except-This"
@test HTTP.Strings.tocameldash!("not-valid") == "Not-Valid"
@test HTTP.Strings.tocameldash!("♇") == "♇"
@test HTTP.Strings.tocameldash!("bλ-a") == "Bλ-A"
@test HTTP.Strings.tocameldash!("not fixable") == "Not fixable"
@test HTTP.Strings.tocameldash!("aaaaaaaaaaaaa") == "Aaaaaaaaaaaaa"
@test HTTP.Strings.tocameldash!("conTENT-Length") == "Content-Length"
@test HTTP.Strings.tocameldash!("Sec-WebSocket-Key2") == "Sec-Websocket-Key2"
@test HTTP.Strings.tocameldash!("User-agent") == "User-Agent"
@test HTTP.Strings.tocameldash!("Proxy-authorization") == "Proxy-Authorization"
@test HTTP.Strings.tocameldash!("HOST") == "Host"
@test HTTP.Strings.tocameldash!("ST") == "St"
@test HTTP.Strings.tocameldash!("X-\$PrototypeBI-Version") == "X-\$prototypebi-Version"
@test HTTP.Strings.tocameldash!("DCLK_imp") == "Dclk_imp"


for (bytes, utf8) in (
        (UInt8[], ""),
        (UInt8[0x00], "\0"),
        (UInt8[0x61], "a"),
        (UInt8[0x63, 0x61, 0x66, 0xe9, 0x20, 0x63, 0x72, 0xe8, 0x6d, 0x65], "café crème"),
        (UInt8[0x6e, 0x6f, 0xeb, 0x6c], "noël"),
        # (UInt8[0x6e, 0x6f, 0xeb, 0x6c, 0x20, 0xa4], "noël €"),
        (UInt8[0xc4, 0xc6, 0xe4], "ÄÆä"),
    )
    @test HTTP.Strings.iso8859_1_to_utf8(bytes) == utf8
end

# using StringEncodings
# println(encode("ÄÆä", "ISO-8859-15"))

end
