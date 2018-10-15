"""
*LazyStrings*

Copyright (c) 2018, Sam O'Connor

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

const WARN_FULL_ITERATION_OF_LAZY_STRING = false



# LazyString

abstract type LazyString <: AbstractString end


"""
Does character `c` at index `i` mark the end of the sub-string?
"""
isend(s::LazyString, i) = isend(s, i, getc(s, i))
isend(::LazyString, i, c) = false


"""
Should character `c` at index `i` be ignored?
"""
isskip(s::LazyString, i) = isskip(s, i, getc(s, i))
isskip(::LazyString, i, c) = false


"""
Find the index of the first character of the sub-string.
"""
findstart(s::LazyString) = s.i


"""
Read a character from source string `s.s` at index `i` with no bounds check.
"""
getc(s::LazyString, i) = @inbounds s.s[i]


"""
Increment `i.
"""
next_i(s::LazyString, i) = nextind(s.s, i)


"""
Increment `i`, read a character, return new `i` and the character.
"""
next_ic(s::LazyString, i) = (i = next_i(s, i); (i, getc(s, i)))


"""
Iterate over the characers of `s`.
Return first index, last index and number of characters.
"""
function scan_string(s::LazyString)

    i = findstart(s)
    first = i
    n = 0
    c = getc(s, first)
    last = maxindex(s)
    while i <= last && !isend(s, i, c)
        if !isskip(s, i, c)
            n += 1
        end
        i, c = next_ic(s, i)
    end

    return first, i-1, n
end


Base.iterate(s::LazyString, i::Int = s.i) = _iterate(identity, s, i)

function _iterate(character, s::LazyString, i)
    if i <= s.i
        i = findstart(s)
    end
    if i > maxindex(s)
        return nothing
    end
    c = getc(s, i)
    if isend(s, i, c)
        return nothing
    end
    while isskip(s, i, c)
        i, c = next_ic(s, i)
        if isend(s, i, c)
            return nothing
        end
    end
    return character(c), next_i(s, i)
end


Base.IteratorSize(::Type{<:LazyString}) = Base.SizeUnknown()

Base.codeunit(s::LazyString) = codeunit(s.s)

Base.codeunit(s::LazyString, i::Integer) = codeunit(s.s, i)

Base.ncodeunits(s::LazyString) = maxindex(s)
maxindex(s::LazyString) = ncodeunits(s.s)

isvalid(s, i) = Base.isvalid(s, i)
prevind(s, i) = Base.prevind(s, i)

Base.isvalid(s::LazyString, i::Integer) = i == 1 || (i > findstart(s) &&
                                                    isvalid(s.s, i) &&
                                                    !isend(s, i) &&
                                                    !isskip(s, prevind(s.s, i)))


function Base.nextind(s::LazyString, i::Int, n::Int)
    n < 0 && throw(ArgumentError("n cannot be negative: $n"))
    if i == 0
        return 1
    end
    if i <= s.i
        i = findstart(s)
    end
    z = maxindex(s)
    @boundscheck 0 ≤ i ≤ z || throw(BoundsError(s, i))
    n == 0 && return thisind(s, i) == i ? i : string_index_err(s, i)
    while n > 0
        if isend(s, i)
            return z + 1
        end
        @inbounds n -= isvalid(s, i += 1)
    end
    return i + n
end


function Base.length(s::LazyString)

    if WARN_FULL_ITERATION_OF_LAZY_STRING
        @warn "Full iteration of LazyString " *
              "length(::$(typeof(s)))!" stacktrace()
    end

    first, last, n = scan_string(s)
    return n
end


function Base.lastindex(s::LazyString)

    if WARN_FULL_ITERATION_OF_LAZY_STRING
        @warn "Full iteration of LazyString " *
              "lastindex(::$(typeof(s)))!" stacktrace()
    end

    first, last, n = scan_string(s)
    return first == last ? 1 : last
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


getc(s::LazyASCII, i) = unsafe_load(pointer(s.s), i)

next_i(s::LazyASCII, i) = i + 1


"""
Convert ASCII byte `c` to `Char`.
`0x8n` maps to `'\x8n'` (not `'\u8n'`).
"""
ascii_char(c::UInt8) = reinterpret(Char, (c % UInt32) << 24)

Base.iterate(s::LazyASCII, i::Int = 1) = _iterate(ascii_char, s, i)


Base.codeunit(s::LazyASCII) = UInt8
Base.codeunits(s::LazyASCII) = LazyASCIICodeUnits(s)

struct LazyASCIICodeUnits{S<:LazyASCII}
    s::S
end

Base.IteratorSize(::Type{<:LazyASCIICodeUnits}) = Base.SizeUnknown()
Base.eltype(::Type{<:LazyASCIICodeUnits}) = UInt8

Base.iterate(s::LazyASCIICodeUnits, i::Integer = s.s.i) =
    _iterate(identity, s.s, i)



end # module LazyStrings
