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
    if isskip(s, si, c)
        while true
            si, c = next_ic(ss, si)
            if isend(s, si, c)
                return nothing
            end
            if !isskip(s, si, c)
                break
            end
        end
    end
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
