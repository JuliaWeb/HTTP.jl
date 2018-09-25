const WARN_FULL_ITERATION_OF_LAZY_STRING = false

abstract type LazyString <: AbstractString end

Base.IteratorSize(::Type{T}) where T <: LazyString = Base.SizeUnknown()

Base.codeunit(s::LazyString) = codeunit(s.s)

@propagate_inbounds(
Base.codeunit(s::LazyString, i::Integer) = codeunit(s.s, s.i + i -1))

function Base.lastindex(s::LazyString)

    if WARN_FULL_ITERATION_OF_LAZY_STRING
        @warn "Full iteration of LazyString " *
              "lastindex(::$(typeof(s)))!" stacktrace()
    end

    first, last, has_skip = scan_string(s)
    return last
end

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

Base.ncodeunits(s::LazyString) = lastindex(s) + 1 - s.i

Base.isvalid(s::LazyString, i::Integer) = isvalid(s.s, s.i + i - 1)

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


abstract type LazyASCII <: LazyString end

# Allow comparison of UInt8 with Char (e.g. c == '{')
==(a, b) = Base.isequal(a, b)
!=(a, b) = !(a == b)
==(i::T, c::Char) where T <: Integer = Base.isequal(i, T(c))

function Base.isvalid(s::LazyASCII, i::Integer)
        return true
end

"""
`jl_alloc_string` allocates `n + 1` bytes and sets the last byte to `0x00`
https://github.com/JuliaLang/julia/blob/master/src/array.c#L464
"""
isend(::LazyASCII, i, c) = c == '\0'
isskip(::LazyASCII, i, c) = c > 0x7F
findstart(s::LazyASCII) = s.i

getc(s, i) = unsafe_load(pointer(s), i)

next_ic(s, i) = (i += 1; (i, getc(s, i)))

function scan_string(s::LazyASCII)

    ss = s.s
    i = findstart(s)
    first = i
    n = 0
    c = getc(ss, first)
    while !isend(s, i, c)
        if !isskip(s, i, c)
            n += 1
        end
        i, c = next_ic(ss, i)
    end

    return first, i-1, n
end


@propagate_inbounds(
Base.iterate(s::LazyASCII, i::Integer = 1) = _iterate(Char, s, i))

@propagate_inbounds(
function _iterate(character::Type, s::LazyASCII, i)
    ss = s.s
    si = i == 1 ? findstart(s) : s.i + i - 1
    c = getc(ss, si)
    if isend(s, si, c)
        return nothing
    end
    while isskip(s, si, c)
        si, c = next_ic(ss, si)
    end
    return character(c), si + 2 - s.i
end)

Base.codeunits(s::LazyASCII) = LazyASCIICodeUnits(s)

struct LazyASCIICodeUnits{S<:LazyASCII}
    s::S
end

Base.IteratorSize(::Type{T}) where T <: LazyASCIICodeUnits = Base.SizeUnknown()
    
@propagate_inbounds(
Base.iterate(s::LazyASCIICodeUnits, i::Integer = 1) = _iterate(UInt8, s.s, i))
