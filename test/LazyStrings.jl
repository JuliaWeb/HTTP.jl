using HTTP

using HTTP.LazyStrings

import .LazyStrings.LazyString
import .LazyStrings.LazyASCII

using Test
#using InteractiveUtils


struct TestLazy{T} <: LazyString
    s::T
    i::Int
end

LazyStrings.isend(::TestLazy, i, c) = c == '\n'

struct TestLazyASCII{T} <: LazyASCII
    s::T
    i::Int
end

LazyStrings.findstart(s::TestLazyASCII) = findnext(c->c != ' ', s.s, s.i)
LazyStrings.isend(::TestLazyASCII, i, c) = c == UInt8('\n')

struct TestLazyASCIIB{T} <: LazyASCII
    s::T
    i::Int
end

LazyStrings.findstart(s::TestLazyASCIIB) = findnext(c->c != ' ', s.s, s.i)
LazyStrings.isend(::TestLazyASCIIB, i, c) = c == UInt8('\n')
LazyStrings.isskip(::TestLazyASCIIB, i, c) = c == UInt8('_')

struct TestLazyASCIIC{T} <: LazyASCII
    s::T
    i::Int
end

LazyStrings.isend(::TestLazyASCIIC, i, c) = c == UInt8('\n')

@testset "LazyStrings" begin

@test TestLazy(" Foo", 2) == "Foo"

@test TestLazy(" Foo\n ", 2) == "Foo"


for pada in [0, 1, 7, 1234], padb in [0, 1, 7, 1234]
    s = "Foo"
    pads = repeat(" ", pada) * s * "\n" * repeat(" ", padb)

    for x in [s, TestLazyASCII(pads, pada + 1)]

        @test x == "Foo"
        @test x == String(x)
        @test x == SubString(x)

        @test map(i->isvalid(x, i), 0:4) == [false, true, true, true, false]
        @test map(i->thisind(x, i), 0:4) == [0, 1, 2, 3, 4]
        @test map(i->prevind(x, i), 1:4) == [0, 1, 2, 3]
        @test map(i->nextind(x, i), 0:3) == [1, 2, 3, 4]

        @test map(i->iterate(x, i), 1:4) == [('F', 2),
                                             ('o', 3),
                                             ('o', 4),
                                             nothing]

        @test_throws BoundsError prevind(x, 0)
        @test_throws BoundsError nextind(x, 4)
    end
end

for pada in [0, 1, 7, 1234], padb in [0, 1, 7, 1234]
    s = "Fu_m"
    pads = repeat(" ", pada) * s * "\n" * repeat(" ", padb)

    for x in [TestLazyASCIIB(pads, pada + 1)]

        @test x == "Fum"
        @test x == String(x)
        @test x == SubString(x)

        @test map(i->isvalid(x, i), 0:5) == [false, true, true, false, true, false]
        @test map(i->thisind(x, i), 0:5) == [0, 1, 2, 2, 4, 5]
        @test map(i->prevind(x, i), 1:5) == [0, 1, 2, 2, 4]
        @test map(i->nextind(x, i), 0:4) == [1, 2, 4, 4, 5]

        @test map(i->iterate(x, i), 1:5) == [('F', 2),
                                             ('u', 3),
                                             ('m', 5),
                                             ('m', 5),
                                             nothing]

        @test_throws BoundsError prevind(x, 0)
        @test_throws BoundsError nextind(x, 5)
    end
end

for pada in [0, 1, 7, 1234], padb in [0, 1, 7, 1234]
    s = "Fu_m_"
    pads = repeat(" ", pada) * s * "\n" * repeat(" ", padb)

    for x in [TestLazyASCIIB(pads, pada + 1)]

        @test x == "Fum"
        @test x == String(x)
        @test x == SubString(x)

        @test map(i->isvalid(x, i), 0:6) == [false, true, true, false, true, false, false]
        @test map(i->thisind(x, i), 0:6) == [0, 1, 2, 2, 4, 4, 6]
        @test map(i->prevind(x, i), 1:6) == [0, 1, 2, 2, 4, 4]
        @test map(i->nextind(x, i), 0:5) == [1, 2, 4, 4, 6, 6]

        @test map(i->iterate(x, i), 1:6) == [('F', 2),
                                             ('u', 3),
                                             ('m', 5),
                                             ('m', 5),
                                             nothing,
                                             nothing]

        @test_throws BoundsError prevind(x, 0)
        @test_throws BoundsError nextind(x, 6)
    end
end

@test TestLazyASCIIC("Foo", 1) == "Foo"
@test TestLazyASCIIC(" Foo\n ", 1) == " Foo"

s = TestLazyASCIIC(" Foo\n ", 1)

str = Base.StringVector(6)

#@code_native iterate(s)
#@code_warntype iterate(s)
#@code_native iterate(s, 1)
#@code_warntype iterate(s, 1)

end # testset "LazyStrings"
