"""
*LazyHTTP*

This module defines `RequestHeader` and `ResponseHeader` types for lazy parsing
of HTTP headers.

`RequestHeader` has properties: `method`, `target` and `version`.

`ResponseHeader` has properties: `version` and `status`.

Both types have an `AbstractDict`-like interface for accessing header fields.

e.g.
```
julia> s = "POST / HTTP/1.1\\r\\n" *
           "Content-Type: foo\\r\\n" *
           "Content-Length: 7\\r\\n" *
           "Tag: FOO\\r\\n" *
           "Tag: BAR\\r\\n" *
           "\\r\\n"

julia> h = LazyHTTP.RequestHeader(s)

julia> h.method
"POST"

julia> h.target
"/"

julia> h["Content-Type"]
"foo"

julia> h["Content-Length"]
"7"

julia> h["Tag"]
"FOO"

julia> collect(h)
4-element Array:
   "Content-Type" => "foo"
 "Content-Length" => "7"
            "Tag" => "FOO"
            "Tag" => "BAR"
```


*Lazy Parsing*

The implementation simply stores a reference to the input string.
Parsing is deferred until the properties or header fields are accessed.

The value objects returned by the parser are also lazy. They store a reference
to the input string and the start index of the value. Parsing of the value
content is deferred until needed by the `AbstractString` interface.

Lazy parsing means that a malformed headers may go unnoticed (i.e. the malformed
part of the header might not be visited during lazy parsing). The `isvalid`
function can be used to check the whole header for compliance with the RFC7230
grammar.


*Repeated `field-name`s*

This parser does not attempt to comma-combine values when multiple fields have
then same name. This behaviour is not required by RFC7230 and is incompatible
with the `Set-Cookie` header.

[RFC7230 3.2.2](https://tools.ietf.org/html/rfc7230#section-3.2.2) says:
"A recipient MAY combine multiple header fields with the same field
name .. by appending each .. value... separated by a comma."

[RFC6265 3](https://tools.ietf.org/html/rfc6265#section-3) says
"... folding HTTP headers fields might change the semantics of
the Set-Cookie header field because the %x2C (",") character is used
by Set-Cookie in a way that conflicts with such folding."


*Implementation*

The `FieldName` and `FieldValue` structs store:
 - a reference to the underlying HTTP Header `String`
 - the start index of the `field-name` or `field-value`.

(`header-field = field-name ":" OWS field-value OWS CRLF`)

When a `field-name` is accessed via the `AbstractString` iteration
interface the parser begins at the start index stops at the ":".
For `field-value` the parser skips over whitespace after the ":"
and stops at whitespace at the end of the line.

              ┌▶"GET / HTTP/1.1\\r\\n" *
              │ "Content-Type: text/plain\\r\\r\\r\\n"
              │  ▲          ▲
              │  │          │
    FieldName(s, i=17)      │        == "Content-Type"
              └──────────┐  │
              FieldValue(s, i=28)    == "text/plain"


Parser does not always know the start index of the `field-value` at the time
a `FieldValue` obeject is created. In such cases the start index is set to
the start of the line and the parser skips over the `field-name` and ":"
before iterating over the `field-value` characters.

              ┌▶"GET / HTTP/1.1\\r\\n" *
              │ "Content-Type: text/plain\\r\\r\\r\\n"
              │  ▲
              │  ├──────────┐
              │  │          │
    FieldName(s, i=17)      │        == "Content-Type"
              └──────────┐  │
              FieldValue(s, i=17)    == "text/plain"


e.g.
```
julia> dump(h["Content-Type"])
HTTP.LazyHTTP.FieldValue{String}
  s: String "GET / HTTP/1.1\\r\\nContent-Type: text/plain\\r\\n\\r\\n"
  i: Int64 28

julia> v = h["Content-Type"]
"text/plain"

julia> for i in keys(v)
          @show i, v[i]
       end
(i, v[i]) = (1, 't')
(i, v[i]) = (32, 'e')
(i, v[i]) = (33, 'x')
(i, v[i]) = (34, 't')
(i, v[i]) = (35, '/')
(i, v[i]) = (36, 'p')
(i, v[i]) = (37, 'l')
(i, v[i]) = (38, 'a')
(i, v[i]) = (39, 'i')
(i, v[i]) = (40, 'n')
```
"""
module LazyHTTP

import ..@require, ..precondition_error
import ..@ensure, ..postcondition_error

using ..LazyStrings
import ..LazyStrings: LazyASCII,
                      getc, next_ic, findstart, maxindex, isskip, isend

include("status_messages.jl")

const ENABLE_OBS_FOLD = true


"""
Parser input was invalid.

Fields:
 - `code`, error code
 - `bytes`, the offending input.
"""
struct ParseError <: Exception
    code::Symbol
    bytes::SubString{String}
end


# Local `==` to allow comparison of UInt8 with Char (e.g. c == '{')
==(a, b) = Base.isequal(a, b)
!=(a, b) = !(a == b)
==(i::T, c::Char) where T <: Integer = Base.isequal(i, T(c))



# HTTP Headers

abstract type Header{T} #= <: AbstractDict{AbstractString,AbstractString} =# end

const REQUEST_LENGTH_MIN = ncodeunits("GET / HTTP/1.1\n\n")
const RESPONSE_LENGTH_MIN = ncodeunits("HTTP/1.1 200\n\n")

struct ResponseHeader{T} <: Header{T}
    s::T

    function ResponseHeader(s::T) where T <: AbstractString
        @require ncodeunits(s) >= RESPONSE_LENGTH_MIN
        @require ends_with_crlf(s)
        return new{T}(s)
    end
    function ResponseHeader(status::Int)
        io = IOBuffer()
        print(io, "HTTP/1.1 ", status, " ", statustext(status), "\r\n\r\n")
        return new{IOBuffer}(io)
    end
end

struct RequestHeader{T} <: Header{T}
    s::T

    function RequestHeader(s::T) where T <: AbstractString
        @require ncodeunits(s) >= REQUEST_LENGTH_MIN
        @require ends_with_crlf(s)
        return new{T}(s)
    end
    function RequestHeader(method, target)
        io = IOBuffer()
        print(io, method, " ", target, " HTTP/1.1\r\n\r\n")
        return new{IOBuffer}(io)
    end
    RequestHeader(s::T) where T = new{T}(s)
end

RequestHeader{T}(s::T) where T = RequestHeader(s)

Base.String(h::Header{<:AbstractString}) = h.s
Base.String(h::Header{IOBuffer}) = String(take!(copy(h.s)))

Base.write(io::IO, h::Header{<:AbstractString}) = write(io, h.s)
Base.write(io::IO, h::Header{IOBuffer}) = unsafe_write(io, pointer(h.s.data),
                                                           h.s.size)

getc(s, i) = unsafe_load(pointer(s), i)
getc(s::IOBuffer, i) = getc(s.data, i)
getc(s::Header, i) = getc(s.s, i)

next_ic(s::Header, i) = (i = i + 1 ; (i, getc(s, i)))


Base.show(io::IO, h::Header) = _show(io, h)
Base.show(io::IO, ::MIME"text/plain", h::Header) = _show(io, h)

function _show(io, h)
    println(io, "$(typeof(h).name)(\"\"\"")
    for l in split(String(h), "\n")[1:end-1]
        println(io, "    ", escape_string(l))
    end
    println(io, "    \"\"\")")
end



# HTTP Fields

abstract type HTTPString{T} <: LazyASCII end

struct FieldName{T} <: HTTPString{T}
    s::T
    i::Int
end

struct FieldValue{T} <: HTTPString{T}
    s::T
    i::Int
end

FieldValue(n::FieldName) = FieldValue(n.s, n.i)
FieldName(v::FieldValue) = FieldName(v.s, v.i)

getc(s::HTTPString{IOBuffer}, i) = getc(s.s, i)
maxindex(s::HTTPString{IOBuffer}) = s.s.size
LazyStrings.isvalid(b::IOBuffer, i) = 1 <= i <= b.size
LazyStrings.prevind(::IOBuffer, i) = i - 1


# Parsing Utilities

"""
https://tools.ietf.org/html/rfc7230#section-3.2
header-field = field-name ":" OWS field-value OWS CRLF
"""
isows(c)  = c == ' '  || c == '\t'
iscrlf(c) = c == '\r' || c == '\n'
isws(c) = isows(c) || iscrlf(c)
isdecimal(c) = c in UInt8('0'):UInt8('9')


"""
Does ASCII string `s` end with `"\r\n\r\n"` or `"\n\n"`?
"""
function ends_with_crlf(s::AbstractString)
    n = ncodeunits(s)
    if n < 4
        return false
    end
    crlf = unsafe_load(Ptr{UInt32}(pointer(s, n - 3)))
    return crlf                     == ntoh(0x0D0A0D0A) ||
          (crlf & ntoh(0x0000FFFF)) == ntoh(0x00000A0A)
end


"""
Find index of first non-OWS character in String `s` starting at index `i`.
"""
function skip_ows(s, i, c = getc(s, i))
    while isows(c)
        i, c = next_ic(s, i)
    end
    return i, c
end


"""
Find index of character after CRLF in String `s` starting at index `i`.
"""
function skip_crlf(s, i, c = getc(s, i))
    if c == '\r'
        i, c = next_ic(s, i)
    end
    if c == '\n'
        i += 1
    end
    return i
end


"""
Find index of last character of space-delimited token
starting at index `i` in String `s`.
"""
function token_end(s, i, c = getc(s,i))
    while !isws(c)                      # Check for '\n' prevents reading past
        i, c = next_ic(s, i)            # end of malformed buffer.
    end                                 # See @require ends_with_crlf(s) above.
    return i - 1
end


"""
Find index of first character of next space-delimited token
starting at index `i` in String `s`.
"""
function skip_token(s, i)
    i = token_end(s, i)
    i, c = skip_ows(s, i + 1)
    return i
end


"""
`SubString` of space-delimited token starting at index `i` in String `s`.
"""
token(s::Header, i) = SubString(s.s, i, token_end(s, i))
token(s::Header{IOBuffer}, i) = String(view(s.s.data, i:token_end(s, i)))


"""
Does `c` mark the end of a `field-name`?
"""
isend(s::FieldName, i, c) = c == ':' || # Check for '\n' prevents reading past
                            c == '\n'   # end of malformed buffer.
                                        # See @require ends_with_crlf(s) above.


"""
Find index and first character of `field-value` in `s`
starting at index `s.i`, which points to the `field-name`.
"""
function findstart(s::FieldValue)
    i, c = next_ic(s, s.i)
    while c != ':' && c != '\n'
        i, c = next_ic(s, i)
    end
    i, c = skip_ows(s, i + 1)
    return i
end


if ENABLE_OBS_FOLD
"""
Skip over `obs-fold` in `field-value`.
https://tools.ietf.org/html/rfc7230#section-3.2.4
"""
isskip(s::FieldValue, i, c) = c == '\r' || c == '\n'
end


"""
Is character `c` at index `i` the last character of a `field-value`?
i.e. Last non `OWS` character before `CRLF` (unless `CRLF` is an `obs-fold`).
`obs-fold = CRLF 1*( SP / HTAB )`
https://tools.ietf.org/html/rfc7230#section-3.2.4
"""
function isend(s::FieldValue, i, c)
    if getc(s, i-1) == '\n'
        return false
    end
    i, c = skip_ows(s, i, c)
    if iscrlf(c)
        if c == '\r'
            i, c = next_ic(s, i)
        end
        i, c = next_ic(s, i)
        if isows(c)
            if !ENABLE_OBS_FOLD
                throw(ParseError(:RFC7230_3_2_4_OBS_FOLD, SubString(s.s, i)))
            end
        else
            return true
        end
    end
    return false
end



# Request/Status Line Interface

"""
Request method.
[RFC7230 3.1.1](https://tools.ietf.org/html/rfc7230#section-3.1.1)
`request-line = method SP request-target SP HTTP-version CRLF`

[RFC7230 3.5](https://tools.ietf.org/html/rfc7230#section-3.5)
> In the interest of robustness, a server that is expecting to receive
> and parse a request-line SHOULD ignore at least one empty line (CRLF)
> received prior to the request-line.
"""
function method(s::RequestHeader)
    i = skip_crlf(s, 1)
    return token(s, i)
end


"""
Request target.
[RFC7230 5.3](https://tools.ietf.org/html/rfc7230#section-5.3)
`request-line = method SP request-target SP HTTP-version CRLF`
"""
function target(s::RequestHeader)
    i = skip_crlf(s, 1)
    i = skip_token(s, i)
    return token(s, i)
end


"""
Response status.
[RFC7230 3.1.2](https://tools.ietf.org/html/rfc7230#section-3.1.2)
[RFC7231 6](https://tools.ietf.org/html/rfc7231#section-6)
`status-line = HTTP-version SP status-code SP reason-phrase CRLF`
See:
[#190](https://github.com/JuliaWeb/HTTP.jl/issues/190#issuecomment-363314009)
"""
function status(s::ResponseHeader)::Int
    i = getc(s, 1) == ' ' ? 11 : 10 # Issue #190
    i, c = skip_ows(s, i)
    return (   c           - UInt8('0')) * 100 +
           (getc(s, i + 1) - UInt8('0')) *  10 +
           (getc(s, i + 2) - UInt8('0'))
end


"""
`request-line = method SP request-target SP HTTP-version CRLF`
"""
function versioni(s::RequestHeader)
    i = skip_crlf(s, 1)
    i = skip_token(s, i)
    i = skip_token(s, i)
    return i + 5
end


"""
`status-line = HTTP-version SP status-code SP reason-phrase CRLF`
See:
[#190](https://github.com/JuliaWeb/HTTP.jl/issues/190#issuecomment-363314009)
"""
versioni(s::ResponseHeader) = getc(s, 1) == ' ' ? 7 : 6 # Issue #190


"""
Does the `Header` have version `HTTP/1.1`?
"""
function version(s::Header)::VersionNumber

    i = versioni(s) - 2
    i, slash = next_ic(s, i)
    i, major = next_ic(s, i)
    i, dot   = next_ic(s, i)
    i, minor = next_ic(s, i)

    if slash != '/' || !isdecimal(major) || dot != '.' || !isdecimal(minor)
        throw(ParseError(:INVALID_HTTP_VERSION, SubString(s.s, 1, i + 2)))
    end
    return VersionNumber(major - UInt8('0'), minor - UInt8('0'))
end


"""
Does the `Header` have version `HTTP/1.1`?
"""
function version_is_1_1(s::Header)
    i = versioni(s)
    return getc(s, i) == '1' && getc(s, i + 2) == '1'
end


function Base.getproperty(h::Header, s::Symbol)
    if s === :status ||
       s === :version ||
       s === :method ||
       s === :target
        return getfield(LazyHTTP, s)(h)
    else
        return getfield(h, s)
    end
end



# Iteration Interface

struct HeaderIndicies{T} h::T end
struct HeaderKeys{T} h::Header{T} end
struct HeaderValues{T} h::Header{T} end

Base.IteratorSize(::Type{<:HeaderIndicies}) = Base.SizeUnknown()
Base.IteratorSize(::Type{<:HeaderKeys})     = Base.SizeUnknown()
Base.IteratorSize(::Type{<:HeaderValues})   = Base.SizeUnknown()
Base.IteratorSize(::Type{<:Header})         = Base.SizeUnknown()

Base.eltype(::Type{<:HeaderIndicies})          = Int
Base.eltype(::Type{<:HeaderKeys{S}})   where S = FieldName{S}
Base.eltype(::Type{<:HeaderValues{S}}) where S = FieldValue{S}
Base.eltype(::Type{<:Header{S}})       where S = Pair{FieldName{S},
                                                      FieldValue{S}}

indicies(s::Header) = HeaderIndicies(s)
Base.keys(s::Header) = HeaderKeys(s)
Base.values(s::Header) = HeaderValues(s)

@inline function Base.iterate(h::HeaderIndicies, i::Int = 1)
    i = next_field(h.h, i)
    return i == 0 ? nothing : (i, i)
end

@inline function Base.iterate(h::HeaderKeys, i::Int = 1)
    i = next_field(h.h, i)
    return i == 0 ? nothing : (FieldName(h.h.s, i), i)
end

@inline function Base.iterate(h::HeaderValues, i::Int = 1)
    i = next_field(h.h, i)
    return i == 0 ? nothing : (FieldValue(h.h.s, i), i)
end

@inline function Base.iterate(s::Header, i::Int = 1)
    i = next_field(s, i)
    return i == 0 ? nothing : ((FieldName(s.s, i) => FieldValue(s.s, i), i))
end


"""
Iterate to next header field line
`@require ends_with_crlf(s)` in constructor prevents reading past end of string.
"""
function next_field(s::Header, i::Int)::Int

    @label top

    old_i = i

    c = getc(s, i)
    if iscrlf(c)
        return 0
    end

    while c != '\n'
        i, c = next_ic(s, i)
    end

    i, c = next_ic(s, i)
    if iscrlf(c)
        return 0
    end

    # https://tools.ietf.org/html/rfc7230#section-3.2.4
    # obs-fold = CRLF 1*( SP / HTAB )
    if isows(c)
        @goto top
    end

    return i
end



# Field Name Comparison

getascii(s, i) = unsafe_load(pointer(s), i)
getascii(s::IOBuffer, i) = unsafe_load(pointer(s.data), i)

function field_isequal_string(f, fi, s, si)
    slast = lastindex(s)
    if si > slast
        return 0
    end
    while (fc = getascii(f, fi)) != ':' && fc != '\n' &&
          ascii_lc(fc) == ascii_lc(getascii(s, si))
        fi += 1
        si += 1
    end
    if fc == ':' && si == slast + 1
        return fi
    end
    return 0
end

function field_isequal_field(a, ai, b, bi)
    while (ac = ascii_lc(getascii(a, ai))) ==
          (bc = ascii_lc(getascii(b, bi))) && ac != '\n' && ac != '\0'
        if ac == ':'
            return ai
        end
        ai += 1
        bi += 1
    end
    return 0
end

module OverloadBaseEquals
import Base.==
import ..Header
import ..FieldName
import ..field_isequal_string
import ..field_isequal_field

"""
    Is HTTP `field-name` `f` equal to `String` `b`?

[HTTP `field-name`s](https://tools.ietf.org/html/rfc7230#section-3.2)
are ASCII-only and case-insensitive.

"""
==(f::FieldName, s::AbstractString) = field_isequal_string(f.s, f.i, s, 1) != 0
==(a::FieldName, b::FieldName) = field_isequal_field(a.s, a.i, b.s, b.i) != 0

==(a::Header, b::Header) = String(a) == String(b)

end # module OverloadBaseEquals

"""
Convert ASCII (RFC20) character `c` to lower case.
"""
ascii_lc(c::UInt8) = c in UInt8('A'):UInt8('Z') ? c + 0x20 : c



# Indexing Interface

function Base.haskey(s::Header, key)
    for i in indicies(s)
        if field_isequal_string(s.s, i, key, 1) > 0
            return true
        end
    end
    return false
end


Base.get(s::Header, key, default=nothing) = _get(s, key, default)

function _get(s::Header, key, default)
    for i in indicies(s)
        n = field_isequal_string(s.s, i, key, 1)
        if n > 0
            return FieldValue(s.s, n - 1)
        end
    end
    return default
end

Base.get(s::Header, key::FieldName, default=nothing) =
    key.s == s.s ? FieldValue(key) : _get(s, key, default)


function Base.getindex(h::Header, key)
    v = get(h, key)
    if v === nothing
        throw(KeyError(key))
    end
    return v
end


Base.length(h::Header) = count(x->true, indicies(h))


# Mutation

const DEBUG_MUTATION = false

function Base.delete!(h::Header{IOBuffer}, key)
    for i in indicies(h)
        if field_isequal_string(h.s, i, key, 1) > 0
            j = next_field(h, i)
            copyto!(h.s.data, i, h.s.data, j, h.s.size + 1 - j)
            h.s.size -= j - i
            h.s.ptr = h.s.size + 1
            break
        end
    end
    if DEBUG_MUTATION
        @ensure !haskey(h, key)
        @ensure isvalid(h)
    end
    return h
end


function Base.push!(h::Header{IOBuffer}, v)
    h.s.ptr -= 2
    print(h.s, v.first, ": ", v.second, "\r\n\r\n")
    if DEBUG_MUTATION
        @ensure v in h
        @ensure isvalid(h)
    end
    return h
end


function Base.setindex!(h::Header{IOBuffer}, value, key)
    delete!(h, key)
    push!(h, key => value)
    if DEBUG_MUTATION
        @ensure get(h,key) == value
    end
    return h
end


function append_trailer(h::T, trailer) where T <: Header
    last = lastindex(h.s) - 1
    if h.s[last] == '\r'
        last -= 1
    end
    return T(h.s[1:last] * trailer)
end


include("isvalid.jl")



end #module
