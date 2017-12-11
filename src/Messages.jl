module Messages

export Message, Request, Response, Body,
       method, iserror, isredirect, parentcount,
       header, setheader, defaultheader, setlengthheader,
       waitforheaders

import ..HTTP

using ..Pairs
using ..IOExtras
using ..Bodies
using ..Parsers
import ..Parsers

import ..@debug, ..DEBUG_LEVEL

import MbedTLS.SSLContext


"""
    Request

Represents a HTTP Request Message.

The `parent` field refers to the `Response` (if any) that led to this request
(e.g. in the case of a redirect).
"""

mutable struct Request
    method::String
    uri::String
    version::VersionNumber
    headers::Vector{Pair{String,String}}
    body::Body
    parent
end

Request() = Request("", "")
Request(method::String, uri, headers=[], body=Body(); parent=nothing) =
    Request(method, uri == "" ? "/" : uri, v"1.1",
            mkheaders(headers), body, parent)

Request(bytes) = read!(IOBuffer(bytes), Request())
Base.parse(::Type{Request}, str::AbstractString) = Request(str)

mkheaders(v::Vector{Pair{String,String}}) = v
mkheaders(x) = [string(k) => string(v) for (k,v) in x]


"""
    Response

Represents a HTTP Response Message.

The `parent` field refers to the `Request` that yielded this `Response`.

The `headerscomplete` `Condition` is raised when the `Parser` has finished
reading the response headers. This allows the `status` and `header` fields to
be read used asynchronously without waiting for the entire body to be parsed.
"""

mutable struct Response
    version::VersionNumber
    status::Int16
    headers::Vector{Pair{String,String}}
    body::Body
    parent
    headerscomplete::Condition
end

Response(status::Int=0, headers=[]; body=Body(), parent=nothing) =
    Response(v"1.1", status, headers, body, parent, Condition())

Response(bytes) = read!(IOBuffer(bytes), Response())
Base.parse(::Type{Response}, str::AbstractString) = Response(str)


const Message = Union{Request,Response}

"""
    iserror(::Response)
    isredirect(::Response)

Does this `Response` have an error or redirect status?
"""

iserror(r::Response) = r.status < 200 || r.status >= 300
isredirect(r::Response) = r.status in (301, 302, 307, 308)


"""
    method(::Response)

Method of the `Request` that yielded this `Response`.
"""

method(r::Response) = r.parent == nothing ? "" : r.parent.method


"""
    parentcount(::Response)

How many redirect parents does this `Response` have?
"""

function parentcount(r::Response)
    if r.parent == nothing || r.parent.parent == nothing
        return 0
    else
        return 1 + parentcount(r.parent.parent)
    end
end


"""
    statustext(::Response)

`String` representation of a HTTP status code. e.g. `200 => "OK"`.
"""

statustext(r::Response) = Base.get(Parsers.STATUS_CODES, r.status, "Unknown Code")


"""
   waitforheaders(::Response)

Wait for the `Parser` (in a different task) to finish parsing the headers.
"""

waitforheaders(r::Response) = while r.status == 0; wait(r.headerscomplete) end


"""
   header(message, key [, default=""])

Get header value for `key`.
"""
header(m, k::String, d::String="") = getbyfirst(m.headers, k, k => d, lceq)[2]
lceq(a,b) = lowercase(a) == lowercase(b)


"""
   setheader(message, key => value)

Set header `value` for `key`.
"""
setheader(m, v::Pair) = setbyfirst(m.headers, Pair{String,String}(v), lceq)


"""
   defaultheader(message, key => value)

Set header `value` for `key` if it is not already set.
"""

function defaultheader(m, v::Pair)
    if header(m, first(v)) == ""
        setheader(m, v)
    end
    return
end



"""
    setlengthheader(::Response)

Set the Content-Length or Transfer-Encoding header according to the
`Response` `Body`.
"""

function setlengthheader(r::Request)

    l = length(r.body)
    if l == Bodies.unknownlength
        setheader(r, "Transfer-Encoding" => "chunked")
    else
        setheader(r, "Content-Length" => string(l))
    end
    return
end


"""
   appendheader(message, key => value)

Append a header value to `message.headers`.

If `key` is `""` the `value` is appended to the value of the previous header.

If `key` is the same as the previous header, the `vale` is appended to the
value of the previous header with a comma delimiter.
https://stackoverflow.com/a/24502264

`Set-Cookie` headers are not comma-combined because cookies often contain
internal commas. https://tools.ietf.org/html/rfc6265#section-3
"""

function appendheader(m::Message, header::Pair{String,String})
    c = m.headers
    k,v = header
    if k == ""
        c[end] = c[end][1] => string(c[end][2], v)
    elseif k != "Set-Cookie" && length(c) > 0 && k == c[end][1]
        c[end] = c[end][1] => string(c[end][2], ", ", v)
    else
        push!(m.headers, header)
    end
    return
end


"""
    httpversion(Message)

e.g. `"HTTP/1.1"`
"""

httpversion(m::Message) = "HTTP/$(m.version.major).$(m.version.minor)"


"""
    writestartline(::IO, message)

e.g. `"GET /path HTTP/1.1\\r\\n"` or `"HTTP/1.1 200 OK\\r\\n"`
"""

function writestartline(io::IO, r::Request)
    write(io, "$(r.method) $(r.uri) $(httpversion(r))\r\n")
    return
end

function writestartline(io::IO, r::Response)
    write(io, "$(httpversion(r)) $(r.status) $(statustext(r))\r\n")
    return
end


"""
    writeheaders(::IO, message)

Write a line for each "name: value" pair and a trailing blank line.
"""

function writeheaders(io::IO, m::Message)
    for (name, value) in m.headers
        write(io, "$name: $value\r\n")
    end
    write(io, "\r\n")
    return
end


"""
    write(::IO, message)

Write start line, headers and body of HTTP Message.
"""

function Base.write(io::IO, m::Message)
    writestartline(io, m)
    writeheaders(io, m)
    write(io, m.body)
    return
end


"""
    readstartline(message, p::Parser)

Read the start-line metadata from `Parser` into a `message` struct.
"""

function readstartline!(r::Response, m::Parsers.Message)
    r.version = VersionNumber(m.major, m.minor)
    r.status = m.status
    if isredirect(r)
        r.body = Body()
    end
    notify(r.headerscomplete)
    yield()
    return
end

function readstartline!(r::Request, m::Parsers.Message)
    r.version = VersionNumber(m.major, m.minor)
    r.method = string(m.method)
    r.uri = m.url
    return
end


"""
    read!(io, parser)

Read data from `io` into `parser` until `eof`
or the parser finds the end of the message.
"""

function Base.read!(io::IO, p::Parser)

    while !eof(io)
        bytes = readavailable(io)
        if isempty(bytes)
            @debug 1 "Bug https://github.com/JuliaWeb/MbedTLS.jl/issues/113 !"
            @assert isa(io, SSLContext)
            @assert eof(io)
            break
        end
        @assert length(bytes) > 0

        n = parse!(p, bytes)
        @assert n == length(bytes) || messagecomplete(p)
        @assert n <= length(bytes)
        @debug 3 "p.state = $(Parsers.ParsingStateCode(p.state))"

        if messagecomplete(p)
            excess = view(bytes, n+1:length(bytes))
            if !isempty(excess)
                unread!(io, excess)
            end
            return
        end
    end

    if eof(io) && !waitingforeof(p)
        throw(ParsingError(headerscomplete(p) ? Parsers.HPE_BODY_INCOMPLETE :
                                                Parsers.HPE_HEADERS_INCOMPLETE))
    end
    return
end


"""
    Parser(::Message)

Create a parser that stores parsed data into a `Message`.
"""
function Parser(m::Message)
    p = Parser()
    p.onbody = x->write(m.body, x)
    p.onheader = x->appendheader(m, x)
    p.onheaderscomplete = x->readstartline!(m, x)
    p.isheadresponse = (isa(m, Response) && method(m) in ("HEAD", "CONNECT"))
                       # FIXME CONNECT??
    return p
end


"""
    read!(io, message)

Read data from `io` into a `Message` struct.
"""

function Base.read!(io::IO, m::Message)
    read!(io, Parser(m))
    close(m.body)
    return m
end


Base.take!(m::Message) = take!(m.body)


function Base.String(m::Message)
    io = IOBuffer()
    write(io, m)
    String(take!(io))
end


function Base.show(io::IO, m::Message)
    println(io, typeof(m), ":")
    println(io, "\"\"\"")
    writestartline(io, m)
    writeheaders(io, m)
    show(io, m.body)
    print(io, "\"\"\"")
    return
end


end # module Messages
