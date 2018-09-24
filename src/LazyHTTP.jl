module LazyHTTP

using Base: @propagate_inbounds 

include("LazyString.jl")

abstract type HTTPString <: LazyASCII end

abstract type Header end

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


"""
https://tools.ietf.org/html/rfc7230#section-3.2
header-field = field-name ":" OWS field-value OWS CRLF
"""

isows(c)  = c == ' '  ||
            c == '\t'

iscrlf(c) = c == '\r' ||
            c == '\n'

"""
Skip over OWS in String `s` starting at index `i`.
"""
function skip_ows(s, i, c = getc(s, i))
    while isows(c) && c != '\0'
        i, c = next_ic(s, i)
    end
    return i, c
end

"""
Skip over CRLF in String `s` starting at index `i`.
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

function token_end(s, i, c=getc(s,i))
    while c != ' ' && c != '\0'
        i += 1
        c = getc(s, i)
    end
    return i - 1 
end

function skip_token(s, i)
    i = token_end(s, i)
    i, c = skip_ows(s, i + 1)
    return i
end

token(s, i) = SubString(s, i, token_end(s, i))



isend(::FieldName, c, i) = c == ':' || c == '\0'

isstart(::FieldValue, c) = c != ':' && !isows(c)

# obs-fold and obs-text
# https://tools.ietf.org/html/rfc7230#section-3.2.4
isskip(::FieldValue, c, i) = c == '\r' || c == '\n' || c > 0x7F

function isend(s::FieldValue, c, i)
    i, c = skip_ows(s.s, i, c)
    if iscrlf(c) || c == '\0'
        if c == '\r'
            i, c = next_ic(s.s, i)
        end
        i, c = next_ic(s.s, i)
        if isows(c)
            # https://tools.ietf.org/html/rfc7230#section-3.2.4
            # obs-fold = CRLF 1*( SP / HTAB )
            return false
        else
            return true
        end
    end
    return false
end

method(s::RequestHeader) = token(s.s, skip_crlf(s.s, 1))
target(s::RequestHeader) = token(s.s, skip_token(s.s, skip_crlf(s.s, 1)))

function version(s::RequestHeader)
    ss = s.s
    i = skip_token(ss, skip_token(ss, skip_crlf(ss, 1)))
    return SubString(ss, i + 5, i + 7)
end

function status(s::ResponseHeader)
    ss = s.s
    i = getc(ss, 1) == 'c' ? 11 : 10
    i, c = skip_ows(s.s, i)
    return SubString(ss, i, i + 2)
end

function version(s::ResponseHeader)
    ss = s.s
    i = getc(ss, 1) == 'c' ? 7 : 6
    return SubString(ss, i, i + 2)
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


@propagate_inbounds(
@inline function Base.iterate(s::Header, i::Int = 1)
    i = iterate_fields(s.s, i)
    return i == 0 ? nothing : (FieldName(s.s, i), i)
end)

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


@inline function value(s::FieldName)
    i = s.i    
    c = getc(s.s, i)
    while !isend(s, c, i)
        i, c = next_ic(s.s, i)
    end
    return FieldValue(s.s, i)
end


"""
    Is HTTP `field-name` `f` equal to `String` `b`?

[HTTP `field-name`s](https://tools.ietf.org/html/rfc7230#section-3.2)
are ASCII-only and case-insensitive.

"""
function Base.isequal(f::FieldName, b::AbstractString)

    a = f.s
    ai = f.i    
    bi = 1
    
    while (ac = ascii_lc(getc(a, ai))) ==
          (bc = ascii_lc(getc(b, bi)))
        ai += 1
        bi += 1
    end

    return ac == ':' && bc == '\0'
end

"""
Convert ASCII (RFC20) character `c` to lower case.
"""
ascii_lc(c::UInt8) = c in UInt8('A'):UInt8('Z') ? c + 0x20 : c


function Base.get(s::Header, key, default=nothing)
    for f in s
        if isequal(f, key)
            return value(f)
        end
    end
    return default
end 

end

import .LazyHTTP.FieldName
import .LazyHTTP.Header
import .LazyHTTP.RequestHeader
import .LazyHTTP.ResponseHeader
import .LazyHTTP.value
import .LazyHTTP.status
import .LazyHTTP.version
import .LazyHTTP.method
import .LazyHTTP.target

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
    @show x => value(x)
    @show SubString(x) => SubString(value(x))
end

function foo(h)
    sum = 0

    for x in h
        sum += ncodeunits(x)
        sum += ncodeunits(value(x))
    end
    sum
end

foo(h)

using InteractiveUtils

@time foo(h)
@time foo(h)
#@code_warntype foo(h)
#@code_native foo(h)

println("lazyget")
@time get(h, "X")
@time get(h, "X")

@show HTTP.header(m, "X")
@show get(h, "X")

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

#s = ":?"
#@show s

#f = FieldName(s, 1)
#@show f


