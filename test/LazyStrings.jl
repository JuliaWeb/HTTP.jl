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
LazyStrings.isskip(::TestLazyASCIIB, i, c) = c == UInt8('_')
function LazyStrings.isend(s::TestLazyASCIIB, i, c)
    while LazyStrings.isskip(s, i, c)
        i, c = LazyStrings.next_ic(s.s, i)
    end
    return c == UInt8('\n')
end

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

        if pada == 0
        @test map(i->isvalid(x, i), 0:4) == [false, true, true, true, false]
        @test map(i->thisind(x, i), 0:3) == [0, 1, 2, 3]
        @test map(i->prevind(x, i), 1:4) ==    [0, 1, 2, 3]
        @test map(i->nextind(x, i), 0:3) == [1, 2, 3, ncodeunits(x)+1]

        @test map(i->iterate(x, i), 1:4) == [('F', 2),
                                             ('o', 3),
                                             ('o', 4),
                                             nothing]
        end

        @test_throws BoundsError prevind(x, 0)
        @test_throws BoundsError nextind(x, ncodeunits(x)+1)
    end
end

for pada in [0, 1, 7, 1234], padb in [0, 1, 7, 1234]
    s = "Fu_m"
    pads = repeat(" ", pada) * s * "\n" * repeat(" ", padb)

    for x in [TestLazyASCIIB(pads, pada + 1)]

        @test x == "Fum"
        @test x == String(x)
        @test x == SubString(x)

        if pada == 0
        index_valid(x) = i->(isvalid(x, i) ? 1 : 0)
                                          #     F  u  _  m
                                          #  0  1  2  3  4  5
        @test map(index_valid(x), 0:5)   == [0, 1, 1, 1, 0, 0]
        @test map(i->thisind(x, i), 0:4) == [0, 1, 2, 3, 3]
        @test thisind(x, 5) == 3 || thisind(x, 5) == ncodeunits(x) + 1
        @test map(i->prevind(x, i), 1:5) ==    [0, 1, 2, 3, 3]
        @test map(i->nextind(x, i), 0:4) == [1, 2, 3, ncodeunits(x) + 1,
                                                      ncodeunits(x) + 1]

        @test map(i->iterate(x, i), 1:5) == [('F', 2),
                                             ('u', 3),
                                             ('m', 5),
                                             ('m', 5),
                                             nothing]
        end

        @test_throws BoundsError prevind(x, 0)
        @test_throws BoundsError nextind(x, ncodeunits(x) + 1)
    end
end

for pada in [0, 1, 7, 1234], padb in [0, 1, 7, 1234]
    s = "Fu_m_"
    pads = repeat(" ", pada) * s * "\n" * repeat(" ", padb)

    for x in [TestLazyASCIIB(pads, pada + 1)]

        @test x == "Fum"
        @test x == String(x)
        @test x == SubString(x)

        if pada == 0
        index_valid(x) = i->(isvalid(x, i) ? 1 : 0)
        index_isend(x) = i->(LazyStrings.isend(x, x.i + i - 1) ? 1 : 0)
                                          #     F  u  _  m  _
                                          #  0  1  2  3  4  5  6
        @test map(index_valid(x), 0:6)   == [0, 1, 1, 1, 0, 0, 0]
        @test map(index_isend(x), 0:6)   == [0, 0, 0, 0, 0, 1, 1]
        @test map(i->thisind(x, i), 0:4) == [0, 1, 2, 3, 3]
        @test map(i->prevind(x, i), 1:6) ==    [0, 1, 2, 3, 3, 3]
        @test map(i->nextind(x, i), 0:2) == [1, 2, 3]

        @test map(i->iterate(x, i), 1:6) == [('F', 2),
                                             ('u', 3),
                                             ('m', 5),
                                             ('m', 5),
                                             nothing,
                                             nothing]
        end

        @test_throws BoundsError prevind(x, 0)
        @test_throws BoundsError nextind(x, ncodeunits(x) + 1)
    end
end

for pada in [0, 1, 7, 1234], padb in [0, 1, 7, 1234]
    s = " u_m_"
    pads = repeat(" ", pada) * s * "\n" * repeat(" ", padb)

    for x in [TestLazyASCIIB(pads, pada + 1)]

        @test x == "um"
        @test x == String(x)
        @test x == SubString(x)

        if pada == 0
        index_valid(x) = i->(isvalid(x, i) ? 1 : 0)
        index_isend(x) = i->(LazyStrings.isend(x, x.i + i - 1) ? 1 : 0)
                                          #    ' ' u  _  m  _
                                          #  0  1  2  3  4  5  6
        @test map(index_valid(x), 0:6)   == [0, 1, 0, 1, 0, 0, 0]
        @test map(index_isend(x), 0:6)   == [0, 0, 0, 0, 0, 1, 1]
        @test map(i->thisind(x, i), 0:4) == [0, 1, 1, 3, 3]
        @test map(i->prevind(x, i), 1:6) ==    [0, 1, 1, 3, 3, 3]
        @test map(i->nextind(x, i), 0:2) == [1, 3, 3]

        @test map(i->iterate(x, i), 1:6) == [('u', 3),
                                             ('u', 3),
                                             ('m', 5),
                                             ('m', 5),
                                             nothing,
                                             nothing]
        end

        @test_throws BoundsError prevind(x, 0)
        @test_throws BoundsError nextind(x, ncodeunits(x) + 1)
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
