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

Base.codeunit(s::LazyString, i::Integer) = codeunit(s.s, i)

Base.ncodeunits(s::LazyString) = ncodeunits(s.s)

function Base.length(s::LazyString)

    if WARN_FULL_ITERATION_OF_LAZY_STRING
        @warn "Full iteration of LazyString " *
              "length(::$(typeof(s)))!" stacktrace()
    end

    first, last, n = scan_string(s)
    return n
end

Base.isvalid(s::LazyString, i::Integer) = isvalid(s.s, i)


function Base.lastindex(s::LazyString)

    if WARN_FULL_ITERATION_OF_LAZY_STRING
        @warn "Full iteration of LazyString " *
              "lastindex(::$(typeof(s)))!" stacktrace()
    end

    first, last, n = scan_string(s)
    return last
end


function Base.iterate(s::LazyString, i::Int = s.i)
    next = iterate(s.s, i)
    if next == nothing
        return nothing
    end
    c, i = next
    return isend(s, i, c) ? nothing : next
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
isend(s::LazyASCII, i) = isend(s, i, getc(s.s, i))
isend(::LazyASCII, i, c) = false


"""
Should character `c` at index `i` be ignored?
"""
isskip(s::LazyASCII, i) = isskip(s, i, getc(s.s, i))
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

Base.iterate(s::LazyASCII, i::Int = s.i) = _iterate(ascii_char, s, i)

function _iterate(character, s::LazyASCII, i)
    ss = s.s
    if i <= s.i
        i = findstart(s)
    end
    if i > ncodeunits(s)
        return nothing
    end
    c = getc(ss, i)
    if isend(s, i, c)
        return nothing
    end
    while isskip(s, i, c)
        i, c = next_ic(ss, i)
        if isend(s, i, c)
            return nothing
        end
    end
    return character(c), i + 1
end


Base.codeunits(s::LazyASCII) = LazyASCIICodeUnits(s)

struct LazyASCIICodeUnits{S<:LazyASCII}
    s::S
end

Base.IteratorSize(::Type{T}) where T <: LazyASCIICodeUnits = Base.SizeUnknown()

Base.iterate(s::LazyASCIICodeUnits, i::Integer = s.s.i) = _iterate(identity, s.s, i)


function Base.isvalid(s::LazyASCII, i::Integer)
    if i == 1
        return true
    end
    if i <= findstart(s) || isend(s, i) || isskip(s, i-1)
        return false
    end
    return isvalid(s.s, i)
end


function Base.nextind(s::LazyASCII, i::Int, n::Int)
    n < 0 && throw(ArgumentError("n cannot be negative: $n"))
    if i == 0
        return 1
    end
    if i <= s.i
        i = findstart(s)
    end
    z = ncodeunits(s)
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


end # module LazyStrings
