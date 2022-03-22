module HTTP

export startwrite, startread, closewrite, closeread,
    @logfmt_str, common_logfmt, combined_logfmt

const DEBUG_LEVEL = Ref(0)

Base.@deprecate escape escapeuri

using Base64, Sockets, Dates
using URIs

function access_threaded(f, v::Vector)
    tid = Threads.threadid()
    0 < tid <= length(v) || _length_assert()
    if @inbounds isassigned(v, tid)
        @inbounds x = v[tid]
    else
        x = f()
        @inbounds v[tid] = x
    end
    return x
end
@noinline _length_assert() =  @assert false "0 < tid <= v"

include("debug.jl")
include("access_log.jl")

include("Pairs.jl")                    ;using .Pairs
include("IOExtras.jl")                 ;using .IOExtras
include("Strings.jl")
include("sniff.jl")
include("multipart.jl")
include("Parsers.jl")                  ;import .Parsers: Headers, Header,
                                                         ParseError
include("ConnectionPool.jl")
include("Messages.jl")                 ;using .Messages
include("cookies.jl")                  ;using .Cookies
include("Streams.jl")                  ;using .Streams
include("MessageRequest.jl");           using .MessageRequest
include("RedirectRequest.jl");          using .RedirectRequest
include("DefaultHeadersRequest.jl");    using .DefaultHeadersRequest
include("BasicAuthRequest.jl");         using .BasicAuthRequest
include("CookieRequest.jl");            using .CookieRequest
include("CanonicalizeRequest.jl");      using .CanonicalizeRequest
include("TimeoutRequest.jl");           using .TimeoutRequest
include("ExceptionRequest.jl");         using .ExceptionRequest
                                        import .ExceptionRequest.StatusError
include("RetryRequest.jl");             using .RetryRequest
include("ConnectionRequest.jl");        using .ConnectionRequest
include("DebugRequest.jl");             using .DebugRequest
include("StreamRequest.jl");            using .StreamRequest
include("ContentTypeRequest.jl");       using .ContentTypeDetection

include("download.jl")
include("Servers.jl")                  ;using .Servers; using .Servers: listen
include("Handlers.jl")                 ;using .Handlers; using .Handlers: serve
include("parsemultipart.jl")           ;using .MultiPartParsing: parse_multipart_form
include("WebSockets.jl")               ;using .WebSockets

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

HTTP.get("http://s3.us-east-1.amazonaws.com/")

conf = (readtimeout = 10,
        retry = false,
        redirect = false)

HTTP.get("http://httpbin.org/ip"; conf...)
HTTP.put("http://httpbin.org/put", [], "Hello"; conf...)
```


URL options

 - `query = nothing`, replaces the query part of `url`.

Streaming options

 - `response_stream = nothing`, a writeable `IO` stream or any `IO`-like
    type `T` for which `write(T, AbstractVector{UInt8})` is defined.
 - `verbose = 0`, set to `1` or `2` for extra message logging.


Connection Pool options

 - `connect_timeout = 0`, close the connection after this many seconds if it
   is still attempting to connect. Use `connect_timeout = 0` to disable.
 - `connection_limit = 8`, number of concurrent connections to each host:port.
 - `socket_type = TCPSocket`


Timeout options

 - `readtimeout = 0`, close the connection if no data is received for this many
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

 - `require_ssl_verification = NetworkOptions.verify_host(host)`, pass `MBEDTLS_SSL_VERIFY_REQUIRED` to
   the mbed TLS library.
   ["... peer must present a valid certificate, handshake is aborted if
     verification failed."](https://tls.mbed.org/api/ssl_8h.html#a5695285c9dbfefec295012b566290f37)
 - `sslconfig = SSLConfig(require_ssl_verification)`


Basic Authentication options

 - Basic authentication is detected automatically from the provided url's `userinfo` (in the form `scheme://user:password@host`)
   and adds the `Authorization: Basic` header; this can be disabled by passing `basicauth=false`


Cookie options

 - `cookies::Union{Bool, Dict{<:AbstractString, <:AbstractString}} = false`, enable cookies, or alternatively,
        pass a `Dict{AbstractString, AbstractString}` of name-value pairs to manually pass cookies
 - `cookiejar::Dict{String, Set{Cookie}}=default_cookiejar`,


Canonicalization options

 - `canonicalize_headers = false`, rewrite request and response headers in
   Canonical-Camel-Dash-Format.

Proxy options

 - `proxy = proxyurl`, pass request through a proxy given as a url

Alternatively, HTTP.jl also respects the `http_proxy`, `HTTP_PROXY`, `https_proxy`, `HTTPS_PROXY`, and `no_proxy`
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
    bytes = readavailable(io)
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
    l = parse(Int, HTTP.header(r, "Content-Length"))
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
        bytes = readavailable(io)
        play_audio(bytes)
    end
end
```
"""
function request(method, url, h=Header[], b=nobody;
                 headers=h, body=b, query=nothing, kw...)::Response
    return request(HTTP.stack(), method, url, headers, body, query; kw...)
end

const STREAM_LAYERS = [timeoutlayer, exceptionlayer, debuglayer]
const REQUEST_LAYERS = [messagelayer, redirectlayer, defaultheaderslayer, basicauthlayer, contenttypedetectionlayer, cookielayer, retrylayer, canonicalizelayer]

pushlayer!(layer; request::Bool=true) = push!(request ? REQUEST_LAYERS : STREAM_LAYERS, layer)
pushfirstlayer!(layer; request::Bool=true) = pushfirst!(request ? REQUEST_LAYERS : STREAM_LAYERS, layer)
poplayer!(; request::Bool=true) = pop!(request ? REQUEST_LAYERS : STREAM_LAYERS)
popfirstlayer!(; request::Bool=true) = popfirst!(request ? REQUEST_LAYERS : STREAM_LAYERS)

function stack(
    # custom layers
    requestlayers=(),
    streamlayers=())

    # stream layers
    layers = foldr((x, y) -> x(y), streamlayers, init=streamlayer)
    layers2 = foldr((x, y) -> x(y), STREAM_LAYERS, init=layers)
    # request layers
    # messagelayer must be the 1st/outermost layer to convert initial args to Request
    layers3 = foldr((x, y) -> x(y), requestlayers; init=connectionlayer(layers2))
    return foldr((x, y) -> x(y), REQUEST_LAYERS; init=layers3)
end

function request(stack::Base.Callable, method, url, h=Header[], b=nobody, q=nothing;
                 headers=h, body=b, query=q, kw...)::Response
    return stack(string(method), request_uri(url, query), mkheaders(headers), body; kw...)
end

macro client(requestlayers, streamlayers=[])
    esc(quote
        get(a...; kw...) = request("GET", a...; kw...)
        put(a...; kw...) = request("PUT", a...; kw...)
        post(a...; kw...) = request("POST", a...; kw...)
        patch(a...; kw...) = request("PATCH", a...; kw...)
        head(u; kw...) = request("HEAD", u; kw...)
        delete(a...; kw...) = request("DELETE", a...; kw...)
        request(method, url, h=HTTP.Header[], b=HTTP.nobody; headers=h, body=b, query=nothing, kw...)::HTTP.Response =
            HTTP.request(HTTP.stack($requestlayers, $streamlayers), method, url, headers, body, query; kw...)
    end)
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
put(a...; kw...) = request("PUT", a...; kw...)

"""
    HTTP.post(url, headers, body; <keyword arguments>) -> HTTP.Response

Shorthand for `HTTP.request("POST", ...)`. See [`HTTP.request`](@ref).
"""
post(a...; kw...) = request("POST", a...; kw...)

"""
    HTTP.patch(url, headers, body; <keyword arguments>) -> HTTP.Response

Shorthand for `HTTP.request("PATCH", ...)`. See [`HTTP.request`](@ref).
"""
patch(a...; kw...) = request("PATCH", a...; kw...)

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

request_uri(url, query) = URI(URI(url); query=query)
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

import .ConnectionPool: Connection

function Base.parse(::Type{T}, str::AbstractString)::T where T <: Message
    buffer = Base.BufferStream()
    write(buffer, str)
    close(buffer)
    m = T()
    http = Stream(m, Connection(buffer))
    m.body = read(http)
    closeread(http)
    return m
end

end # module
