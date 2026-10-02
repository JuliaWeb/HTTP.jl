"""
The `Messages` module defines structs that represent [`HTTP.Request`](@ref)
and [`HTTP.Response`](@ref) Messages.

The `Response` struct has a `request` field that points to the corresponding
`Request`; and the `Request` struct has a `response` field.
The `Request` struct also has a `parent` field that points to a `Response`
in the case of HTTP Redirect.


The Messages module defines `IO` `read` and `write` methods for Messages
but it does not deal with URIs, creating connections, or executing requests.
The 

The `read` methods throw `EOFError` exceptions if input data is incomplete.
and call parser functions that may throw `HTTP.ParsingError` exceptions.
The `read` and `write` methods may also result in low level `IO` exceptions.


### Sending Messages

Messages are formatted and written to an `IO` stream by
[`Base.write(::IO,::HTTP.Messages.Message)`](@ref) and or
[`HTTP.Messages.writeheaders`](@ref).


### Receiving Messages

Messages are parsed from `IO` stream data by
[`HTTP.Messages.readheaders`](@ref).
This function calls [`HTTP.Messages.appendheader`](@ref) and
[`HTTP.Messages.readstartline!`](@ref).

The `read` methods rely on [`HTTP.IOExtras.unread!`](@ref) to push excess
data back to the input stream.


### Headers

Headers are represented by `Vector{Pair{String,String}}`. As compared to
`Dict{String,String}` this allows [repeated header fields and preservation of
order](https://tools.ietf.org/html/rfc7230#section-3.2.2).

Header values can be accessed by name using 
[`HTTP.Messages.header`](@ref) and
[`HTTP.Messages.setheader`](@ref) (case-insensitive).

The [`HTTP.Messages.appendheader`](@ref) function handles combining
multi-line values, repeated header fields and special handling of
multiple `Set-Cookie` headers.

### Bodies

The `HTTP.Message` structs represent the Message Body as `Vector{UInt8}`.

Streaming of request and response bodies is handled by the
[`HTTP.StreamLayer`](@ref) and the [`HTTP.Stream`](@ref) `<: IO` stream.
"""


module Messages

export Message, Request, Response,
       reset!,
       iserror, isredirect, ischunked, issafe, isidempotent,
       header, hasheader, setheader, defaultheader, appendheader,
       mkheaders, readheaders, headerscomplete, readtrailers, writeheaders,
       readstartline!, writestartline

if VERSION > v"0.7.0-DEV.2338"
using Unicode
end

import ..HTTP

using ..Pairs
using ..IOExtras
using ..Parsers
import ..Parsers
import ..Parsers: headerscomplete, reset!

abstract type Message end

"""
    Response <: Message

Represents a HTTP Response Message.

- `version::VersionNumber`
- `status::Int16`
- `headers::Vector{Pair{String,String}}`
- `body::Vector{UInt8}`
- `request`, the `Request` that yielded this `Response`.
"""

mutable struct Response <: Message
    version::VersionNumber
    status::Int16
    headers::Headers
    body::Vector{UInt8}
    request
end

Response(status::Int=0, headers=[]; body=UInt8[], request=nothing) =
    Response(v"1.1", status, mkheaders(headers), body, request)

Response(bytes) = parse(Response, bytes)

function reset!(r::Response)
    r.version = v"1.1"
    r.status = 0
    if !isempty(r.headers)
        empty!(r.headers)
    end
    if !isempty(r.body)
        empty!(r.body)
    end
end


"""
    Request <: Message

Represents a HTTP Request Message.

- `method::String`
- `uri::String`
- `version::VersionNumber`
- `headers::Vector{Pair{String,String}}`
- `body::Vector{UInt8}`
- `response`, the `Response` to this `Request`
- `parent`, the `Response` (if any) that led to this request
  (e.g. in the case of a redirect).
"""

mutable struct Request <: Message
    method::String
    uri::String
    version::VersionNumber
    headers::Headers
    body::Vector{UInt8}
    response::Response
    parent
end

Request() = Request("", "")

function Request(method::String, uri, headers=[], body=UInt8[]; parent=nothing)
    r = Request(method,
                uri == "" ? "/" : uri,
                v"1.1",
                mkheaders(headers),
                body,
                Response(),
                parent)
    r.response.request = r
    return r
end

Request(bytes) = parse(Request, bytes)

mkheaders(h::Headers) = h
mkheaders(h)::Headers = Header[string(k) => string(v) for (k,v) in h]

"""
    issafe(::Request)

https://tools.ietf.org/html/rfc7231#section-4.2.1
"""

issafe(r::Request) = r.method in ["GET", "HEAD", "OPTIONS", "TRACE"]


"""
    isidempotent(::Request)

https://tools.ietf.org/html/rfc7231#section-4.2.2
"""

isidempotent(r::Request) = issafe(r) || r.method in ["PUT", "DELETE"]


"""
    iserror(::Response)

Does this `Response` have an error status?
"""

iserror(r::Response) = r.status != 0 && r.status != 100 && r.status != 101 &&
                       (r.status < 200 || r.status >= 300) && !isredirect(r)


"""
    isredirect(::Response)

Does this `Response` have a redirect status?
"""
isredirect(r::Response) = r.status in (301, 302, 307, 308)


"""
    statustext(::Response) -> String

`String` representation of a HTTP status code. e.g. `200 => "OK"`.
"""

statustext(r::Response) = Base.get(Parsers.STATUS_CODES, r.status, "Unknown Code")


"""
    header(::Message, key [, default=""]) -> String

Get header value for `key` (case-insensitive).
"""
header(m, k, d="") = header(m.headers, k, d)
header(h::Headers, k::String, d::String="") = getbyfirst(h, k, k => d, lceq)[2]
lceq(a,b) = lowercase(a) == lowercase(b)


"""
    hasheader(::Message, key) -> Bool

Does header value for `key` exist (case-insensitive)?
"""
hasheader(m, k::String) = header(m, k) != ""


"""
    setheader(::Message, key => value)

Set header `value` for `key` (case-insensitive).
"""
setheader(m, v) = setheader(m.headers, v)
setheader(h::Headers, v::Pair) = setbyfirst(h, Pair{String,String}(v), lceq)


"""
    defaultheader(::Message, key => value)

Set header `value` for `key` if it is not already set.
"""

function defaultheader(m, v::Pair)
    if header(m, first(v)) == ""
        setheader(m, v)
    end
    return
end


"""
    ischunked(::Message)

Does the `Message` have a "Transfer-Encoding: chunked" header?
"""

ischunked(m) = header(m, "Transfer-Encoding") == "chunked"


"""
    appendheader(::Message, key => value)

Append a header value to `message.headers`.

If `key` is `""` the `value` is appended to the value of the previous header.

If `key` is the same as the previous header, the `vale` is [appended to the
value of the previous header with a comma
delimiter](https://stackoverflow.com/a/24502264)

`Set-Cookie` headers are not comma-combined because [cookies often contain
internal commas](https://tools.ietf.org/html/rfc6265#section-3).
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
    httpversion(::Message)

e.g. `"HTTP/1.1"`
"""

httpversion(m::Message) = "HTTP/$(m.version.major).$(m.version.minor)"


"""
    writestartline(::IO, ::Message)

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
    writeheaders(::IO, ::Message)

Write `Message` start line and
a line for each "name: value" pair and a trailing blank line.
"""

function writeheaders(io::IO, m::Message)
    writestartline(io, m)                 # FIXME To avoid fragmentation, maybe
    for (name, value) in m.headers        # buffer header before sending to `io`
        write(io, "$name: $value\r\n")
    end
    write(io, "\r\n")
    return
end


"""
    write(::IO, ::Message)

Write start line, headers and body of HTTP Message.
"""

function Base.write(io::IO, m::Message)
    writeheaders(io, m)
    write(io, m.body)
    return
end


function Base.String(m::Message)
    io = IOBuffer()
    write(io, m)
    String(take!(io))
end


"""
    readstartline!(::Parsers.Message, ::Message)

Read the start-line metadata from Parser into a `::Message` struct.
"""

function readstartline!(m::Parsers.Message, r::Response)
    r.version = VersionNumber(m.major, m.minor)
    r.status = m.status
    return
end

function readstartline!(m::Parsers.Message, r::Request)
    r.version = VersionNumber(m.major, m.minor)
    r.method = string(m.method)
    r.uri = m.url
    return
end


"""
    readheaders(::IO, ::Parser, ::Message)

Read headers (and startline) from an `IO` stream into a `Message` struct.
Throw `EOFError` if input is incomplete.
"""

function readheaders(io::IO, parser::Parser, message::Message)

    while !headerscomplete(parser) && !eof(io)
        excess = parseheaders(parser, readavailable(io)) do h
            appendheader(message, h)
        end
        unread!(io, excess)
    end
    if !headerscomplete(parser)
        throw(EOFError())
    end
    readstartline!(parser.message, message)
    return message
end


"""
    headerscomplete(::Message)

Have the headers been read into this `Message`?
"""

headerscomplete(r::Response) = r.status != 0 && r.status != 100
headerscomplete(r::Request) = r.method != ""


"""
    readtrailers(::IO, ::Parser, ::Message)

Read trailers from an `IO` stream into a `Message` struct.
"""

function readtrailers(io::IO, parser::Parser, message::Message)
    if messagehastrailing(parser)
        readheaders(io, parser, message)
    end
    return message
end


"""
    readbody(::IO, ::Parser) -> Vector{UInt8}

Read message body from an `IO` stream.
"""

function readbody(io::IO, parser::Parser)
    body = IOBuffer()
    while !bodycomplete(parser) && !eof(io)
        data, excess = parsebody(parser, readavailable(io))
        write(body, data)
        unread!(io, excess)
    end
    return take!(body)
end


function Base.parse(::Type{T}, str::AbstractString) where T <: Message
    bytes = IOBuffer(str)
    p = Parser()
    m = T()
    readheaders(bytes, p, m)
    m.body = readbody(bytes, p)
    readtrailers(bytes, p, m)
    seteof(p)
    if !messagecomplete(p)
        throw(EOFError())
    end
    return m
end


"""
    set_show_max(x)

Set the maximum number of body bytes to be displayed by `show(::IO, ::Message)`
"""

set_show_max(x) = global body_show_max = x
body_show_max = 1000


"""
    bodysummary(bytes)

The first chunk of the Message Body (for display purposes).
"""
bodysummary(bytes) = view(bytes, 1:min(length(bytes), body_show_max))

function compactstartline(m::Message)
    b = IOBuffer()
    writestartline(b, m)
    strip(String(take!(b)))
end

function Base.show(io::IO, m::Message)
    if get(io, :compact, false)
        print(io, compactstartline(m))
        if m isa Response
            print(io, " <= (", compactstartline(m.request::Request), ")")
        end
        return
    end
    println(io, typeof(m), ":")
    println(io, "\"\"\"")
    writeheaders(io, m)
    summary = bodysummary(m.body)
    write(io, summary)
    if length(m.body) > length(summary)
        println(io, "\n⋮\n$(length(m.body))-byte body")
    end
    print(io, "\"\"\"")
    return
end


end # module Messages
