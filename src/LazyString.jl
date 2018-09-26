"""
This module defines `AbstractString` methods for accessing sub-strings whose
length is not known in advance. Length is lazily determined during iteration.
`LazyString` is intended for use by lazy parsers. A parser that has identified
the start of a syntax element (but not the end) can return a `LazyString`.
The `LazyString` encapsulates the source string and start index but defers
parsng until the string value is accessed via the `AbstractString` interface.

e.g.

```
struct TokenString{T} <: LazyString
    s::T
    i::Int
end

LazyStrings.isend(::TokenString, i, c) = isspace(c)

TokenString("one two three", 5) == "two"
```


A `LazyASCII` is a `LazyString` specialised for ASCII strings.

e.g.

```
struct FieldName{T} <: LazyASCII
    s::T
    i::Int
end

LazyStrings.findstart(s::FieldName) = findnext(c -> c != ' ', s.s, s.i)
LazyStrings.isend(::FieldName, i, c) = c == UInt8(':')

FieldName("  foo: bar", 1) == "foo"
```

"""
module LazyStrings

export LazyString, LazyASCII

const WARN_FULL_ITERATION_OF_LAZY_STRING = true



# LazyString

abstract type LazyString <: AbstractString end


isend(s::LazyString, i, c) = false


"""
Iterate over the characers of `s`.
Return first index, last index and number of characters.
"""
@inline function scan_string(s::LazyString)
    frist = iterate(s)
    last = 0
    i = first
    n = 0
    while i != nothing
        c, last = i
        i = iterate(s, last)
        n += 1
    end
    return s.i, s.i + last - 1, n
end


Base.IteratorSize(::Type{T}) where T <: LazyString = Base.SizeUnknown()

Base.codeunit(s::LazyString) = codeunit(s.s)

Base.codeunit(s::LazyString, i::Integer) = codeunit(s.s, s.i + i -1)

Base.ncodeunits(s::LazyString) = ncodeunits(s.s) + 1 - s.i

Base.isvalid(s::LazyString, i::Integer) = isvalid(s.s, s.i + i - 1)


function Base.lastindex(s::LazyString)

    if WARN_FULL_ITERATION_OF_LAZY_STRING
        @warn "Full iteration of LazyString " *
              "lastindex(::$(typeof(s)))!" stacktrace()
    end

    first, last, n = scan_string(s)
    return last
end


function Base.iterate(s::LazyString, i::Int = 1)
    next = iterate(s.s, s.i + i - 1)
    if next == nothing
        return nothing
    end
    c, i = next
    if isend(s, i, c)
        return nothing
    end
    return c, i + 1 - s.i
end


function Base.convert(::Type{SubString}, s::LazyString)
    first, last, count = scan_string(s)
    if count == last - first + 1
        return SubString(s.s, first, last)
    else
        str = Base.StringVector(count)
        copyto!(str, codeunits(s))
        return SubString(String(str))
    end
end


Base.convert(::Type{String}, s::LazyString) =
    convert(String, convert(SubString, s))


Base.String(s::LazyString) = convert(String, s)
Base.SubString(s::LazyString) = convert(SubString, s)



# LazyASCII

abstract type LazyASCII <: LazyString end


"""
Does character `c` at index `i` mark the end of the sub-string?
"""
isend(s::LazyASCII, i) = isend(s, i, getc(s.s, s.i + i - 1))
isend(::LazyASCII, i, c) = false


"""
Should character `c` at index `i` be ignored?
"""
isskip(s::LazyASCII, i) = isskip(s, i, getc(s.s, s.i + i - 1))
isskip(::LazyASCII, i, c) = false

"""
Translate character `c` to something else.
"""
replace(::LazyASCII, i, c) = c, 0


"""
Find the index of the first character of the sub-string.
"""
findstart(s::LazyASCII) = s.i


"""
Read a character from ASCII string `s` at index `i` with no bounds check.
"""
getc(s, i) = unsafe_load(pointer(s), i)


"""
Increment `i`, read a character, return new `i` and the character.
"""
next_ic(s, i) = (i += 1; (i, getc(s, i)))


"""
Iterate over the characers of `s`.
Return first index, last index and number of characters.
"""
function scan_string(s::LazyASCII)

    ss = s.s
    i = findstart(s)
    first = i
    n = 0
    c = getc(ss, first)
    last = ncodeunits(ss)
    while i <= last && !isend(s, i, c)
        if !isskip(s, i, c)
            n += 1
        end
        c, r = replace(s, i, c)
        n -= r
        i, c = next_ic(ss, i)
    end

    return first, i-1, n
end


"""
Convert ASCII byte `c` to `Char`.
`0x8n` maps to `'\x8n'` (not `'\u8n'`).
"""
ascii_char(c::UInt8) = reinterpret(Char, (c % UInt32) << 24)

Base.iterate(s::LazyASCII, i::Int = 1) = _iterate(ascii_char, s, i)

function _iterate(character, s::LazyASCII, i)
    ss = s.s
    si = i == 1 ? findstart(s) : s.i + i - 1
    if si > ncodeunits(ss)
        return nothing
    end
    c = getc(ss, si)
    if isend(s, si, c)
        return nothing
    end
    while isskip(s, si, c)
        si, c = next_ic(ss, si)
    end
    if isend(s, si, c)
        return nothing
    end
    c, n = replace(s, si, c)
    si += n
    return character(c), si + 2 - s.i
end


Base.codeunits(s::LazyASCII) = LazyASCIICodeUnits(s)

struct LazyASCIICodeUnits{S<:LazyASCII}
    s::S
end

Base.IteratorSize(::Type{T}) where T <: LazyASCIICodeUnits = Base.SizeUnknown()

Base.iterate(s::LazyASCIICodeUnits, i::Integer = 1) = _iterate(identity, s.s, i)


function Base.isvalid(s::LazyASCII, i::Integer)
    if i == 1
        return true
    end
    si = s.i + i - 1
    if si < findstart(s) || isend(s, i) || isskip(s, i)
        return false
    end
    return isvalid(s.s, si)
end


function Base.thisind(s::LazyASCII, i::Int)
    if i > 1 && isend(s, i)
        return i
    end
    z = ncodeunits(s) + 1
    @boundscheck 0 ≤ i ≤ z || throw(BoundsError(s, i))
    @inbounds while 1 < i && !isvalid(s, i)
        i -= 1
    end
    return i
end


function Base.nextind(s::LazyASCII, i::Int, n::Int)
    n < 0 && throw(ArgumentError("n cannot be negative: $n"))
    if isend(s, i)
        throw(BoundsError(s, i))
    end
    z = ncodeunits(s)
    @boundscheck 0 ≤ i ≤ z || throw(BoundsError(s, i))
    n == 0 && return thisind(s, i) == i ? i : string_index_err(s, i)
    while n > 0 && !isend(s, i + 1)
        @inbounds n -= isvalid(s, i += 1)
    end
    return i + n
end


end # module LazyStrings

#=
import .LazyStrings.LazyString
import .LazyStrings.LazyASCII

using Test
using InteractiveUtils

struct TestLazy{T} <: LazyString
    s::T
    i::Int
end

LazyStrings.isend(::TestLazy, i, c) = c == '\n'

@test TestLazy(" Foo", 2) == "Foo"

@test TestLazy(" Foo\n ", 2) == "Foo"

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

function test_lazy_ascii()

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
end

=#
