"""
The `Messages` module defines structs that represent [`HTTP.Request`](@ref)
and [`HTTP.Response`](@ref) Messages.

The `Response` struct has a `request` field that points to the corresponding
`Request`; and the `Request` struct has a `response` field.
The `Request` struct also has a `parent` field that points to a `Response`
in the case of HTTP Redirect.


The Messages module defines `IO` `read` and `write` methods for Messages
but it does not deal with URIs, creating connections, or executing requests.

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
This function calls [`HTTP.Parsers.parse_header_field`](@ref) and passes each
header-field to [`HTTP.Messages.appendheader`](@ref).

`readheaders` relies on [`HTTP.IOExtras.unread!`](@ref) to push excess
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

export Message, Request, Response, HeaderSizeError,
       reset!, status, method, headers, uri, body,
       iserror, isredirect, ischunked, issafe, isidempotent,
       header, hasheader, setheader, defaultheader, appendheader,
       mkheaders, readheaders, headerscomplete,
       readchunksize,
       writeheaders, writestartline,
       bodylength, unknown_length,
       payload

import ..HTTP

using ..Pairs
import ..@warn
using ..IOExtras
using ..Parsers
import ..@require, ..precondition_error
import ..bytes, ..bytesavailable

const unknown_length = typemax(Int)

abstract type Message end

# HTTP Response

"""
    Response <: Message

Represents a HTTP Response Message.

- `version::VersionNumber`
   [RFC7230 2.6](https://tools.ietf.org/html/rfc7230#section-2.6)

- `status::Int16`
   [RFC7230 3.1.2](https://tools.ietf.org/html/rfc7230#section-3.1.2)
   [RFC7231 6](https://tools.ietf.org/html/rfc7231#section-6)

- `headers::Vector{Pair{String,String}}`
   [RFC7230 3.2](https://tools.ietf.org/html/rfc7230#section-3.2)

- `body::Vector{UInt8}`
   [RFC7230 3.3](https://tools.ietf.org/html/rfc7230#section-3.3)

- `request`, the `Request` that yielded this `Response`.
"""
mutable struct Response <: Message
    version::VersionNumber
    status::Int16
    headers::Headers
    body::Vector{UInt8}
    request::Message

    function Response(status::Int, headers=[]; body=UInt8[], request=nothing)
        r = new()
        r.version = v"1.1"
        r.status = status
        r.headers = mkheaders(headers)
        r.body = bytes(body)
        if request != nothing
            r.request = request
        end
        return r
    end
end

Response() = Request().response

Response(s::Int, body::AbstractVector{UInt8}) = Response(s; body=body)
Response(s::Int, body::AbstractString) = Response(s, bytes(body))

Response(body) = Response(200, body)

Base.convert(::Type{Response},s::AbstractString) = Response(s)

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
    statustext(::Response) -> String

`String` representation of a HTTP status code. e.g. `200 => "OK"`.
"""
statustext(r::Response) = Base.get(STATUS_MESSAGES, r.status, "Unknown Code")

@deprecate status(r::Response) getfield(r, :status)
@deprecate headers(r::Response) getfield(r, :headers)
@deprecate body(r::Response) getfield(r, :body)

# HTTP Request

"""
    Request <: Message

Represents a HTTP Request Message.

- `method::String`
   [RFC7230 3.1.1](https://tools.ietf.org/html/rfc7230#section-3.1.1)

- `target::String`
   [RFC7230 5.3](https://tools.ietf.org/html/rfc7230#section-5.3)

- `version::VersionNumber`
   [RFC7230 2.6](https://tools.ietf.org/html/rfc7230#section-2.6)

- `headers::Vector{Pair{String,String}}`
   [RFC7230 3.2](https://tools.ietf.org/html/rfc7230#section-3.2)

- `body::Vector{UInt8}`
   [RFC7230 3.3](https://tools.ietf.org/html/rfc7230#section-3.3)

- `response`, the `Response` to this `Request`

- `txcount`, number of times this `Request` has been sent (see RetryRequest.jl).

- `parent`, the `Response` (if any) that led to this request
  (e.g. in the case of a redirect).
   [RFC7230 6.4](https://tools.ietf.org/html/rfc7231#section-6.4)
"""
mutable struct Request <: Message
    method::String
    target::String
    version::VersionNumber
    headers::Headers
    body::Vector{UInt8}
    response::Response
    txcount::Int
    parent
end

Request() = Request("", "")

function Request(method::String, target, headers=[], body=UInt8[];
                 version=v"1.1", parent=nothing)
    r = Request(method,
                target == "" ? "/" : target,
                version,
                mkheaders(headers),
                bytes(body),
                Response(0),
                0,
                parent)
    r.response.request = r
    return r
end

mkheaders(h::Headers) = h
mkheaders(h)::Headers = Header[string(k) => string(v) for (k,v) in h]

@deprecate method(r::Request) getfield(r, :method)
@deprecate uri(r::Request) getfield(r, :target)
@deprecate headers(r::Request) getfield(r, :headers)
@deprecate body(r::Request) getfield(r, :body)

# HTTP Message state and type queries

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
    ischunked(::Message)

Does the `Message` have a "Transfer-Encoding: chunked" header?
"""
ischunked(m) = any(h->(lowercase(h[1]) == "transfer-encoding" &&
                       endswith(lowercase(h[2]), "chunked")),
                   m.headers)

"""
    headerscomplete(::Message)

Have the headers been read into this `Message`?
"""
headerscomplete(r::Response) = r.status != 0 && r.status != 100
headerscomplete(r::Request) = r.method != ""

"""
"The presence of a message body in a response depends on both the
 request method to which it is responding and the response status code.
 Responses to the HEAD request method never include a message body [].
 2xx (Successful) responses to a CONNECT request method (Section 4.3.6 of
 [RFC7231]) switch to tunnel mode instead of having a message body.
 All 1xx (Informational), 204 (No Content), and 304 (Not Modified)
 responses do not include a message body.  All other responses do
 include a message body, although the body might be of zero length."
[RFC7230 3.3](https://tools.ietf.org/html/rfc7230#section-3.3)
"""
bodylength(r::Response)::Int =
                 r.request.method == "HEAD" ? 0 :
                     r.status in [204, 304] ? 0 :
    (l = header(r, "Content-Length")) != "" ? parse(Int, l) :
                                              unknown_length

"""
"The presence of a message body in a request is signaled by a
 Content-Length or Transfer-Encoding header field.  Request message
 framing is independent of method semantics, even if the method does
 not define any use for a message body."
[RFC7230 3.3](https://tools.ietf.org/html/rfc7230#section-3.3)
"""
bodylength(r::Request)::Int =
    ischunked(r) ? unknown_length :
                   parse(Int, header(r, "Content-Length", "0"))

# HTTP header-fields

Base.getindex(m::Message, k) = header(m, k)

"""
    header(::Message, key [, default=""]) -> String

Get header value for `key` (case-insensitive).
"""
header(m::Message, k, d="") = header(m.headers, k, d)
header(h::Headers, k::AbstractString, d::AbstractString="") =
    getbyfirst(h, k, k => d, lceq)[2]
lceq(a,b) = lowercase(a) == lowercase(b)

# FIXME consider allocation and speed efficiency of lowercase comparisons
# - Make a LCString <: AbstractString wrapper that translates in-line?
# - Make a lcmp function that translates as it goes?
# https://github.com/JuliaLang/julia/issues/19972


"""
    hasheader(::Message, key) -> Bool

Does header value for `key` exist (case-insensitive)?
"""
hasheader(m, k::AbstractString) = header(m, k) != ""

"""
    hasheader(::Message, key, value) -> Bool

Does header for `key` match `value` (both case-insensitive)?
"""
hasheader(m, k::AbstractString, v::AbstractString) =
    lowercase(header(m, k)) == lowercase(v)

"""
    setheader(::Message, key => value)

Set header `value` for `key` (case-insensitive).
"""
setheader(m::Message, v) = setheader(m.headers, v)
setheader(h::Headers, v::Header) = setbyfirst(h, v, lceq)
setheader(h::Headers, v::Pair) =
    setbyfirst(h, Header(SubString(v.first), SubString(v.second)), lceq)

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
    appendheader(::Message, key => value)

Append a header value to `message.headers`.

If `key` is `""` the `value` is appended to the value of the previous header.

If `key` is the same as the previous header, the `value` is [appended to the
value of the previous header with a comma
delimiter](https://stackoverflow.com/a/24502264)

`Set-Cookie` headers are not comma-combined because [cookies often contain
internal commas](https://tools.ietf.org/html/rfc6265#section-3).
"""
function appendheader(m::Message, header::Header)
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

# HTTP payload body

#Like https://github.com/JuliaIO/FileIO.jl/blob/v0.6.1/src/FileIO.jl#L19 ?
@deprecate load(m::Message) payload(m, String)

function payload(m::Message)::Vector{UInt8}
    enc = lowercase(first(split(header(m, "Transfer-Encoding"), ", ")))
    return enc in ["", "identity", "chunked"] ? m.body : decode(m, enc)
end

payload(m::Message, ::Type{String}) =
    hasheader(m, "Content-Type", "ISO-8859-1") ? iso8859_1_to_utf8(payload(m)) :
                                                 String(payload(m))

function decode(m::Message, encoding::String)::Vector{UInt8}
    if encoding == "gzip"
        # Use https://github.com/bicycle1885/TranscodingStreams.jl ?
    end
    @warn "Decoding of HTTP Transfer-Encoding is not implemented yet!"
    return m.body
end

# Writing HTTP Messages to IO streams

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
    write(io, "$(r.method) $(r.target) $(httpversion(r))\r\n")
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
    writestartline(io, m)
    for (name, value) in m.headers
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

# Reading HTTP Messages from IO streams

"""
    readheaders(::IO, ::Message)

Read headers (and startline) from an `IO` stream into a `Message` struct.
Throw `EOFError` if input is incomplete.
"""
function readheaders(io::IO, message::Message)
    bytes = String(readuntil(io, find_end_of_header))
    bytes = parse_start_line!(bytes, message)
    parse_header_fields!(bytes, message)
    return
end

parse_start_line!(bytes, r::Response) = parse_status_line!(bytes, r)

parse_start_line!(bytes, r::Request) = parse_request_line!(bytes, r)

function parse_header_fields!(bytes::SubString{String}, m::Message)

    h, bytes = parse_header_field(bytes)
    while !(h === Parsers.emptyheader)
        appendheader(m, h)
        h, bytes = parse_header_field(bytes)
    end
    return
end

"""
Read chunk-size from an `IO` stream.
After the final zero size chunk, read trailers into a `Message` struct.
"""
function readchunksize(io::IO, message::Message)::Int
    n = parse_chunk_size(readuntil(io, find_end_of_line))
    if n == 0
        bytes = readuntil(io, find_end_of_trailer)
        if bytes[2] != UInt8('\n')
            parse_header_fields!(SubString(String(bytes)), message)
        end
    end
    return n
end

# Debug message printing

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

const STATUS_MESSAGES = (()->begin
    v = fill("Unknown Code", 530)
    v[100] = "Continue"
    v[101] = "Switching Protocols"
    v[102] = "Processing"                            # RFC 2518 => obsoleted by RFC 4918
    v[200] = "OK"
    v[201] = "Created"
    v[202] = "Accepted"
    v[203] = "Non-Authoritative Information"
    v[204] = "No Content"
    v[205] = "Reset Content"
    v[206] = "Partial Content"
    v[207] = "Multi-Status"                          # RFC 4918
    v[300] = "Multiple Choices"
    v[301] = "Moved Permanently"
    v[302] = "Moved Temporarily"
    v[303] = "See Other"
    v[304] = "Not Modified"
    v[305] = "Use Proxy"
    v[307] = "Temporary Redirect"
    v[400] = "Bad Request"
    v[401] = "Unauthorized"
    v[402] = "Payment Required"
    v[403] = "Forbidden"
    v[404] = "Not Found"
    v[405] = "Method Not Allowed"
    v[406] = "Not Acceptable"
    v[407] = "Proxy Authentication Required"
    v[408] = "Request Time-out"
    v[409] = "Conflict"
    v[410] = "Gone"
    v[411] = "Length Required"
    v[412] = "Precondition Failed"
    v[413] = "Request Entity Too Large"
    v[414] = "Request-URI Too Large"
    v[415] = "Unsupported Media Type"
    v[416] = "Requested Range Not Satisfiable"
    v[417] = "Expectation Failed"
    v[418] = "I'm a teapot"                        # RFC 2324
    v[422] = "Unprocessable Entity"                # RFC 4918
    v[423] = "Locked"                              # RFC 4918
    v[424] = "Failed Dependency"                   # RFC 4918
    v[425] = "Unordered Collection"                # RFC 4918
    v[426] = "Upgrade Required"                    # RFC 2817
    v[428] = "Precondition Required"               # RFC 6585
    v[429] = "Too Many Requests"                   # RFC 6585
    v[431] = "Request Header Fields Too Large"     # RFC 6585
    v[440] = "Login Timeout"
    v[444] = "nginx error: No Response"
    v[495] = "nginx error: SSL Certificate Error"
    v[496] = "nginx error: SSL Certificate Required"
    v[497] = "nginx error: HTTP -> HTTPS"
    v[499] = "nginx error or Antivirus intercepted request or ArcGIS error"
    v[500] = "Internal Server Error"
    v[501] = "Not Implemented"
    v[502] = "Bad Gateway"
    v[503] = "Service Unavailable"
    v[504] = "Gateway Time-out"
    v[505] = "HTTP Version Not Supported"
    v[506] = "Variant Also Negotiates"             # RFC 2295
    v[507] = "Insufficient Storage"                # RFC 4918
    v[509] = "Bandwidth Limit Exceeded"
    v[510] = "Not Extended"                        # RFC 2774
    v[511] = "Network Authentication Required"     # RFC 6585
    v[520] = "CloudFlare Server Error: Unknown"
    v[521] = "CloudFlare Server Error: Connection Refused"
    v[522] = "CloudFlare Server Error: Connection Timeout"
    v[523] = "CloudFlare Server Error: Origin Server Unreachable"
    v[524] = "CloudFlare Server Error: Connection Timeout"
    v[525] = "CloudFlare Server Error: Connection Failed"
    v[526] = "CloudFlare Server Error: Invalid SSL Ceritificate"
    v[527] = "CloudFlare Server Error: Railgun Error"
    v[530] = "Site Frozen"
    return v
end)()


end # module Messages
