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

@test HTTP.canonicalize!("accept") == "Accept"
@test HTTP.canonicalize!("Accept") == "Accept"
@test HTTP.canonicalize!("eXcept-this") == "Except-This"
@test HTTP.canonicalize!("exCept-This") == "Except-This"
@test HTTP.canonicalize!("not-valid") == "Not-Valid"
@test HTTP.canonicalize!("♇") == "♇"
@test HTTP.canonicalize!("bλ-a") == "Bλ-A"
@test HTTP.canonicalize!("not fixable") == "Not fixable"
@test HTTP.canonicalize!("aaaaaaaaaaaaa") == "Aaaaaaaaaaaaa"
@test HTTP.canonicalize!("conTENT-Length") == "Content-Length"
@test HTTP.canonicalize!("Sec-WebSocket-Key2") == "Sec-Websocket-Key2"
@test HTTP.canonicalize!("User-agent") == "User-Agent"
@test HTTP.canonicalize!("Proxy-authorization") == "Proxy-Authorization"
@test HTTP.canonicalize!("HOST") == "Host"
@test HTTP.canonicalize!("ST") == "St"
@test HTTP.canonicalize!("X-\$PrototypeBI-Version") == "X-\$prototypebi-Version"
@test HTTP.canonicalize!("DCLK_imp") == "Dclk_imp"

end