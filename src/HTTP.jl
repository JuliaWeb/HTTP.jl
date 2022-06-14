module HTTP

export startwrite, startread, closewrite, closeread,
    @logfmt_str, common_logfmt, combined_logfmt, WebSockets

const DEBUG_LEVEL = Ref(0)

Base.@deprecate escape escapeuri

using Base64, Sockets, Dates, URIs, LoggingExtras

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

function open end

include("Conditions.jl")               ;using .Conditions
include("access_log.jl")

include("Pairs.jl")                    ;using .Pairs
include("IOExtras.jl")                 ;using .IOExtras
include("Strings.jl")                  ;using .Strings
include("Exceptions.jl")               ;using .Exceptions
include("sniff.jl")                    ;using .Sniff
include("multipart.jl")                ;using .Forms
include("Parsers.jl")                  ;import .Parsers: Headers, Header,
                                                         ParseError
include("ConnectionPool.jl")           ;using .ConnectionPool
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
r = HTTP.get("http://httpbin.org/ip") # equivalent shortcut
println(r.status)
println(String(r.body))
```

`headers` can be any collection where
`[string(k) => string(v) for (k,v) in headers]` yields `Vector{Pair}`.
e.g. a `Dict()`, a `Vector{Tuple}`, a `Vector{Pair}` or an iterator.
By convention, if a header _value_ is an empty string, it will not be written
when sending a request (following the curl convention).

`body` can be a variety of objects:

 - a `String`, a `Vector{UInt8}` or any `T` accepted by `write(::IO, ::T)`
 - a collection of `String` or `AbstractVector{UInt8}` or `IO` streams
   or items of any type `T` accepted by `write(::IO, ::T...)`
 - a readable `IO` stream or any `IO`-like type `T` for which
   `eof(T)` and `readavailable(T)` are defined.

The `HTTP.Response` struct contains:

 - `status::Int16` e.g. `200`
 - `headers::Vector{Pair{String,String}}`
    e.g. ["Server" => "Apache", "Content-Type" => "text/html"]
 - `body::Vector{UInt8}` or `::IO`, the Response Body bytes or the `io` argument
    provided via the `response_stream` keyword argument

Functions `HTTP.get`, `HTTP.put`, `HTTP.post` and `HTTP.head` are defined as
shorthand for `HTTP.request("GET", ...)`, etc.

Supported optional keyword arguments:

 - `query = nothing`, a `Pair` or `Dict` of key => values to be included in the url
 - `response_stream = nothing`, a writeable `IO` stream or any `IO`-like
    type `T` for which `write(T, AbstractVector{UInt8})` is defined. The response body
    will be written to this stream instead of returned as a `Vector{UInt8}`.
 - `verbose = 0`, set to `1` or `2` for increasingly verbose logging of the
    request and response process
 - `connect_timeout = 0`, close the connection after this many seconds if it
   is still attempting to connect. Use `connect_timeout = 0` to disable.
 - `connection_limit = 8`, number of concurrent connections allowed to each host:port.
 - `readtimeout = 0`, close the connection if no data is received for this many
   seconds. Use `readtimeout = 0` to disable.
 - `status_exception = true`, throw `HTTP.StatusError` for response status >= 300.
 - Basic authentication is detected automatically from the provided url's `userinfo` (in the form `scheme://user:password@host`)
   and adds the `Authorization: Basic` header; this can be disabled by passing `basicauth=false`
 - `canonicalize_headers = false`, rewrite request and response headers in
   Canonical-Camel-Dash-Format.
 - `proxy = proxyurl`, pass request through a proxy given as a url; alternatively, the `http_proxy`, `HTTP_PROXY`, `https_proxy`, `HTTPS_PROXY`, and `no_proxy`
   environment variables are also detected/used; if set, they will be used automatically when making requests.
 - `detect_content_type = false`: if `true` and the request body is not a form or `IO`, it will be
    inspected and the "Content-Type" header will be set to the detected content type.
 - `decompress = true`, if `true`, decompress the response body if the response has a
    "Content-Encoding" header set to "gzip".

Retry arguments:
 - `retry = true`, retry idempotent requests in case of error.
 - `retries = 4`, number of times to retry.
 - `retry_non_idempotent = false`, retry non-idempotent requests too. e.g. POST.

Redirect arguments:
 - `redirect = true`, follow 3xx redirect responses; i.e. additional requests will be made to the redirected location
 - `redirect_limit = 3`, maximum number of times a redirect will be followed
 - `redirect_method = nothing`, the method to use for the redirected request; by default,
    GET will be used, only responses with 307/308 will use the same original request method.
    Pass `redirect_method=:same` to pass the same method as the orginal request though note that some servers
    may not respond/accept the same method. It's also valid to pass the exact method to use
    as a string, like `redirect_method="PUT"`.
 - `forwardheaders = true`, forward original headers on redirect.

SSL arguments:
 - `require_ssl_verification = NetworkOptions.verify_host(host)`, pass `MBEDTLS_SSL_VERIFY_REQUIRED` to
   the mbed TLS library.
   ["... peer must present a valid certificate, handshake is aborted if
     verification failed."](https://tls.mbed.org/api/ssl_8h.html#a5695285c9dbfefec295012b566290f37)
 - `sslconfig = SSLConfig(require_ssl_verification)`

Cookie arguments:
 - `cookies::Union{Bool, Dict{<:AbstractString, <:AbstractString}} = true`, enable cookies, or alternatively,
        pass a `Dict{AbstractString, AbstractString}` of name-value pairs to manually pass cookies in the request "Cookie" header
 - `cookiejar::HTTP.CookieJar=HTTP.COOKIEJAR`: threadsafe cookie jar struct for keeping track of cookies per host;
    a global cookie jar is used by default.

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
r = HTTP.get("http://httpbin.org/get", response_stream=IOBuffer())
println(String(take!(r.body)))
```

Stream body through `open() do io`:
```julia
r = HTTP.open("GET", "http://httpbin.org/stream/10") do io
   while !eof(io)
       println(String(readavailable(io)))
   end
end

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

Interfacing with RESTful JSON APIs:
```julia
using JSON
params = Dict("user"=>"RAO...tjN", "token"=>"NzU...Wnp", "message"=>"Hello!")
url = "http://api.domain.com/1/messages.json"
r = HTTP.post(url, body=JSON.json(params))
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

const STREAM_LAYERS = [timeoutlayer, exceptionlayer]
const REQUEST_LAYERS = [redirectlayer, defaultheaderslayer, basicauthlayer, contenttypedetectionlayer, cookielayer, retrylayer, canonicalizelayer]

"""
    Layer

Abstract type to represent a client-side middleware that exists for documentation purposes.
A layer is any function of the form `f(::Handler) -> Handler`, where [`Handler`](@ref) is
a function of the form `f(::Request) -> Response`. Note that the `Handler` definition is from
the server-side documentation, and is "hard-coded" on the client side. It may also be apparent
that a `Layer` is the same as the [`Middleware`](@ref) interface from server-side, which is true, but
we define `Layer` to clarify the client-side distinction and its unique usage. Custom layers can be
deployed in one of two ways:
  * [`HTTP.@client`](@ref): Create a custom "client" with shorthand verb definitions, but which
    include custom layers; only these new verb methods will use the custom layers.
  * [`HTTP.pushlayer!`](@ref)/[`HTTP.poplayer!`](@ref): Allows globally adding and removing
    layers from the default HTTP.jl layer stack; *all* http requests will then use the custom layers

### Quick Examples
```julia
module Auth

using HTTP

function auth_layer(handler)
    # returns a `Handler` function; check for a custom keyword arg `authcreds` that
    # a user would pass like `HTTP.get(...; authcreds=creds)`.
    # We also accept trailing keyword args `kw...` and pass them along later.
    return function(req; authcreds=nothing, kw...)
        # only apply the auth layer if the user passed `authcreds`
        if authcreds !== nothing
            # we add a custom header with stringified auth creds
            HTTP.setheader(req, "X-Auth-Creds" => string(authcreds))
        end
        # pass the request along to the next layer by calling `auth_layer` arg `handler`
        # also pass along the trailing keyword args `kw...`
        return handler(req; kw...)
    end
end

# Create a new client with the auth layer added
HTTP.@client [auth_layer]

end # module

# Can now use custom client like:
Auth.get(url; authcreds=creds) # performs GET request with auth_layer layer included

# Or can include layer globally in all HTTP.jl requests
HTTP.pushlayer!(Auth.auth_layer)

# Now can use normal HTTP.jl methods and auth_layer will be included
HTTP.get(url; authcreds=creds)
```
"""
abstract type Layer end

"""
    HTTP.pushlayer!(layer; request=true)

Push a layer onto the stack of layers that will be applied to all requests.
The "layer" is expected to be a function that takes and returns a `Handler` function.
See [`Layer`](@ref) for more details.
If `request=false`, the layer is expected to take and return a "stream" handler function.
The custom `layer` will be put on the top of the stack, so it will be the first layer
executed. To add a layer at the bottom of the stack, see [`HTTP.pushfirstlayer!`](@ref).
"""
pushlayer!(layer; request::Bool=true) = push!(request ? REQUEST_LAYERS : STREAM_LAYERS, layer)

"""
    HTTP.pushfirstlayer!(layer; request=true)

Push a layer to the start of the stack of layers that will be applied to all requests.
The "layer" is expected to be a function that takes and returns a `Handler` function.
See [`Layer`](@ref) for more details.
If `request=false`, the layer is expected to take and return a "stream" handler function.
The custom `layer` will be put on the bottom of the stack, so it will be the last layer
executed. To add a layer at the top of the stack, see [`HTTP.pushlayer!`](@ref).
"""
pushfirstlayer!(layer; request::Bool=true) = pushfirst!(request ? REQUEST_LAYERS : STREAM_LAYERS, layer)

"""
    HTTP.poplayer!(layer; request=true)

Inverse of [`HTTP.pushlayer!`](@ref), removes the top layer of the global HTTP.jl layer stack.
Can be used to "cleanup" after a custom layer has been added.
If `request=false`, will remove the top "stream" layer as opposed to top "request" layer.
"""
poplayer!(; request::Bool=true) = pop!(request ? REQUEST_LAYERS : STREAM_LAYERS)

"""
    HTTP.popfirstlayer!(layer; request=true)

Inverse of [`HTTP.pushfirstlayer!`](@ref), removes the bottom layer of the global HTTP.jl layer stack.
Can be used to "cleanup" after a custom layer has been added.
If `request=false`, will remove the bottom "stream" layer as opposed to bottom "request" layer.
"""
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
    # we also want debuglayer to be early to ensure any debug logging is handled correctly in other layers
    layers3 = foldr((x, y) -> x(y), requestlayers; init=connectionlayer(layers2))
    return messagelayer(debuglayer(foldr((x, y) -> x(y), REQUEST_LAYERS; init=layers3)))
end

function request(stack::Base.Callable, method, url, h=Header[], b=nobody, q=nothing;
                 headers=h, body=b, query=q, kw...)::Response
    return stack(string(method), request_uri(url, query), mkheaders(headers), body; kw...)
end

"""
    HTTP.@client [requestlayers]
    HTTP.@client [requestlayers] [streamlayers]

Convenience macro for creating a custom HTTP.jl client that will include custom layers when
performing requests. It's common to want to define a custom [`Layer`](@ref) to enhance a
specific category of requests, such as custom authentcation for a web API. Instead of affecting
the global HTTP.jl request stack via [`HTTP.pushlayer!`](@ref), a custom wrapper client can be
defined with convenient shorthand methods. See [`Layer`](@ref) for an example of defining a custom
layer and creating a new client that includes the layer.
"""
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

The `HTTP.open` API allows the request body to be written to (and/or the
response body to be read from) an `IO` stream.

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
