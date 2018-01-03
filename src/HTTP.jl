__precompile__()
module HTTP

using MbedTLS
import MbedTLS.SSLContext


const DEBUG_LEVEL = 1
const minimal = false

include("compat.jl")

include("debug.jl")
include("Pairs.jl")
include("Strings.jl")
include("IOExtras.jl")
include("uri.jl");                      using .URIs
                                                                     if !minimal
include("consts.jl")
include("utils.jl")
include("fifobuffer.jl");               using .FIFOBuffers
include("cookies.jl");                  using .Cookies
include("multipart.jl")
                                                                             end
include("parser.jl");                   import .Parsers: ParsingError, Headers
include("Connect.jl")
include("ConnectionPool.jl")
include("Messages.jl");                 using .Messages
                                        import .Messages: header, hasheader
include("HTTPStreams.jl");              using .HTTPStreams
include("WebSockets.jl");               using .WebSockets


"""

    HTTP.request(method, url [, headers [, body]]; <keyword arguments>]) -> HTTP.Response

Send a HTTP Request Message and recieve a HTTP Response Message.

`headers` can be any collection where
`[string(k) => string(v) for (k,v) in headers]` yields `Vector{Pair}`.
e.g. a `Dict()`, a `Vector{Tuple}`, a `Vector{Pair}` or an iterator.

`body` can take a number of forms:

 - a `String`, a `Vector{UInt8}` or a readable `IO` stream
   or any `T` accepted by `write(::IO, ::T)`
 - a collection of `String` or `AbstractVector{UInt8}` or `IO` streams
   or items of any type `T` accepted by `write(::IO, ::T...)`
 - a readable `IO` stream or any `IO`-like type `T` for which
   `eof(T)` and `readavailable(T)` are defined.

The `HTTP.Response` struct contains:

 - `status::Int16` e.g. `200`
 - `headers::Vector{Pair{String,String}}`
    e.g. ["Server" => "Apache", "Content-Type" => "text/html"]
 - `body::Vector{UInt8}`, the Response Body bytes.
    Empty if a `response_stream` was specified in the `request`.

`HTTP.get`, `HTTP.put`, `HTTP.post` and `HTTP.head` are defined as shorthand
for `HTTP.request("GET", ...)`, etc.

`HTTP.request` and `HTTP.open` also accept the following optional keyword
parameters:


Streaming options (See [`HTTP.StreamLayer`](@ref)])

 - `response_stream = nothing`, a writeable `IO` stream or any `IO`-like
    type `T` for which `write(T, AbstractVector{UInt8})` is defined.
 - `verbose = 0`, set to `1` or `2` for extra message logging.


Connection Pool options (See `ConnectionPool.jl`)

 - `connectionpool = true`, enable the `ConnectionPool`.
 - `duplicate_limit = 7`, number of duplicate connections to each host:port.
 - `pipeline_limit = 16`, number of simultaneous requests per connection.
 - `reuse_limit = nolimit`, each connection is closed after this many requests.
 - `socket_type = TCPSocket`


Timeout options (See [`HTTP.TimeoutLayer`](@ref)])

 - `timeout = 60`, close the connection if no data is recieved for this many
   seconds. Use `timeout = 0` to disable.


Retry options (See [`HTTP.RetryLayer`](@ref)])

 - `retry = true`, retry idempotent requests in case of error.
 - `retries = 4`, number of times to retry.
 - `retry_non_idempotent = false`, retry non-idempotent requests too. e.g. POST.


Redirect options (See [`HTTP.RedirectLayer`](@ref)])

 - `redirect = true`, follow 3xx redirect responses.
 - `redirect_limit = 3`, number of times to redirect.
 - `forwardheaders = false`, forward original headers on redirect.


Status Exception options (See [`HTTP.ExceptionLayer`](@ref)])

 - `statusexception = true`, throw `HTTP.StatusError` for response status >= 300.


SSLContext options (See `Connect.jl`)

 - `require_ssl_verification = false`, pass `MBEDTLS_SSL_VERIFY_REQUIRED` to
   the mbed TLS library.
   ["... peer must present a valid certificate, handshake is aborted if
     verification failed."](https://tls.mbed.org/api/ssl_8h.html#a5695285c9dbfefec295012b566290f37)
 - sslconfig = SSLConfig(require_ssl_verification)`


Basic Authenticaiton options (See [`HTTP.BasicAuthLayer`](@ref)])

 - basicauthorization=false, add `Authorization: Basic` header using credentials
   from url userinfo.


AWS Authenticaiton options (See [`HTTP.AWS4AuthLayer`](@ref)])
 - `awsauthorization = false`, enable AWS4 Authentication.
 - `aws_service = split(uri.host, ".")[1]`
 - `aws_region = split(uri.host, ".")[2]`
 - `aws_access_key_id = ENV["AWS_ACCESS_KEY_ID"]`
 - `aws_secret_access_key = ENV["AWS_SECRET_ACCESS_KEY"]`
 - `aws_session_token = get(ENV, "AWS_SESSION_TOKEN", "")`
 - `body_sha256 = digest(MD_SHA256, body)`,
 - `body_md5 = digest(MD_MD5, body)`,


Cookie options (See [`HTTP.CookieLayer`](@ref)])

 - `cookies = false`, enable cookies.
 - `cookiejar::Dict{String, Set{Cookie}}=default_cookiejar`


Cananoincalization options (See [`HTTP.CanonicalizeLayer`](@ref)])

 - `canonicalizeheaders = false`, rewrite request and response headers in
   Canonical-Camel-Dash-Format.
"""

request(method::String, uri::URI, headers::Headers, body; kw...)::Response =
    request(HTTP.stack(;kw...), method, uri, headers, body; kw...)

request(method, uri, headers=[], body=UInt8[]; kw...)::Response =
    request(string(method), URI(uri), mkheaders(headers), body; kw...)


"""
    HTTP.open(method, url, [,headers]) do
        write(io, bytes)
    end -> HTTP.Response

The `HTTP.open` API allows the Request Body to be written to an `IO` stream.
`HTTP.open` also allows the Response Body to be streamed:


    HTTP.open(method, url, [,headers]) do io
        [startread(io) -> HTTP.Response]
        while !eof(io)
            readavailable(io) -> AbstractVector{UInt8}
        end
    end -> HTTP.Response
"""

open(f::Function, method::String, uri, headers=[]; kw...)::Response =
    request(method, uri, headers, nothing; iofunction=f, kw...)


"""
    HTTP.get(url [, headers]; <keyword arguments>) -> HTTP.Response


Shorthand for `HTTP.request("GET", ...)`. See [`HTTP.request`](@ref).
"""


get(a...; kw...) = request("GET", a..., kw...)

"""
    HTTP.put(url, headers, body; <keyword arguments>) -> HTTP.Response

Shorthand for `HTTP.request("PUT", ...)`. See [`HTTP.request`](@ref).
"""


put(a...; kw...) = request("PUT", a..., kw...)

"""
    HTTP.post(url, headers, body; <keyword arguments>) -> HTTP.Response

Shorthand for `HTTP.request("POST", ...)`. See [`HTTP.request`](@ref).
"""


post(a...; kw...) = request("POST", a..., kw...)

"""
    HTTP.head(url; <keyword arguments>) -> HTTP.Response

Shorthand for `HTTP.request("HEAD", ...)`. See [`HTTP.request`](@ref).
"""

head(a...; kw...) = request("HEAD", a..., kw...)



abstract type Layer end
                                                                     if !minimal
include("RedirectRequest.jl");          using .RedirectRequest
include("BasicAuthRequest.jl");         using .BasicAuthRequest
include("AWS4AuthRequest.jl");          using .AWS4AuthRequest
include("CookieRequest.jl");            using .CookieRequest
include("CanonicalizeRequest.jl");      using .CanonicalizeRequest
include("TimeoutRequest.jl");           using .TimeoutRequest
                                                                             end
include("MessageRequest.jl");           using .MessageRequest
include("ExceptionRequest.jl");         using .ExceptionRequest
                                        import .ExceptionRequest.StatusError
include("RetryRequest.jl");             using .RetryRequest
include("ConnectionRequest.jl");        using .ConnectionRequest
include("StreamRequest.jl");            using .StreamRequest
                                                                     if !minimal

function stack(;redirect=true,
                basicauthorization=false,
                awsauthorization=false,
                cookies=false,
                canonicalizeheaders=false,
                retry=true,
                statusexception=true,
                timeout=0,
                kw...)

    NoLayer = Union

    (redirect            ? RedirectLayer       : NoLayer){
    (basicauthorization  ? BasicAuthLayer      : NoLayer){
    (cookies             ? CookieLayer         : NoLayer){
    (canonicalizeheaders ? CanonicalizeLayer   : NoLayer){
                           MessageLayer{
    (awsauthorization    ? AWS4AuthLayer       : NoLayer){
    (retry               ? RetryLayer          : NoLayer){
    (statusexception     ? ExceptionLayer      : NoLayer){
                           ConnectionPoolLayer{
    (timeout > 0         ? TimeoutLayer        : NoLayer){
                           StreamLayer
    }}}}}}}}}}
end

                                                                            else
stack(;kw...) = MessageLayer{
                ExceptionLayer{
                ConnectionPoolLayer{
                StreamLayer}}}
                                                                             end

                                                                     if !minimal
include("client.jl")
include("sniff.jl")
include("handlers.jl");                  using .Handlers
include("server.jl");                    using .Nitrogen
include("precompile.jl")
                                                                             end

end # module
