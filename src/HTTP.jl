module HTTP

export startwrite, startread, closewrite, closeread,
    @logfmt_str, common_logfmt, combined_logfmt, WebSockets

const DEBUG_LEVEL = Ref(0)

Base.@deprecate escape escapeuri

using Base64, Sockets, Dates, URIs, LoggingExtras, MbedTLS, OpenSSL

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

const SOCKET_TYPE_TLS = Ref{Any}(OpenSSL.SSLStream)

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
include("Connections.jl")              ;using .Connections
# backwards compat
const ConnectionPool = Connections
include("StatusCodes.jl")              ;using .StatusCodes
include("Messages.jl")                 ;using .Messages
include("cookies.jl")                  ;using .Cookies
include("Streams.jl")                  ;using .Streams

getrequest(r::Request) = r
getrequest(s::Stream) = s.message.request

# Wraps client-side "layer" to track the amount of time spent in it as a request is processed.
function observelayer(f)
    function observation(req_or_stream; kw...)
        req = getrequest(req_or_stream)
        nm = nameof(f)
        cntnm = Symbol(nm, "_count")
        durnm = Symbol(nm, "_duration_ms")
        start_time = time()
        req.context[cntnm] = Base.get(req.context, cntnm, 0) + 1
        try
            return f(req_or_stream; kw...)
        finally
            req.context[durnm] = Base.get(req.context, durnm, 0) + (time() - start_time) * 1000
            # @info "observed layer = $f, count = $(req.context[cntnm]), duration = $(req.context[durnm])"
        end
    end
end

include("clientlayers/MessageRequest.jl");           using .MessageRequest
include("clientlayers/RedirectRequest.jl");          using .RedirectRequest
include("clientlayers/HeadersRequest.jl");           using .HeadersRequest
include("clientlayers/CookieRequest.jl");            using .CookieRequest
include("clientlayers/TimeoutRequest.jl");           using .TimeoutRequest
include("clientlayers/ExceptionRequest.jl");         using .ExceptionRequest
include("clientlayers/RetryRequest.jl");             using .RetryRequest
include("clientlayers/ConnectionRequest.jl");        using .ConnectionRequest
include("clientlayers/StreamRequest.jl");            using .StreamRequest

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
when sending a request (following the curl convention). By default, a copy of
provided headers is made (since required headers are typically set during the request);
to avoid this copy and have HTTP.jl mutate the provided headers array, pass `copyheaders=false`
as an additional keyword argument to the request.

The `body` argument can be a variety of objects:

 - an `AbstractDict` or `NamedTuple` to be serialized as the "application/x-www-form-urlencoded" content type
 - any `AbstractString` or `AbstractVector{UInt8}` which will be sent "as is" for the request body
 - a readable `IO` stream or any `IO`-like type `T` for which
   `eof(T)` and `readavailable(T)` are defined. This stream will be read and sent until `eof` is `true`.
   This object should support the `mark`/`reset` methods if request retries are desired (if not, no retries will be attempted).
 - Any collection or iterable of the above (`AbstractDict`, `AbstractString`, `AbstractVector{UInt8}`, or `IO`)
   which will result in a "chunked" request body, where each iterated element will be sent as a separate chunk
 - a [`HTTP.Form`](@ref), which will be serialized as the "multipart/form-data" content-type

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
 - `connect_timeout = 30`, close the connection after this many seconds if it
   is still attempting to connect. Use `connect_timeout = 0` to disable.
 - `pool = nothing`, an `HTTP.Pool` object to use for managing the reuse of connections between requests.
    By default, a global pool is used, which is shared across all requests. To create a pool for a specific set of requests,
    use `pool = HTTP.Pool(max::Int)`, where `max` controls the maximum number of concurrent connections allowed to be used for requests at a given time.
 - `readtimeout = 0`, abort a request after this many seconds. Will trigger retries if applicable. Use `readtimeout = 0` to disable.
 - `status_exception = true`, throw `HTTP.StatusError` for response status >= 300.
 - Basic authentication is detected automatically from the provided url's `userinfo` (in the form `scheme://user:password@host`)
   and adds the `Authorization: Basic` header; this can be disabled by passing `basicauth=false`
 - `canonicalize_headers = false`, rewrite request and response headers in
   Canonical-Camel-Dash-Format.
 - `proxy = proxyurl`, pass request through a proxy given as a url; alternatively, the `http_proxy`, `HTTP_PROXY`, `https_proxy`, `HTTPS_PROXY`, and `no_proxy`
   environment variables are also detected/used; if set, they will be used automatically when making requests.
 - `detect_content_type = false`: if `true` and the request body is not a form or `IO`, it will be
    inspected and the "Content-Type" header will be set to the detected content type.
 - `decompress = nothing`, by default, decompress the response body if the response has a
    "Content-Encoding" header set to "gzip". If `decompress=true`, decompress the response body
    regardless of `Content-Encoding` header. If `decompress=false`, do not decompress the response body.
 - `logerrors = false`, if `true`, `HTTP.StatusError`, `HTTP.TimeoutError`, `HTTP.IOError`, and `HTTP.ConnectError` will be
    logged via `@error` as they happen, regardless of whether the request is then retried or not. Useful for debugging or
    monitoring requests where there's worry of certain errors happening but ignored because of retries.
 - `logtag = nothing`, if provided, will be used as the tag for error logging. Useful for debugging or monitoring requests.
 - `observelayers = false`, if `true`, enables the `HTTP.observelayer` to wrap each client-side "layer" to track the amount of
   time spent in each layer as a request is processed. This can be useful for debugging performance issues. Note that when retries
   or redirects happen, the time spent in each layer is cumulative, as noted by the `[layer]_count`. The metrics are stored
   in the `Request.context` dictionary, and can be accessed like `HTTP.get(...).request.context`

Retry arguments:
 - `retry = true`, retry idempotent requests in case of error.
 - `retries = 4`, number of times to retry.
 - `retry_non_idempotent = false`, retry non-idempotent requests too. e.g. POST.
 - `retry_delays = ExponentialBackOff(n = retries)`, provide a custom `ExponentialBackOff` object to control the delay between retries.
 - `retry_check = (s, ex, req, resp, resp_body) -> Bool`, provide a custom function to control whether a retry should be attempted.
    The function should accept 5 arguments: the delay state, exception, request, response (an `HTTP.Response` object *if* a request was
    successfully made, otherwise `nothing`), and `resp_body` response body (which may be `nothing` if there is no response yet, otherwise
    a `Vector{UInt8}`), and return `true` if a retry should be attempted.

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
 - `socket_type_tls = MbedTLS.SSLContext`, the type of socket to use for TLS connections. Defaults to `MbedTLS.SSLContext`.
    Also supported is passing `socket_type_tls = OpenSSL.SSLStream`. To change the global default, set `HTTP.SOCKET_TYPE_TLS[] = OpenSSL.SSLStream`.

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
function request(method, url, h=nothing, b=nobody;
                 headers=h, body=b, query=nothing, observelayers::Bool=false, kw...)::Response
    return request(HTTP.stack(observelayers), method, url, headers, body, query; kw...)
end

# layers are applied from left to right, i.e. the first layer is the outermost that is called first, which then calls into the second layer, etc.
const STREAM_LAYERS = [timeoutlayer, exceptionlayer]
const REQUEST_LAYERS = [redirectlayer, headerslayer, cookielayer, retrylayer]

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
    HTTP.poplayer!(; request=true)

Inverse of [`HTTP.pushlayer!`](@ref), removes the top layer of the global HTTP.jl layer stack.
Can be used to "cleanup" after a custom layer has been added.
If `request=false`, will remove the top "stream" layer as opposed to top "request" layer.
"""
poplayer!(; request::Bool=true) = pop!(request ? REQUEST_LAYERS : STREAM_LAYERS)

"""
    HTTP.popfirstlayer!(; request=true)

Inverse of [`HTTP.pushfirstlayer!`](@ref), removes the bottom layer of the global HTTP.jl layer stack.
Can be used to "cleanup" after a custom layer has been added.
If `request=false`, will remove the bottom "stream" layer as opposed to bottom "request" layer.
"""
popfirstlayer!(; request::Bool=true) = popfirst!(request ? REQUEST_LAYERS : STREAM_LAYERS)

function stack(
    observelayers::Bool=false,
    # custom layers
    requestlayers=(),
    streamlayers=())

    obs = observelayers ? observelayer : identity
    # stream layers
    if streamlayers isa NamedTuple
        inner_stream_layers = haskey(streamlayers, :last) ? streamlayers.last : ()
        outer_stream_layers = haskey(streamlayers, :first) ? streamlayers.first : ()
    else
        inner_stream_layers = streamlayers
        outer_stream_layers = ()
    end
    layers = foldr((x, y) -> obs(x(y)), inner_stream_layers, init=obs(streamlayer))
    layers2 = foldr((x, y) -> obs(x(y)), STREAM_LAYERS, init=layers)
    if !isempty(outer_stream_layers)
        layers2 = foldr((x, y) -> obs(x(y)), outer_stream_layers, init=layers2)
    end
    # request layers
    # messagelayer must be the 1st/outermost layer to convert initial args to Request
    if requestlayers isa NamedTuple
        inner_request_layers = haskey(requestlayers, :last) ? requestlayers.last : ()
        outer_request_layers = haskey(requestlayers, :first) ? requestlayers.first : ()
    else
        inner_request_layers = requestlayers
        outer_request_layers = ()
    end
    layers3 = foldr((x, y) -> obs(x(y)), inner_request_layers; init=obs(connectionlayer(layers2)))
    layers4 = foldr((x, y) -> obs(x(y)), REQUEST_LAYERS; init=layers3)
    if !isempty(outer_request_layers)
        layers4 = foldr((x, y) -> obs(x(y)), outer_request_layers, init=layers4)
    end
    return messagelayer(layers4)
end

function request(stack::Base.Callable, method, url, h=nothing, b=nobody, q=nothing;
                 headers=h, body=b, query=q, kw...)::Response
    return stack(string(method), request_uri(url, query), headers, body; kw...)
end

macro remove_linenums!(expr)
    return esc(Base.remove_linenums!(expr))
end

"""
    HTTP.@client requestlayers
    HTTP.@client requestlayers streamlayers
    HTTP.@client (first=requestlayers, last=requestlayers) (first=streamlayers, last=streamlayers)

Convenience macro for creating a custom HTTP.jl client that will include custom layers when
performing requests. It's common to want to define a custom [`Layer`](@ref) to enhance a
specific category of requests, such as custom authentcation for a web API. Instead of affecting
the global HTTP.jl request stack via [`HTTP.pushlayer!`](@ref), a custom wrapper client can be
defined with convenient shorthand methods. See [`Layer`](@ref) for an example of defining a custom
layer and creating a new client that includes the layer.

Custom layer arguments can be provided as a collection of request or stream-based layers; alternatively,
a NamedTuple with keys `first` and `last` can be provided with values being a collection of layers.
The NamedTuple form provides finer control over the order in which the layers will be included in the default
http layer stack: `first` request layers are executed before all other layers, `last` request layers
are executed right before all stream layers, and similarly for stream layers.

An empty collection can always be passed for request or stream layers when not needed.

One use case for custom clients is to control the value of standard `HTTP.request` keyword arguments.
This can be achieved by passing a `(first=[defaultkeywordlayer],)` where `defaultkeywordlayer` is defined
like:

```julia
defaultkeywordlayer(handler) = (req; kw...) -> handler(req; retry=false, redirect=false, kw...)
```

This client-side layer is basically a no-op as it doesn't modify the request at all, except that it
hard-codes the value of the `retry` and `redirect` keyword arguments. When we pass this layer as
`(first=[defaultkeywordlayer],)` this ensures this layer will be executed before all other layers,
effectively over-writing the default and any user-provided keyword arguments for `retry` or `redirect`.
"""
macro client(requestlayers, streamlayers=[])
    return @remove_linenums! esc(quote
        get(a...; kw...) = ($__source__; request("GET", a...; kw...))
        put(a...; kw...) = ($__source__; request("PUT", a...; kw...))
        post(a...; kw...) = ($__source__; request("POST", a...; kw...))
        patch(a...; kw...) = ($__source__; request("PATCH", a...; kw...))
        head(a...; kw...) = ($__source__; request("HEAD", a...; kw...))
        delete(a...; kw...) = ($__source__; request("DELETE", a...; kw...))
        open(f, a...; kw...) = ($__source__; request(a...; iofunction=f, kw...))
        function request(method, url, h=HTTP.Header[], b=HTTP.nobody; headers=h, body=b, query=nothing, observelayers::Bool=false, kw...)::HTTP.Response
            $__source__
            HTTP.request(HTTP.stack(observelayers, $requestlayers, $streamlayers), method, url, headers, body, query; kw...)
        end
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
    HTTP.openraw(method, url, [, headers])::Tuple{Connection, Response}

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
    Threads.@spawn HTTP.open(method, url, headers; kw...) do http
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
    parse(Request, str)
    parse(Response, str)

Parse a string into a `Request` or `Response` object.
"""
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
