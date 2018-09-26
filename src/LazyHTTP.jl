"""
This module defines `RequestHeader` and `ResponseHeader` types for lazy parsing
of HTTP headers.

`RequestHeader` has properties: `method`, `target` and `version.
`ResponseHeader` has properties: `version` and `status`.
Both types implement the `AbstractDict` interface for accessing header fields.

e.g.
```
h = RequestHeader(
    "POST / HTTP/1.1\r\n" *
    "Content-Type: foo\r\n" *
    "Content-Length: 7\r\n" *
    "\r\n")

h.method == "POST"
h.target == "/"
h["Content-Type"] == "foo"
h["Content-Length"] == "7"
```

The implementation simply stores a reference to the input string.
Parsing is deferred until the properties or header fields are accessed.

Lazy parsing means that a malformed headers may go unnoticed (i.e. the malformed
part of the header might not be visited during lazy parsing). The `isvalid`
function can be used to check the whole header for compliance with the RFC7230
grammar.
"""
module LazyHTTP


const ENABLE_FOLDING = false


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


include("debug.jl") # FIXME


include("LazyString.jl")
using .LazyStrings
import .LazyStrings: getc, next_ic, findstart, isskip, replace, isend


abstract type Header <: AbstractDict{AbstractString,AbstractString} end

const REQUEST_LENGTH_MIN = ncodeunits("GET / HTTP/1.1\n\n")
const RESPONSE_LENGTH_MIN = ncodeunits("HTTP/1.1 200 OK\n\n")

struct ResponseHeader{T <: AbstractString} <: Header
    s::T

    function ResponseHeader(s::T) where T <: AbstractString
        @require ncodeunits(s) >= RESPONSE_LENGTH_MIN
        @require ends_with_crlf(s)
        return new{T}(s)
    end
end

struct RequestHeader{T <: AbstractString} <: Header
    s::T

    function RequestHeader(s::T) where T <: AbstractString
        @require ncodeunits(s) >= REQUEST_LENGTH_MIN
        @require ends_with_crlf(s)
        return new{T}(s)
    end
end


Base.show(io::IO, h::Header) = print(io, h.s)
Base.show(io::IO, ::MIME"text/plain", h::Header) = print(io, h.s)


abstract type HTTPString <: LazyASCII end

struct FieldName{T <: AbstractString} <: HTTPString
    s::T
    i::Int
end

struct FieldValue{T <: AbstractString} <: HTTPString
    s::T
    i::Int
end

FieldValue(n::FieldName) = FieldValue(n.s, n.i)
FieldName(v::FieldValue) = FieldName(v.s, v.i)


"""
https://tools.ietf.org/html/rfc7230#section-3.2
header-field = field-name ":" OWS field-value OWS CRLF
"""
isows(c)  = c == ' '  || c == '\t'
iscrlf(c) = c == '\r' || c == '\n'


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
    while c != ' ' && c != '\n'         # Check for '\n' prevents reading past
        i += 1                          # end of malformed buffer.
        c = getc(s, i)                  # See @require ends_with_crlf(s) above.
    end
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
token(s, i) = SubString(s, i, token_end(s, i))


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
findstart(s::FieldValue) = skip_token(s.s, s.i)


if ENABLE_FOLDING
"""
Skip over `obs-fold` in `field-value`.
https://tools.ietf.org/html/rfc7230#section-3.2.4
"""
function isskip(s::FieldValue, i, c)
    i, c = skip_ows(s.s, i, c)
    return c == '\r' || c == '\n'
end
end


"""
Is character `c` at index `i` the last character of a `field-value`?
i.e. Last non `OWS` character before `CRLF` (unless `CRLF` is an `obs-fold`).
`obs-fold = CRLF 1*( SP / HTAB )`
https://tools.ietf.org/html/rfc7230#section-3.2.4
"""
function isend(s::FieldValue, i, c)
    i, c = skip_ows(s.s, i, c)
    if iscrlf(c)
        if c == '\r'
            i, c = next_ic(s.s, i)
        end
        i, c = next_ic(s.s, i)
        if ENABLE_FOLDING
            if !isows(c) && !should_comma_combine(s.s, s.i, i)
                return true
            end
        else
            if isows(c)
                throw(ParseError(:RFC7230_3_2_4_OBS_FOLD, SubString(s.s, i)))
            end
            return true
        end
    end
    return false
end

if ENABLE_FOLDING
function replace(s::FieldValue, i, c)
    if getc(s.s, i-1) == '\n' && !isows(c)
        j = skip_token(s.s, i)
        return UInt8(','), max(j - 2 - i, 0)
    end
    return c, 0
end
end


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
    i = skip_crlf(s.s, 1)
    return token(s.s, i)
end


"""
Request target.
[RFC7230 5.3](https://tools.ietf.org/html/rfc7230#section-5.3)
`request-line = method SP request-target SP HTTP-version CRLF`
"""
function target(s::RequestHeader)
    i = skip_crlf(s.s, 1)
    i = skip_token(s.s, i)
    return token(s.s, i)
end


"""
Response status.
[RFC7230 3.1.2](https://tools.ietf.org/html/rfc7230#section-3.1.2)
[RFC7231 6](https://tools.ietf.org/html/rfc7231#section-6)
`status-line = HTTP-version SP status-code SP reason-phrase CRLF`
"""
function status(s::ResponseHeader)
    i = getc(s.s, 1) == 'c' ? 11 : 10
    i, c = skip_ows(s.s, i)
    return (   c             - UInt8('0')) * 100 +
           (getc(s.s, i + 1) - UInt8('0')) *  10 +
           (getc(s.s, i + 2) - UInt8('0'))
end


"""
`request-line = method SP request-target SP HTTP-version CRLF`
"""
function versioni(s::RequestHeader)
    i = skip_crlf(s.s, 1)
    i = skip_token(s.s, i)
    i = skip_token(s.s, i)
    return i + 5
end


"""
`status-line = HTTP-version SP status-code SP reason-phrase CRLF`
"""
versioni(s::ResponseHeader) = getc(s.s, 1) == 'c' ? 7 : 6


"""
Does the `Header` have version `HTTP/1.1`?
"""
function version(s::Header)
    i = versioni(s)
    return VersionNumber(getc(s.s, i    ) - UInt8('0'),
                         getc(s.s, i + 2) - UInt8('0'))
end


"""
Does the `Header` have version `HTTP/1.1`?
"""
function version_is_1_1(s::Header)
    i = versioni(s)
    return getc(s.s, i) == '1' && getc(s.s, i + 2) == '1'
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

Base.String(h::Header) = h.s


struct HeaderIndicies{T} h::T end
struct HeaderKeys{T} h::T end
struct HeaderValues{T} h::T end

Base.IteratorSize(::Type{T}) where T <: Header = Base.SizeUnknown()
Base.IteratorSize(::Type{T}) where T <: HeaderIndicies = Base.SizeUnknown()
Base.IteratorSize(::Type{T}) where T <: HeaderKeys = Base.SizeUnknown()
Base.IteratorSize(::Type{T}) where T <: HeaderValues = Base.SizeUnknown()

indicies(s::Header) = HeaderIndicies(s)
Base.keys(s::Header) = HeaderKeys(s)
Base.values(s::Header) = HeaderValues(s)

@inline function Base.iterate(h::HeaderIndicies, i::Int = 1)
    i = iterate_fields(h.h.s, i)
    return i == 0 ? nothing : (i, i)
end

@inline function Base.iterate(h::HeaderKeys, i::Int = 1)
    i = iterate_fields(h.h.s, i)
    return i == 0 ? nothing : (FieldName(h.h.s, i), i)
end

@inline function Base.iterate(h::HeaderValues, i::Int = 1)
    i = iterate_fields(h.h.s, i)
    return i == 0 ? nothing : (FieldValue(h.h.s, i), i)
end

@inline function Base.iterate(s::Header, i::Int = 1)
    i = iterate_fields(s.s, i)
    return i == 0 ? nothing : ((FieldName(s.s, i) => FieldValue(s.s, i), i))
end


"""
Iterate to next header field line
`@require ends_with_crlf(s)` in constructor prevents reading past end of string.
"""
function iterate_fields(s, i::Int)::Int

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
    if isows(c) || (ENABLE_FOLDING && should_comma_combine(s, i, old_i))
        @goto top
    end

    return i
end

"""
If `field-name` is the same as the previous field the value is
appended to the value of the previous header with a comma delimiter.
[RFC7230 3.2.2](https://tools.ietf.org/html/rfc7230#section-3.2.2)
`Set-Cookie` headers are not comma-combined because cookies often
contain internal commas.
[RFC6265 3](https://tools.ietf.org/html/rfc6265#section-3)
"""
should_comma_combine(s, i, old_i) =
    field_isequal_field(s, i, s,         old_i) != 0 &&
    field_isequal_field(s, i, "Set-Cookie:", 1) == 0


"""
    Is HTTP `field-name` `f` equal to `String` `b`?

[HTTP `field-name`s](https://tools.ietf.org/html/rfc7230#section-3.2)
are ASCII-only and case-insensitive.

"""
Base.isequal(f::FieldName, s::AbstractString) =
    field_isequal_string(f.s, f.i, s, 1) != 0

Base.isequal(a::FieldName, b::FieldName) =
    field_isequal_field(a.s, a.i, b.s, b.i) != 0

function field_isequal_string(f, fi, s, si)
    slast = lastindex(s)
    if si > slast
        return 0
    end
    while (fc = getc(f, fi)) != ':' && fc != '\n'
          ascii_lc(fc) == ascii_lc(getc(s, si))
        fi += 1
        si += 1
    end
    if fc == ':' && si == slast + 1
        return fi
    end
    return 0
end

function field_isequal_field(a, ai, b, bi)
    while (ac = ascii_lc(getc(a, ai))) ==
          (bc = ascii_lc(getc(b, bi))) && ac != '\n'
        if ac == ':'
            return ai
        end
        ai += 1
        bi += 1
    end
    return 0
end



"""
Convert ASCII (RFC20) character `c` to lower case.
"""
ascii_lc(c::UInt8) = c in UInt8('A'):UInt8('Z') ? c + 0x20 : c

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
            #return FieldValue(s.s, n) #FIXME
            return FieldValue(s.s, i) #FIXME
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


include("isvalid.jl")

end #module

#=

import .LazyHTTP.FieldName
import .LazyHTTP.Header
import .LazyHTTP.RequestHeader
import .LazyHTTP.ResponseHeader
import .LazyHTTP.status
import .LazyHTTP.version
import .LazyHTTP.method
import .LazyHTTP.target
import .LazyHTTP.isend
import .LazyHTTP.version_is_1_1
import .LazyHTTP.test_lazy_ascii
import .LazyHTTP.field_isequal_string
import .LazyHTTP.field_isequal_field

using HTTP

using Test

test_lazy_ascii()

for l in ["Foo-12", "FOO-12", "foo-12"],
    r =  ["Foo-12", "FOO-12", "foo-12"]

    for (c, i) in [(":", 7), ("\n", 0), ("", 0)]
        @test field_isequal_string("$l$c", 1, "$r", 1) == i
        @test field_isequal_string("$l$c", 1, SubString("$r"), 1) == i
        @test field_isequal_string("$l$c", 1, SubString(" $r ", 2, 7), 1) == i
        @test field_isequal_string("$l$c", 1, " $r", 2) == i

        @test field_isequal_field("$l$c", 1, "$r$c", 1) == i
        @test field_isequal_field("$l$c xxx", 1, "$r$c xxx", 1) == i
        @test field_isequal_field("$l$c xxx", 1, "$r$c yyy", 1) == i
    end

    @test field_isequal_string("$l:", 1, "$r:", 1) == 0
    @test field_isequal_string("$l:", 1, " $r:", 2) == 0
    @test field_isequal_string("$l:", 1, " $r ", 2) == 0
    @test field_isequal_string("$l:", 1, SubString("$r", 1, 5), 1) == 0

    @test field_isequal_string("$l\n:", 1, "$r\n", 1) == 0

    @test field_isequal_string("$l:a", 1, "$r:a", 1) == 0

    @test field_isequal_field("$l\n", 1, "$r\n", 1) == 0
    @test field_isequal_field("$l", 1, "$r", 1) == 0
    @test field_isequal_field("$l:", 1, "$r", 1) == 0
    @test field_isequal_field("$l", 1, "$r:", 1) == 0
    @test field_isequal_field("$l: xxx", 1, "$r: yyy", 2) == 0
    @test field_isequal_field("$l: xxx", 2, "$r: yyy", 1) == 0
end


s = "HTTP/1.1 200 OK\r\n" *
    "Foo: \t Bar Bar\t  \r\n" *
    "X: Y  \r\n" *
    "X:  Z \r\n" *
    "XX: Y  \r\n" *
    "XX:  Z \r\n" *
    "Field: Value\n folded \r\n more fold\n" *
    "Blah: x\x84x" *
    "\r\n" *
    "\r\n"

h = ResponseHeader(s)

@test (@allocated h = ResponseHeader(s)) <= 32

@test h.status == 200
@test (@allocated h.status) == 0
@test h.version == v"1.1"
@test (@allocated h.version) <= 48

@test h["X"] == (LazyHTTP.ENABLE_FOLDING ? "Y, Z" : "Y")
@test h["XX"] == (LazyHTTP.ENABLE_FOLDING ? "Y, Z" : "Y")

if LazyHTTP.ENABLE_FOLDING
@test collect(keys(h)) == ["Foo", "X", "XX", "Field", "Blah"]
@test collect(h) == ["Foo" => "Bar Bar",
                     "X" => "Y, Z",
                     "XX" => "Y, Z",
                     "Field" => "Value folded more fold",
                     "Blah" => "x\x84x"]
else
@test collect(keys(h)) == ["Foo", "X", "X", "XX", "XX", "Field", "Blah"]
@test h["Field"] != "Foo"
@test h["Field"] != "Valu"
@test_throws LazyHTTP.ParseError h["Field"] == "Value"
@test_throws LazyHTTP.ParseError h["Field"] == "Value folded more fold"
@test [n => h[n] for n in filter(x->x != "Field", collect(keys(h)))] ==
    ["Foo" => "Bar Bar",
     "X" => "Y",
     "X" => "Z",
     "XX" => "Y",
     "XX" => "Z",
     "Blah" => "x\x84x"]
end

@test (@allocated keys(h)) <= 16
@test iterate(keys(h)) == ("Foo", 18)
@test (@allocated iterate(keys(h))) <= 80

@test SubString(h["Foo"]).string == s
@test SubString(h["Blah"]).string == s
if LazyHTTP.ENABLE_FOLDING
@test SubString(h["X"]).string != s
@test SubString(h["Field"]).string != s
end

@test (@allocated SubString(h["Blah"])) <= 64

@test all(n->SubString(n).string == s, keys(h))

@test haskey(h, "Foo")
@test haskey(h, "FOO")
@test haskey(h, "foO")
@test (@allocated haskey(h, "Foo")) == 0
@test (@allocated haskey(h, "XXx")) == 0

if LazyHTTP.ENABLE_FOLDING
@test [h[n] for n in keys(h)] == ["Bar Bar",
                                  "Y, Z",
                                  "Y, Z",
                                  "Value folded more fold",
                                  "x\x84x"]

@test [h[n] for n in keys(h)] == [x for x in values(h)]
@test [h[n] for n in keys(h)] == [String(x) for x in values(h)]
@test [h[n] for n in keys(h)] == [SubString(x) for x in values(h)]
else
@test [h[n] for n in filter(x->x != "Field", collect(keys(h)))] == ["Bar Bar",
                                  "Y",
                                  "Z",
                                  "Y",
                                  "Z",
                                  "x\x84x"]
end



s = "GET /foobar HTTP/1.1\r\n" *
    "Foo: \t Bar Bar\t  \r\n" *
    "X: Y  \r\n" *
    "Field: Value\n folded \r\n more fold\n" *
    "Blah: x\x84x" *
    "\r\n" *
    "\r\n"

@test !isvalid(RequestHeader(s))
@test isvalid(RequestHeader(s); obs=true)

@test method(RequestHeader(s)) == "GET"
@test target(RequestHeader(s)) == "/foobar"
@test version(RequestHeader(s)) == v"1.1"

@test RequestHeader(s).method == "GET"
@test RequestHeader(s).target == "/foobar"
@test RequestHeader(s).version == v"1.1"
@test version_is_1_1(RequestHeader(s))


h = RequestHeader(s)
@test h.method == "GET"
@test (@allocated h.method) <= 32

=#
