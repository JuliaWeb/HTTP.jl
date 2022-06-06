using HTTP.Strings

@testset "ascii.jl" begin
    lc = HTTP.Strings.ascii_lc
    lceq = HTTP.Strings.ascii_lc_isequal

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
