module Messages

export Message, Request, Response, Body,
       method, header, setheader, request
  

include("Bodies.jl")
using .Bodies

import ..@lock
import ..Parser
import ..parse!
import ..messagecomplete
import ..waitingforeof
import ..ParsingStateCode
import ..URIs: URI, scheme, hostname, port, resource
import ..HTTP: STATUS_CODES, getkey, setkey, @debug

include("Connections.jl")
using .Connections
import .Connections.SSLContext

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

Request(method="", uri="", headers=[], body=Body(); parent=nothing) =
    Request(method, uri == "" ? "/" : uri, v"1.1",
            mkheaders(headers), body, parent)

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

Response(status=0, headers=[]; body=Body(), parent=nothing) =
    Response(v"1.1", status, headers, body, parent, Condition())

const Message = Union{Request,Response}


"""
    method(::Response)

Method of the `Request` that yielded this `Response`.
"""

method(r::Response) = r.parent == nothing ? "" : r.parent.method


"""
    statustext(::Response)

`String` representation of a HTTP status code. e.g. `200 => "OK"`.
"""

statustext(r::Response) = Base.get(STATUS_CODES, r.status, "Unknown Code")


"""
   waitforheaders(::Response)

Wait for the `Parser` (in a different task) to finish parsing the headers.
"""

waitforheaders(r::Response) = while r.status == 0; wait(r.headerscomplete) end


"""
   header(message, key [, default=""])

Get header value for `key`.
"""
header(m, k::String, default::String="") = getkey(m.headers, k, k => default)[2]


"""
   setheader(message, key => value)

Set header `value` for `key`.
"""
setheader(m, v::Pair{String,String}) = setkey(m.headers, v)


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
end

function writestartline(io::IO, r::Response)
    write(io, "$(httpversion(r)) $(r.status) $(statustext(r))\r\n")
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
end


"""
    write(::IO, message)

Write start line, headers and body of HTTP Message.
"""

function Base.write(io::IO, m::Message)
    writestartline(io, m)
    writeheaders(io, m)
    write(io, m.body)
end


"""
    readstartline(message, p::Parser)

Read the start-line metadata from `Parser` into a `message` struct.
"""

function readstartline!(r::Response, p::Parser)
    r.version = VersionNumber(p.major, p.minor)
    r.status = p.status
    notify(r.headerscomplete)
    yield()
end

function readstartline!(r::Request, p::Parser)
    r.version = VersionNumber(p.major, p.minor)
    r.method = string(p.method)
    r.uri = string(p.url)
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
            @debug "MbedTLS https://github.com/JuliaWeb/MbedTLS.jl/issues/113 !"
            @assert isa(io, SSLContext)
            @assert eof(io)
            break
        end
        @assert length(bytes) > 0

        n = parse!(p, bytes)
        @assert n == length(bytes) || messagecomplete(p)
        @assert n <= length(bytes)

        @debug ParsingStateCode(p.state)

        if messagecomplete(p)
            excess = view(bytes, n+1:length(bytes))
            if !isempty(excess)
                unread!(io, excess)
            end
            return
        end
    end

    if eof(io) && !waitingforeof(p)
        throw(EOFError())
    end
end


"""
    read!(io, message)

Read data from `io` into a `Message` struct.
"""

function Base.read!(io::IO, m::Message)

    p = Parser()
    p.onbody = x->write(m.body, x)
    p.onheader = x->appendheader(m, x)
    p.onheaderscomplete = ()->readstartline!(m, p)
    p.isheadresponse = (isa(m, Response) && method(m) in ("HEAD", "CONNECT"))
                       # FIXME CONNECT??

    read!(io, p)
    close(m.body)
end


"""
    connecturi(::URI)

Get a `Connection` for a `URI` from the connection pool.
"""

function connecturi(uri::URI)
    getconnection(scheme(uri) == "https" ? SSLContext : TCPSocket,
                  hostname(uri),
                  parse(UInt, port(uri)))
end


"""
    request(::URI, ::Request, ::Response)

Get a `Connection` for a `URI`, send a `Request` and fill in a `Response`.
"""

function request(uri::URI, req::Request, res::Response)

    #FIXME set Content-Length header?

    host = hostname(uri)
    if header(req, "Host") == ""
        setheader(req, "Host" => host)
    end

    c = connecturi(uri)
    @debug "write to: $c\n$req"
    write(c, req)
    readresponse!(c, res)
    @debug "read from: $c\n$req"

    return res
end


"""
    request(method, uri [, headers=[] [, body="" ]; kw args...)

Execute a `Request` and return a `Response`.

`parent=` optionally set a parent `Response`.

`response_stream=` optional `IO` stream for response body.


e.g. use a stream as a request body:

```
io = open("request", "r")
r = request("POST", "http://httpbin.org/post", [], io)
```

e.g. send a response body to a stream:

```
io = open("response_file", "w")
r = request("GET", "http://httpbin.org/stream/100", response_stream=io)
println(stat("response_file").size)
0
sleep(1)
println(stat("response_file").size)
14990
```
"""

function request(method::String, uri, headers=[], body="";
                 parent=nothing, response_stream=nothing)

    u = URI(uri)

    req = Request(method,
                  method == "CONNECT" ? host(u) : resource(u),
                  headers,
                  Body(body);
                  parent=parent)

    res = Response(body=Body(response_stream), parent=req)

    if isstream(res.body)
        @schedule request(u, req, res)
        waitforheaders(res)
    else
        request(u, req, res)
    end

    return res
end


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
end


end # module Messages
