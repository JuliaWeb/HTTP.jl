@testset "HTTP.ascii" begin

    lc = HTTP.Messages.ascii_lc
    lceq = HTTP.Messages.ascii_lc_isequal

    for c in UInt8(1):UInt8(127)
        @test lc(c) == UInt8(lowercase(Char(c)))
    end

    for c in UInt8(1):UInt8(127)
        @test  lceq(c, c)
        @test !lceq(c, UInt8(c+1))
        @test !lceq(c, UInt8(0))
        @test !lceq(c, UInt8(128))
    end

    @test  lceq("Foo", "Foo")
    @test !lceq("Foo", "Fo")
    @test !lceq("Foo", "Foox")
    @test  lceq("Foo", "foo")
    @test  lceq("foo", "Foo")
    @test  lceq("foo", "FOO")
    @test !lceq("",    "FOO")
    @test !lceq("FOO", "")

    @test  lceq("123!", "123!")
    @test !lceq("123",  "123!")

    @test  lceq("", "")

    @test  lceq("NotAscii: 😬", "NotAscii: 😬")
    @test  lceq("notascii: 😬", "NotAscii: 😬")
end
