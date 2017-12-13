using .Parsers

"""
    HTTP.Client([logger::IO]; args...)

A type to facilitate connections to remote hosts, send HTTP requests, and manage state between requests.
Takes an optional `logger` IO argument where client activity is recorded (defaults to `STDOUT`).
Additional keyword arguments can be passed that will get transmitted with each HTTP request:

  * `chunksize::Int`: if a request body is larger than `chunksize`, the "chunked-transfer" http mechanism will be used and chunks will be sent no larger than `chunksize`; default = `nothing`
  * `connecttimeout::Float64`: sets a timeout on how long to wait when trying to connect to a remote host; default = Inf. Note that while setting a timeout will affect the actual program control flow, there are current lower-level limitations that mean underlying resources may not actually be freed until their own timeouts occur (i.e. libuv sockets only timeout after 75 seconds, with no option to configure)
  * `readtimeout::Float64`: sets a timeout on how long to wait when receiving a response from a remote host; default = Int
  * `tlsconfig::TLS.SSLConfig`: a valid `TLS.SSLConfig` which will be used to initialize every https connection; default = `nothing`
  * `maxredirects::Int`: the maximum number of redirects that will automatically be followed for an http request; default = 5
  * `allowredirects::Bool`: whether redirects should be allowed to be followed at all; default = `true`
  * `forwardheaders::Bool`: whether user-provided headers should be forwarded on redirects; default = `false`
  * `retries::Int`: # of times a request will be tried before throwing an error; default = 3
  * `managecookies::Bool`: whether the request client should automatically store and add cookies from/to requests (following appropriate host-specific & expiration rules); default = `true`
  * `statusraise::Bool`: whether an `HTTP.StatusError` should be raised on a non-2XX response status code; default = `true`
  * `insecure::Bool`: whether an "https" connection should allow insecure connections (no TLS verification); default = `false`
  * `canonicalizeheaders::Bool`: whether header field names should be canonicalized in responses, e.g. `content-type` is canonicalized to `Content-Type`; default = `true`
  * `logbody::Bool`: whether the request body should be logged when `verbose=true` is passed; default = `true`
"""
mutable struct Client
    # cookies are stored in-memory per host and automatically sent when appropriate
    cookies::Dict{String, Set{Cookie}}
    # buffer::Vector{UInt8} #TODO: create a fixed size buffer for reading bytes off the wire and having http_parser use, this should keep allocations down, need to make sure MbedTLS supports blocking readbytes!
    logger::Option{IO}
    # global request settings
    options::RequestOptions
    connectioncount::Int
end

Client(logger::Option{IO}, options::RequestOptions) = Client(
                                                     Dict{String, Set{Cookie}}(),
                                                     logger, options, 1)

# this is where we provide all the default request options
const DEFAULT_OPTIONS = :((nothing, true, Inf, Inf, nothing, 5, true, false, 3, true, true, false, true, true))

@eval begin
    Client(logger::Option{IO}; args...) = Client(logger, RequestOptions($(DEFAULT_OPTIONS)...; args...))
    Client(; args...) = Client(nothing, RequestOptions($(DEFAULT_OPTIONS)...; args...))
end

function setclient!(client::Client)
    global const DEFAULT_CLIENT = client
end


# build Request
function request(client::Client, method, uri::URI;
                 headers::Dict=Headers(),
                 body="",
                 enablechunked::Bool=true,
                 stream::Bool=false,
                 verbose::Bool=false,
                 args...)
    #opts = RequestOptions(; args...)
    #not(client.logger) && (client.logger = STDOUT)
    #client.logger != STDOUT && (verbose = true)

    m = string(method)
    h = [k => v for (k,v) in headers]

    if stream
        push!(args, (:response_stream, BufferStream()))
    end

    if isa(body, Dict)
        body = HTTP.Form(body)
        Pairs.setbyfirst(h, "Content-Type" =>
                            "multipart/form-data; boundary=$(body.boundary)")
        Pairs.setkv(args, :bodylength, length(body))
    end

    if !enablechunked && isa(body, IO)
        body = read(body)
    end

    return RequestStack.request(m, uri, h, body; args...)
end
request(uri::AbstractString; verbose::Bool=false, query="", args...) = request(DEFAULT_CLIENT, GET, URIs.URL(uri; query=query); verbose=verbose, args...)
request(uri::URI; verbose::Bool=false, args...) = request(DEFAULT_CLIENT, GET, uri; verbose=verbose, args...)
request(method, uri::String; verbose::Bool=false, query="", args...) = request(DEFAULT_CLIENT, convert(HTTP.Method, method), URIs.URL(uri; query=query); verbose=verbose, args...)
request(method, uri::URI; verbose::Bool=false, args...) = request(DEFAULT_CLIENT, convert(HTTP.Method, method), uri; verbose=verbose, args...)

for f in [:get, :post, :put, :delete, :head,
          :trace, :options, :patch, :connect]
    f_str = uppercase(string(f))
    meth = convert(Method, f_str)
    @eval begin
        @doc """
    $($f)(uri; kwargs...) -> Response
    $($f)(client::HTTP.Client, uri; kwargs...) -> Response

Build and execute an http "$($f_str)" request. Query parameters can be passed via the `query` keyword argument as a `Dict`. Multiple
query parameters with the same key can be passed like `Dict("key1"=>["value1", "value2"], "key2"=>...)`.
Returns a `Response` object that includes the resulting status code (`HTTP.status(r)` and `HTTP.statustext(r)`),
response headers (`HTTP.headers(r)`), cookies (`HTTP.cookies(r)`), response history if redirects were involved
(`HTTP.history(r)`), and response body (`HTTP.body(r)` or `String(r)` or `take!(r)`).

The body or payload for a request can be given through the `body` keyword arugment.
The body can be given as a `String`, `Vector{UInt8}`, `IO`, `HTTP.FIFOBuffer` or `Dict` argument type.
See examples below for how to use an `HTTP.FIFOBuffer` for asynchronous streaming uploads.

If the body is provided as a `Dict`, the request body will be uploaded using the multipart/form-data encoding.
The key-value pairs in the Dict will constitute the name and value of each multipart boundary chunk.
Files and other large data arguments can be provided as values as IO arguments: either an `IOStream` such as returned via `open(file)`,
an `IOBuffer` for in-memory data, or even an `HTTP.FIFOBuffer`. For complete control over the multipart details, an
`HTTP.Multipart` type is provided to support setting the `Content-Type`, `filename`, and `Content-Transfer-Encoding` if desired. See `?HTTP.Multipart` for more details.

Additional keyword arguments supported, include:

  * `headers::Dict`: headers given as Dict to be sent with the request
  * `body`: a request body can be given as a `String`, `Vector{UInt8}`, `IO`, `HTTP.FIFOBuffer` or `Dict`; see example below for how to utilize `HTTP.FIFOBuffer` for "streaming" request bodies; a `Dict` argument will be converted to a multipart form upload
  * `stream::Bool=false`: enable response body streaming; depending on the response body size, the request will return before the full body has been received; as the response body is read, additional bytes will be recieved and put in the response body. Readers should read until `eof(response.body) == true`; see below for an example of response streaming
  * `chunksize::Int`: if a request body is larger than `chunksize`, the "chunked-transfer" http mechanism will be used and chunks will be sent no larger than `chunksize`; default = `nothing`
  * `connecttimeout::Float64`: sets a timeout on how long to wait when trying to connect to a remote host; default = Inf. Note that while setting a timeout will affect the actual program control flow, there are current lower-level limitations that mean underlying resources may not actually be freed until their own timeouts occur (i.e. libuv sockets only timeout after 75 seconds, with no option to configure)
  * `readtimeout::Float64`: sets a timeout on how long to wait when receiving a response from a remote host; default = Int
  * `tlsconfig::TLS.SSLConfig`: a valid `TLS.SSLConfig` which will be used to initialize every https connection; default = `nothing`
  * `maxredirects::Int`: the maximum number of redirects that will automatically be followed for an http request; default = 5
  * `allowredirects::Bool`: whether redirects should be allowed to be followed at all; default = `true`
  * `forwardheaders::Bool`: whether user-provided headers should be forwarded on redirects; default = `false`
  * `retries::Int`: # of times a request will be tried before throwing an error; default = 3
  * `managecookies::Bool`: whether the request client should automatically store and add cookies from/to requests (following appropriate host-specific & expiration rules); default = `true`
  * `statusraise::Bool`: whether an `HTTP.StatusError` should be raised on a non-2XX response status code; default = `true`
  * `insecure::Bool`: whether an "https" connection should allow insecure connections (no TLS verification); default = `false`
  * `canonicalizeheaders::Bool`: whether header field names should be canonicalized in responses, e.g. `content-type` is canonicalized to `Content-Type`; default = `true`
  * `logbody::Bool`: whether the request body should be logged when `verbose=true` is passed; default = `true`

Simple request example:
```julia
julia> resp = HTTP.get("http://httpbin.org/ip")
HTTP.Response:
\"\"\"
HTTP/1.1 200 OK
Connection: keep-alive
X-Powered-By: Flask
Content-Length: 32
Via: 1.1 vegur
Access-Control-Allow-Credentials: true
X-Processed-Time: 0.000903129577637
Date: Wed, 23 Aug 2017 23:35:59 GMT
Content-Type: application/json
Access-Control-Allow-Origin: *
Server: meinheld/0.6.1
Content-Length: 32

{ 
  "origin": "50.207.241.62"
}
\"\"\"


julia> String(resp)
"{\n  \"origin\": \"65.130.216.45\"\n}\n"
```

Response streaming example (asynchronous download):
```julia
julia> r = HTTP.get("http://httpbin.org/stream/100"; stream=true)
HTTP.Response:
\"\"\"
HTTP/1.1 200 OK
Connection: keep-alive
X-Powered-By: Flask
Transfer-Encoding: chunked
Via: 1.1 vegur
Access-Control-Allow-Credentials: true
X-Processed-Time: 0.000981092453003
Date: Wed, 23 Aug 2017 23:36:56 GMT
Content-Type: application/json
Access-Control-Allow-Origin: *
Server: meinheld/0.6.1

[HTTP.Response body of 27415 bytes]
Content-Length: 27390

{"id": 0, "origin": "50.207.241.62", "args": {}, "url": "http://httpbin.org/stream/100", "headers": {"Connection": "close", "User-Agent": "HTTP.jl/0.0.0", "Host": "httpbin.org", "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8,application/json"}}
{"id": 1, "origin": "50.207.241.62", "args": {}, "url": "http://httpbin.org/stream/100", "headers": {"Connection": "close", "User-Agent": "HTTP.jl/0.0.0", "Host": "httpbin.org", "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8,application/json"}}
{"id": 2, "origin": "50.207.241.62", "args": {}, "url": "http://httpbin.org/stream/100", "headers": {"Connection": "close", "User-Agent": "HTTP.jl/0.0.0", "Host": "httpbin.org", "
⋮
\"\"\"

julia> body = HTTP.body(r)
HTTP.FIFOBuffers.FIFOBuffer(27390, 1048576, 27390, 1, 27391, -1, 27390, UInt8[0x7b, 0x22, 0x69, 0x64, 0x22, 0x3a, 0x20, 0x30, 0x2c, 0x20  …  0x6e, 0x2f, 0x6a, 0x73, 0x6f, 0x6e, 0x22, 0x7d, 0x7d, 0x0a], Condition(Any[]), Task (done) @0x0000000112d84250, true)

julia> while true
           println(String(readavailable(body)))
           eof(body) && break
       end
{"id": 0, "origin": "50.207.241.62", "args": {}, "url": "http://httpbin.org/stream/100", "headers": {"Connection": "close", "User-Agent": "HTTP.jl/0.0.0", "Host": "httpbin.org", "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8,application/json"}}
{"id": 1, "origin": "50.207.241.62", "args": {}, "url": "http://httpbin.org/stream/100", "headers": {"Connection": "close", "User-Agent": "HTTP.jl/0.0.0", "Host": "httpbin.org", "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8,application/json"}}
{"id": 2, "origin": "50.207.241.62", "args": {}, "url": "http://httpbin.org/stream/100", "headers": {"Connection": "close", "User-Agent": "HTTP.jl/0.0.0", "Host": "httpbin.org", "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8,application/json"}}
{"id": 3, "origin": "50.207.241.62", "args": {}, "url": "http://httpbin.org/stream/100", "headers": {"Connection": "close", "User-Agent": "HTTP.jl/0.0.0", "Host": "httpbin.org", "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8,application/json"}}
...
```

Request streaming example (asynchronous upload):
```julia
# create a FIFOBuffer for sending our request body
f = HTTP.FIFOBuffer()
# write initial data
write(f, "hey")
# start an HTTP.post asynchronously
t = @async HTTP.post("http://httpbin.org/post"; body=f)
write(f, " there ") # as we write to f, it triggers another chunk to be sent in our async request
write(f, "sailor")
close(f) # setting eof on f causes the async request to send a final chunk and return the response

resp = wait(t) # get our response by getting the result of our asynchronous task
```
        """ function $(f) end
        ($f)(uri::AbstractString; verbose::Bool=false, query="", args...) = request(DEFAULT_CLIENT, $meth, URIs.URL(uri; query=query, isconnect=$(f_str == "CONNECT")); verbose=verbose, args...)
        ($f)(uri::URI; verbose::Bool=false, args...) = request(DEFAULT_CLIENT, $meth, uri; verbose=verbose, args...)
        ($f)(client::Client, uri::AbstractString; query="", args...) = request(client, $meth, URIs.URL(uri; query=query, isconnect=$(f_str == "CONNECT")); args...)
        ($f)(client::Client, uri::URI; args...) = request(client, $meth, uri; args...)
    end
end

function download(uri::AbstractString, file; threshold::Int=50000000, verbose::Bool=false, query="", args...)
    res = request(GET, uri; verbose=verbose, query=query, stream=true, args...)
    body = HTTP.body(res)
    file = Base.get(HTTP.headers(res), "Content-Encoding", "") == "gzip" ? string(file, ".gz") : file
    threshold_step = threshold
    nbytes = 0
    open(file, "w") do f
        while !eof(body)
            nbytes += write(f, readavailable(body))
            if verbose && nbytes > threshold
                println("[$(Dates.now())]: downloaded $nbytes bytes...")
                flush(STDOUT)
                threshold += threshold_step
            end
        end
        length(body) > 0 && write(f, readavailable(body))
    end
    return file
end
