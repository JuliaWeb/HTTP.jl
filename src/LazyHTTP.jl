module LazyHTTP

using Base: @propagate_inbounds 

include("LazyString.jl")

abstract type HTTPString <: LazyASCII end

abstract type Header <: AbstractDict{AbstractString,AbstractString} end

struct ResponseHeader{T <: AbstractString} <: Header
    s::T
end

struct RequestHeader{T <: AbstractString} <: Header
    s::T
end

struct FieldName{T <: AbstractString} <: HTTPString
    s::T
    i::Int
end

struct FieldValue{T <: AbstractString} <: HTTPString
    s::T
    i::Int
end

FieldValue(n::FieldName) = FieldValue(n.s, n.i)

"""
https://tools.ietf.org/html/rfc7230#section-3.2
header-field = field-name ":" OWS field-value OWS CRLF
"""

isows(c)  = c == ' '  ||
            c == '\t'

iscrlf(c) = c == '\r' ||
            c == '\n'


"""
Find index of first non-OWS character in String `s` starting at index `i`.
"""
function skip_ows(s, i, c = getc(s, i))
    while isows(c) && c != '\0'
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
    while c != ' ' && c != '\0'
        i += 1
        c = getc(s, i)
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
isend(::FieldName, i, c) = c == ':' || c == '\0'


"""
Find index and first character of `field-value` in `s`
starting at index `s.i`, which points to the `field-name`.
"""
findstart(s::FieldValue) = skip_token(s.s, s.i)


"""
Skip over `obs-fold` and `obs-text` in `field-value`.
https://tools.ietf.org/html/rfc7230#section-3.2.4
"""
isskip(::FieldValue, i, c) = c == '\r' || c == '\n' || c > 0x7F

#= FIXME =======================================================================
https://tools.ietf.org/html/rfc7230#section-3.2.4

A server that receives an obs-fold in a request message that is not
   within a message/http container MUST either reject the message by
   sending a 400 (Bad Request), preferably with a representation
   explaining that obsolete line folding is unacceptable

 A user agent that receives an obs-fold in a response message that is
   not within a message/http container MUST replace each received
   obs-fold with one or more SP octets prior to interpreting the field
   value.
===============================================================================#


"""
Is character `c` at index `i` the last character of a `field-value`?
i.e. Last non `OWS` character before `CRLF` (unless `CRLF` is an `obs-fold`).
`obs-fold = CRLF 1*( SP / HTAB )`
https://tools.ietf.org/html/rfc7230#section-3.2.4
"""
function isend(s::FieldValue, i, c)
    i, c = skip_ows(s.s, i, c)
    if iscrlf(c) || c == '\0'
        if c == '\r'
            i, c = next_ic(s.s, i)
        end
        i, c = next_ic(s.s, i)
        if !isows(c)
            return true
        end
    end
    return false
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
method(s::RequestHeader) = token(s.s, skip_crlf(s.s, 1))


"""
Request target.
[RFC7230 5.3](https://tools.ietf.org/html/rfc7230#section-5.3)
`request-line = method SP request-target SP HTTP-version CRLF`
"""
target(s::RequestHeader) = token(s.s, skip_token(s.s, skip_crlf(s.s, 1)))


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
        return getfield(Main, s)(h)
    else
        return getfield(h, s)
    end
end

Base.String(h::Header) = h.s


struct HeaderIndicies{T}
    h::T
end

indicies(s::Header) = HeaderIndicies(s)

@propagate_inbounds(
@inline function Base.iterate(h::HeaderIndicies, i::Int = 1)
    i = iterate_fields(h.h.s, i)
    return i == 0 ? nothing : (i, i)
end)

@propagate_inbounds(
@inline function Base.iterate(s::Header, i::Int = 1)
    i = iterate_fields(s.s, i)
    return i == 0 ? nothing : ((FieldName(s.s, i) => FieldValue(s.s, i), i))
end)

Base.IteratorSize(::Type{Header}) = Base.SizeUnknown()
Base.IteratorSize(::Type{HeaderIndicies}) = Base.SizeUnknown()


@propagate_inbounds(
function iterate_fields(s, i::Int)::Int

    @label top

    c = getc(s, i)
    if iscrlf(c) || c == '\0'
        return 0
    end

    while c != '\n' && c != '\0'
        i, c = next_ic(s, i)
    end

    i, c = next_ic(s, i)
    if iscrlf(c) || c == '\0'
        return 0
    end
    
    # https://tools.ietf.org/html/rfc7230#section-3.2.4
    # obs-fold = CRLF 1*( SP / HTAB )
    if isows(c)
        @goto top
    end
    
    return i
end)


"""
    Is HTTP `field-name` `f` equal to `String` `b`?

[HTTP `field-name`s](https://tools.ietf.org/html/rfc7230#section-3.2)
are ASCII-only and case-insensitive.

"""
Base.isequal(f::FieldName, b::AbstractString) =
    field_isequal(f.s, f.i, b, 1) != 0

function field_isequal(a, ai, b, bi)
    while (ac = ascii_lc(getc(a, ai))) ==
          (bc = ascii_lc(getc(b, bi)))
        ai += 1
        bi += 1
    end
    if ac == ':' && bc == '\0'
        return ai
    end
    return 0
end


"""
Convert ASCII (RFC20) character `c` to lower case.
"""
ascii_lc(c::UInt8) = c in UInt8('A'):UInt8('Z') ? c + 0x20 : c

function Base.haskey(s::Header, key)
    for i in indicies(s)
        if field_isequal(s.s, i, key, 1) > 0
            return true
        end
    end
    return false
end

function Base.get(s::Header, key, default=nothing)
    for i in indicies(s)
        n = field_isequal(s.s, i, key, 1)
        if n > 0
            return FieldValue(s.s, n)
        end
    end
    return default
end 

function Base.getindex(h::Header, key) 
    v = get(h, key)
    if v === nothing
        throw(KeyError(key))
    end
    return v
end

end #module

import .LazyHTTP.FieldName
import .LazyHTTP.Header
import .LazyHTTP.RequestHeader
import .LazyHTTP.ResponseHeader
import .LazyHTTP.value
import .LazyHTTP.status
import .LazyHTTP.version
import .LazyHTTP.method
import .LazyHTTP.target
import .LazyHTTP.version_is_1_1

using HTTP

s = "HTTP/1.1 200 OK\r\nFoo: \t Bar Bar\t  \r\nX: Y  \r\nField: Value\n folded \r\n more fold\nBlash: x\x84x\r\n\r\n d d d"
@show s

m = parse(HTTP.Response, s)

#f = FieldName(s, 18)
#@show f
#@show collect(codeunits(f))
#@show String(f)
#@show SubString(f)

#v = FieldValue(s, 22)
#@show v

#@show String(f)
#@show SubString(f)

#@show ncodeunits(v)
#@show length(v)


h = ResponseHeader(s)
for x in h
    @show x
end

using InteractiveUtils


println("lazyget")
@time get(h, "X")
@time get(h, "X")

@show HTTP.header(m, "X")
@show get(h, "X")
@show h["X"]

m = HTTP.Response()
io = IOBuffer(s)

println("readheaders")
@timev HTTP.Messages.readheaders(io, m)
m = HTTP.Response()
io = IOBuffer(s)
@time HTTP.Messages.readheaders(io, m)

println("header")
@time HTTP.header(m, "X")
@time HTTP.header(m, "X")

function xxx(m, io, h)
    HTTP.Messages.readheaders(io, m)
    HTTP.header(m, h)
end

println("xxx")
m = HTTP.Response()
io = IOBuffer(s)
@time xxx(m, io, "X")
m = HTTP.Response()
io = IOBuffer(s)
@time xxx(m, io, "X")

@show version(h)
@show status(h)
@show h.version
@show h.status
s = "GET /foobar HTTP/1.1\r\n\r\n"
@show method(RequestHeader(s))
@show target(RequestHeader(s))
@show version(RequestHeader(s))

@show RequestHeader(s).method
@show RequestHeader(s).target
@show RequestHeader(s).version
@show version_is_1_1(RequestHeader(s))

@show @timev haskey(h, "X")
@show @timev haskey(h, "Y")
@show @timev haskey(h, "X")
@show @timev haskey(h, "Y")

@show h
@show Dict(h)

#s = ":?"
#@show s

#f = FieldName(s, 1)
#@show f


