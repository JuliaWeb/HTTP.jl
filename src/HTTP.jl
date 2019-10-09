module HTTP

export startwrite, startread, closewrite, closeread, stack, insert, AWS4AuthLayer,
    BasicAuthLayer, CanonicalizeLayer, ConnectionPoolLayer, ContentTypeDetectionLayer,
    DebugLayer, ExceptionLayer, MessageLayer, RedirectLayer, RetryLayer, StreamLayer,
    TimeoutLayer

const DEBUG_LEVEL = Ref(0)

Base.@deprecate escape escapeuri
Base.@deprecate URL URI

using Base64, Sockets, Dates

include("debug.jl")

include("Pairs.jl")                    ;using .Pairs
include("IOExtras.jl")                 ;using .IOExtras
include("Strings.jl")
include("URIs.jl")                     ;using .URIs
include("sniff.jl")
include("multipart.jl")
include("Parsers.jl")                  ;import .Parsers: Headers, Header,
                                                         ParseError
include("ConnectionPool.jl")
include("Messages.jl")                 ;using .Messages
include("cookies.jl")                  ;using .Cookies
include("Streams.jl")                  ;using .Streams
include("layers.jl")                   ;using .Layers

const nobody = UInt8[]

"""

    HTTP.request(method, url [, headers [, body]]; <keyword arguments>]) -> HTTP.Response

Send a HTTP Request Message and receive a HTTP Response Message.

e.g.
```julia
r = HTTP.request("GET", "http://httpbin.org/ip")
println(r.status)
println(String(r.body))
```

`headers` can be any collection where
`[string(k) => string(v) for (k,v) in headers]` yields `Vector{Pair}`.
e.g. a `Dict()`, a `Vector{Tuple}`, a `Vector{Pair}` or an iterator.

`body` can take a number of forms:

 - a `String`, a `Vector{UInt8}` or any `T` accepted by `write(::IO, ::T)`
 - a collection of `String` or `AbstractVector{UInt8}` or `IO` streams
   or items of any type `T` accepted by `write(::IO, ::T...)`
 - a readable `IO` stream or any `IO`-like type `T` for which
   `eof(T)` and `readavailable(T)` are defined.

The `HTTP.Response` struct contains:

 - `status::Int16` e.g. `200`
 - `headers::Vector{Pair{String,String}}`
    e.g. ["Server" => "Apache", "Content-Type" => "text/html"]
 - `body::Vector{UInt8}`, the Response Body bytes
    (empty if a `response_stream` was specified in the `request`).

Functions `HTTP.get`, `HTTP.put`, `HTTP.post` and `HTTP.head` are defined as
shorthand for `HTTP.request("GET", ...)`, etc.

`HTTP.request` and `HTTP.open` also accept optional keyword parameters.

e.g.
```julia
HTTP.request("GET", "http://httpbin.org/ip"; retries=4, cookies=true)

HTTP.get("http://s3.us-east-1.amazonaws.com/"; aws_authorization=true)

conf = (readtimeout = 10,
        pipeline_limit = 4,
        retry = false,
        redirect = false)

HTTP.get("http://httpbin.org/ip"; conf..)
HTTP.put("http://httpbin.org/put", [], "Hello"; conf..)
```


URL options

 - `query = nothing`, replaces the query part of `url`.

Streaming options

 - `response_stream = nothing`, a writeable `IO` stream or any `IO`-like
    type `T` for which `write(T, AbstractVector{UInt8})` is defined.
 - `verbose = 0`, set to `1` or `2` for extra message logging.


Connection Pool options

 - `connection_limit = 8`, number of concurrent connections to each host:port.
 - `pipeline_limit = 16`, number of concurrent requests per connection.
 - `reuse_limit = nolimit`, number of times a connection is reused after the
                            first request.
 - `socket_type = TCPSocket`


Timeout options

 - `readtimeout = 60`, close the connection if no data is received for this many
   seconds. Use `readtimeout = 0` to disable.


Retry options

 - `retry = true`, retry idempotent requests in case of error.
 - `retries = 4`, number of times to retry.
 - `retry_non_idempotent = false`, retry non-idempotent requests too. e.g. POST.


Redirect options

 - `redirect = true`, follow 3xx redirect responses.
 - `redirect_limit = 3`, number of times to redirect.
 - `forwardheaders = true`, forward original headers on redirect.


Status Exception options

 - `status_exception = true`, throw `HTTP.StatusError` for response status >= 300.


SSLContext options

 - `require_ssl_verification = false`, pass `MBEDTLS_SSL_VERIFY_REQUIRED` to
   the mbed TLS library.
   ["... peer must present a valid certificate, handshake is aborted if
     verification failed."](https://tls.mbed.org/api/ssl_8h.html#a5695285c9dbfefec295012b566290f37)
 - `sslconfig = SSLConfig(require_ssl_verification)`


Basic Authentication options

 - Basic authentication is detected automatically from the provided url's `userinfo` (in the form `scheme://user:password@host`)
   and adds the `Authorization: Basic` header


AWS Authentication options

 - `aws_authorization = false`, enable AWS4 Authentication.
 - `aws_service = split(url.host, ".")[1]`
 - `aws_region = split(url.host, ".")[2]`
 - `aws_access_key_id = ENV["AWS_ACCESS_KEY_ID"]`
 - `aws_secret_access_key = ENV["AWS_SECRET_ACCESS_KEY"]`
 - `aws_session_token = get(ENV, "AWS_SESSION_TOKEN", "")`
 - `body_sha256 = digest(MD_SHA256, body)`,
 - `body_md5 = digest(MD_MD5, body)`,


Cookie options

 - `cookies::Union{Bool, Dict{String, String}} = false`, enable cookies, or alternatively,
        pass a `Dict{String, String}` of name-value pairs to manually pass cookies
 - `cookiejar::Dict{String, Set{Cookie}}=default_cookiejar`,


Canonicalization options

 - `canonicalize_headers = false`, rewrite request and response headers in
   Canonical-Camel-Dash-Format.

Proxy options

 - `proxy = proxyurl`, pass request through a proxy given as a url

Alternatively, HTTP.jl also respects the `http_proxy`, `https_proxy`, and `no_proxy`
environment variables; if set, they will be used automatically when making requests.

## Request Body Examples

String body:
```julia
HTTP.request("POST", "http://httpbin.org/post", [], "post body data")
```

Stream body from file:
```julia
io = open("post_data.txt", "r")
HTTP.request("POST", "http://httpbin.org/post", [], io)
```

Generator body:
```julia
chunks = ("chunk\$i" for i in 1:1000)
HTTP.request("POST", "http://httpbin.org/post", [], chunks)
```

Collection body:
```julia
chunks = [preamble_chunk, data_chunk, checksum(data_chunk)]
HTTP.request("POST", "http://httpbin.org/post", [], chunks)
```

`open() do io` body:
```julia
HTTP.open("POST", "http://httpbin.org/post") do io
    write(io, preamble_chunk)
    write(io, data_chunk)
    write(io, checksum(data_chunk))
end
```


## Response Body Examples

String body:
```julia
r = HTTP.request("GET", "http://httpbin.org/get")
println(String(r.body))
```

Stream body to file:
```julia
io = open("get_data.txt", "w")
r = HTTP.request("GET", "http://httpbin.org/get", response_stream=io)
close(io)
println(read("get_data.txt"))
```

Stream body through buffer:
```julia
io = Base.BufferStream()
@async while !eof(io)
    bytes = readavailable(io))
    println("GET data: \$bytes")
end
r = HTTP.request("GET", "http://httpbin.org/get", response_stream=io)
close(io)
```

Stream body through `open() do io`:
```julia
r = HTTP.open("GET", "http://httpbin.org/stream/10") do io
   while !eof(io)
       println(String(readavailable(io)))
   end
end

using HTTP.IOExtras

HTTP.open("GET", "https://tinyurl.com/bach-cello-suite-1-ogg") do http
    n = 0
    r = startread(http)
    l = parse(Int, header(r, "Content-Length"))
    open(`vlc -q --play-and-exit --intf dummy -`, "w") do vlc
        while !eof(http)
            bytes = readavailable(http)
            write(vlc, bytes)
            n += length(bytes)
            println("streamed \$n-bytes \$((100*n)÷l)%\\u1b[1A")
        end
    end
end
```


## Request and Response Body Examples

String bodies:
```julia
r = HTTP.request("POST", "http://httpbin.org/post", [], "post body data")
println(String(r.body))
```

Interfacing with RESTful JSON APIs:
```julia
using JSON
params = Dict("user"=>"RAO...tjN", "token"=>"NzU...Wnp", "message"=>"Hello!")
base_url = "http://api.domain.com"
endpoint = "/1/messages.json"
url = base_url * endpoint
r = HTTP.request("POST", url,
             ["Content-Type" => "application/json"],
             JSON.json(params))
println(JSON.parse(String(r.body)))
```

Stream bodies from and to files:
```julia
in = open("foo.png", "r")
out = open("foo.jpg", "w")
HTTP.request("POST", "http://convert.com/png2jpg", [], in, response_stream=out)
```

Stream bodies through: `open() do io`:
```julia
using HTTP.IOExtras

HTTP.open("POST", "http://music.com/play") do io
    write(io, JSON.json([
        "auth" => "12345XXXX",
        "song_id" => 7,
    ]))
    r = startread(io)
    @show r.status
    while !eof(io)
        bytes = readavailable(io))
        play_audio(bytes)
    end
end
```
"""
function request(method, url, h=Header[], b=nobody;
                 headers=h, body=b, query=nothing, kw...)::Response
    return request(HTTP.stack(;kw...), string(method), request_uri(url, query), mkheaders(headers), body; kw...)
end
function request(stack::Type{<:Layer}, method, url, h=Header[], b=nobody;
                 headers=h, body=b, query=nothing, kw...)::Response
    return request(stack, string(method), request_uri(url, query), mkheaders(headers), body; kw...)
end

request(::Type{Union{}}, resp::Response) = resp
request(a...; kw...)::Response = request(HTTP.stack(; kw...), a...; kw...)

request_uri(url, query) = merge(URI(url); query=query)
request_uri(url, ::Nothing) = URI(url)

"""
    HTTP.open(method, url, [,headers]) do io
        write(io, body)
        [startread(io) -> HTTP.Response]
        while !eof(io)
            readavailable(io) -> AbstractVector{UInt8}
        end
    end -> HTTP.Response

The `HTTP.open` API allows the Request Body to be written to (and/or the
Response Body to be read from) an `IO` stream.


e.g. Streaming an audio file to the `vlc` player:
```julia
HTTP.open(:GET, "https://tinyurl.com/bach-cello-suite-1-ogg") do http
    open(`vlc -q --play-and-exit --intf dummy -`, "w") do vlc
        write(vlc, http)
    end
end
```
"""
open(f::Function, method::Union{String,Symbol}, url, headers=Header[]; kw...)::Response =
    request(string(method), url, headers, nothing; iofunction=f, kw...)

"""
    HTTP.openraw(method, url, [, headers])::Tuple{TCPSocket, Response, ByteView}

Open a raw socket that is unmanaged by HTTP.jl. Useful for doing HTTP upgrades
to other protocols.  Any bytes of the body read from the socket when reading
headers, is returned as excess bytes in the last tuple argument.

Example of a WebSocket upgrade:
```julia
headers = Dict(
    "Upgrade" => "websocket",
    "Connection" => "Upgrade",
    "Sec-WebSocket-Key" => "dGhlIHNhbXBsZSBub25jZQ==",
    "Sec-WebSocket-Version" => "13")

socket, response, excess = HTTP.openraw("GET", "ws://echo.websocket.org", headers)

# Write a WebSocket frame
frame = UInt8[0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]
write(socket, frame)
```
"""
function openraw(method::Union{String,Symbol}, url, headers=Header[]; kw...)::Tuple{IO, Response}
    socketready = Channel{Tuple{IO, Response}}(0)
    @async HTTP.open(method, url, headers; kw...) do http
        HTTP.startread(http)
        socket = http.stream
        put!(socketready, (socket, http.message))
        while(isopen(socket))
            Base.wait_close(socket)
        end
    end
    take!(socketready)
end

"""
    HTTP.get(url [, headers]; <keyword arguments>) -> HTTP.Response

Shorthand for `HTTP.request("GET", ...)`. See [`HTTP.request`](@ref).
"""
get(a...; kw...) = request("GET", a...; kw...)

"""
    HTTP.put(url, headers, body; <keyword arguments>) -> HTTP.Response

Shorthand for `HTTP.request("PUT", ...)`. See [`HTTP.request`](@ref).
"""
put(u, h=[], b=""; kw...) = request("PUT", u, h, b; kw...)

"""
    HTTP.post(url, headers, body; <keyword arguments>) -> HTTP.Response

Shorthand for `HTTP.request("POST", ...)`. See [`HTTP.request`](@ref).
"""
post(u, h=[], b=""; kw...) = request("POST", u, h, b; kw...)

"""
    HTTP.patch(url, headers, body; <keyword arguments>) -> HTTP.Response

Shorthand for `HTTP.request("PATCH", ...)`. See [`HTTP.request`](@ref).
"""
patch(u, h=[], b=""; kw...) = request("PATCH", u, h, b; kw...)

"""
    HTTP.head(url; <keyword arguments>) -> HTTP.Response

Shorthand for `HTTP.request("HEAD", ...)`. See [`HTTP.request`](@ref).
"""
head(u; kw...) = request("HEAD", u; kw...)

"""
    HTTP.delete(url [, headers]; <keyword arguments>) -> HTTP.Response

Shorthand for `HTTP.request("DELETE", ...)`. See [`HTTP.request`](@ref).
"""
delete(a...; kw...) = request("DELETE", a...; kw...)

include("RedirectRequest.jl");          using .RedirectRequest
include("BasicAuthRequest.jl");         using .BasicAuthRequest
include("AWS4AuthRequest.jl");          using .AWS4AuthRequest
include("CookieRequest.jl");            using .CookieRequest
include("CanonicalizeRequest.jl");      using .CanonicalizeRequest
include("TimeoutRequest.jl");           using .TimeoutRequest
include("MessageRequest.jl");           using .MessageRequest
include("ExceptionRequest.jl");         using .ExceptionRequest
                                        import .ExceptionRequest.StatusError
include("RetryRequest.jl");             using .RetryRequest
include("ConnectionRequest.jl");        using .ConnectionRequest
include("DebugRequest.jl");             using .DebugRequest
include("StreamRequest.jl");            using .StreamRequest
include("ContentTypeRequest.jl");       using .ContentTypeDetection
include("exceptions.jl")

"""
The `stack()` function returns the default HTTP Layer-stack type.
This type is passed as the first parameter to the [`HTTP.request`](@ref) function.

`stack()` accepts optional keyword arguments to enable/disable specific layers
in the stack:
`request(method, args...; kw...) request(stack(; kw...), args...; kw...)`


The minimal request execution stack is:

```julia
stack = MessageLayer{ConnectionPoolLayer{StreamLayer}}
```

The figure below illustrates the full request execution stack and its
relationship with [`HTTP.Response`](@ref), [`HTTP.Parsers`](@ref),
[`HTTP.Stream`](@ref) and the [`HTTP.ConnectionPool`](@ref).

```
 ┌────────────────────────────────────────────────────────────────────────────┐
 │                                            ┌───────────────────┐           │
 │  HTTP.jl Request Execution Stack           │ HTTP.ParsingError ├ ─ ─ ─ ─ ┐ │
 │                                            └───────────────────┘           │
 │                                            ┌───────────────────┐         │ │
 │                                            │ HTTP.IOError      ├ ─ ─ ─     │
 │                                            └───────────────────┘      │  │ │
 │                                            ┌───────────────────┐           │
 │                                            │ HTTP.StatusError  │─ ─   │  │ │
 │                                            └───────────────────┘   │       │
 │                                            ┌───────────────────┐      │  │ │
 │     request(method, url, headers, body) -> │ HTTP.Response     │   │       │
 │             ──────────────────────────     └─────────▲─────────┘      │  │ │
 │                           ║                          ║             │       │
 │   ┌────────────────────────────────────────────────────────────┐      │  │ │
 │   │ request(RedirectLayer,     method, ::URI, ::Headers, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(BasicAuthLayer,    method, ::URI, ::Headers, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(CookieLayer,       method, ::URI, ::Headers, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(CanonicalizeLayer, method, ::URI, ::Headers, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(MessageLayer,      method, ::URI, ::Headers, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(AWS4AuthLayer,             ::URI, ::Request, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(RetryLayer,                ::URI, ::Request, body) │   │       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
 │   │ request(ExceptionLayer,            ::URI, ::Request, body) ├ ─ ┘       │
 │   ├────────────────────────────────────────────────────────────┤      │  │ │
┌┼───┤ request(ConnectionPoolLayer,       ::URI, ::Request, body) ├ ─ ─ ─     │
││   ├────────────────────────────────────────────────────────────┤         │ │
││   │ request(DebugLayer,                ::IO,  ::Request, body) │           │
││   ├────────────────────────────────────────────────────────────┤         │ │
││   │ request(TimeoutLayer,              ::IO,  ::Request, body) │           │
││   ├────────────────────────────────────────────────────────────┤         │ │
││   │ request(StreamLayer,               ::IO,  ::Request, body) │           │
││   └──────────────┬───────────────────┬─────────────────────────┘         │ │
│└──────────────────┼────────║──────────┼───────────────║─────────────────────┘
│                   │        ║          │               ║                   │
│┌──────────────────▼───────────────┐   │  ┌──────────────────────────────────┐
││ HTTP.Request                     │   │  │ HTTP.Response                  │ │
││                                  │   │  │                                  │
││ method::String                   ◀───┼──▶ status::Int                    │ │
││ target::String                   │   │  │ headers::Vector{Pair}            │
││ headers::Vector{Pair}            │   │  │ body::Vector{UInt8}            │ │
││ body::Vector{UInt8}              │   │  │                                  │
│└──────────────────▲───────────────┘   │  └───────────────▲────────────────┼─┘
│┌──────────────────┴────────║──────────▼───────────────║──┴──────────────────┐
││ HTTP.Stream <:IO          ║           ╔══════╗       ║                   │ │
││   ┌───────────────────────────┐       ║   ┌──▼─────────────────────────┐   │
││   │ startwrite(::Stream)      │       ║   │ startread(::Stream)        │ │ │
││   │ write(::Stream, body)     │       ║   │ read(::Stream) -> body     │   │
││   │ ...                       │       ║   │ ...                        │ │ │
││   │ closewrite(::Stream)      │       ║   │ closeread(::Stream)        │   │
││   └───────────────────────────┘       ║   └────────────────────────────┘ │ │
│└───────────────────────────║────────┬──║──────║───────║──┬──────────────────┘
│┌──────────────────────────────────┐ │  ║ ┌────▼───────║──▼────────────────┴─┐
││ HTTP.Messages                    │ │  ║ │ HTTP.Parsers                     │
││                                  │ │  ║ │                                  │
││ writestartline(::IO, ::Request)  │ │  ║ │ parse_status_line(bytes, ::Req') │
││ writeheaders(::IO, ::Request)    │ │  ║ │ parse_header_field(bytes, ::Req')│
│└──────────────────────────────────┘ │  ║ └──────────────────────────────────┘
│                            ║        │  ║
│┌───────────────────────────║────────┼──║────────────────────────────────────┐
└▶ HTTP.ConnectionPool       ║        │  ║                                    │
 │                     ┌──────────────▼────────┐ ┌───────────────────────┐    │
 │ getconnection() ->  │ HTTP.Transaction <:IO │ │ HTTP.Transaction <:IO │    │
 │                     └───────────────────────┘ └───────────────────────┘    │
 │                           ║    ╲│╱    ║                  ╲│╱               │
 │                           ║     │     ║                   │                │
 │                     ┌───────────▼───────────┐ ┌───────────▼───────────┐    │
 │              pool: [│ HTTP.Connection       │,│ HTTP.Connection       │...]│
 │                     └───────────┬───────────┘ └───────────┬───────────┘    │
 │                           ║     │     ║                   │                │
 │                     ┌───────────▼───────────┐ ┌───────────▼───────────┐    │
 │                     │ Base.TCPSocket <:IO   │ │MbedTLS.SSLContext <:IO│    │
 │                     └───────────────────────┘ └───────────┬───────────┘    │
 │                           ║           ║                   │                │
 │                           ║           ║       ┌───────────▼───────────┐    │
 │                           ║           ║       │ Base.TCPSocket <:IO   │    │
 │                           ║           ║       └───────────────────────┘    │
 └───────────────────────────║───────────║────────────────────────────────────┘
                             ║           ║
 ┌───────────────────────────║───────────║──────────────┐  ┏━━━━━━━━━━━━━━━━━━┓
 │ HTTP Server               ▼                          │  ┃ data flow: ════▶ ┃
 │                        Request     Response          │  ┃ reference: ────▶ ┃
 └──────────────────────────────────────────────────────┘  ┗━━━━━━━━━━━━━━━━━━┛
```
*See `docs/src/layers`[`.monopic`](http://monodraw.helftone.com).*
"""
function stack(;redirect=true,
                aws_authorization=false,
                cookies=false,
                canonicalize_headers=false,
                retry=true,
                status_exception=true,
                readtimeout=0,
                detect_content_type=false,
                verbose=0,
                kw...)

    NoLayer = Union

    (redirect             ? RedirectLayer             : NoLayer){
                            BasicAuthLayer{
    (detect_content_type  ? ContentTypeDetectionLayer : NoLayer){
    (cookies === true || (cookies isa AbstractDict && !isempty(cookies)) ?
                            CookieLayer               : NoLayer){
    (canonicalize_headers ? CanonicalizeLayer         : NoLayer){
                            MessageLayer{
    (aws_authorization    ? AWS4AuthLayer             : NoLayer){
    (retry                ? RetryLayer                : NoLayer){
    (status_exception     ? ExceptionLayer            : NoLayer){
                            ConnectionPoolLayer{
    (verbose >= 3 ||
     DEBUG_LEVEL[] >= 3   ? DebugLayer                : NoLayer){
    (readtimeout > 0      ? TimeoutLayer              : NoLayer){
                            StreamLayer{Union{}}
    }}}}}}}}}}}}
end

include("download.jl")
include("Servers.jl")                  ;using .Servers; using .Servers: listen
include("Handlers.jl")                 ;using .Handlers; using .Handlers: serve
include("parsemultipart.jl")
include("WebSockets.jl")               ;using .WebSockets

import .ConnectionPool: Transaction, Connection

function Base.parse(::Type{T}, str::AbstractString)::T where T <: Message
    buffer = Base.BufferStream()
    write(buffer, str)
    close(buffer)
    m = T()
    http = Stream(m, Transaction(Connection(buffer)))
    m.body = read(http)
    closeread(http)
    return m
end

end # module
