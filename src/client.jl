@enum ConnectionState Busy Idle Dead

"""
    HTTP.Connection

Represents a persistent client connection to a remote host; only created
when a server response includes the "Connection: keep-alive" header. An open and non-idle connection
will be reused when sending subsequent requests to the same host.
"""
mutable struct Connection{I <: IO}
    id::Int
    socket::I
    state::ConnectionState
end

Connection(tcp::IO) = Connection(0, tcp, Busy)
Connection(id::Int, tcp::IO) = Connection(id, tcp, Busy)
busy!(conn::Connection) = (conn.state == Dead || (conn.state = Busy); return nothing)
idle!(conn::Connection) = (conn.state == Dead || (conn.state = Idle); return nothing)
dead!(conn::Connection) = (conn.state == Dead || (conn.state = Dead; close(conn.socket)); return nothing)

"""
    HTTP.Client([logger::IO]; args...)

A type to facilitate connections to remote hosts, send HTTP requests, and manage state between requests.
Takes an optional `logger` IO argument where client activity is recorded (defaults to `STDOUT`).
Additional keyword arguments can be passed that will get transmitted with each HTTP request:

* `chunksize::Int`: if a request body is larger than `chunksize`, the "chunked-transfer" http mechanism will be used and chunks will be sent no larger than `chunksize`; default = `nothing`
* `connecttimeout::Float64`: sets a timeout on how long to wait when trying to connect to a remote host; default = 10.0 seconds
* `readtimeout::Float64`: sets a timeout on how long to wait when receiving a response from a remote host; default = 9.0 seconds
* `tlsconfig::TLS.SSLConfig`: a valid `TLS.SSLConfig` which will be used to initialize every https connection; default = `nothing`
* `maxredirects::Int`: the maximum number of redirects that will automatically be followed for an http request; default = 5
* `allowredirects::Bool`: whether redirects should be allowed to be followed at all; default = `true`
* `forwardheaders::Bool`: whether user-provided headers should be forwarded on redirects; default = `false`
* `retries::Int`: # of times a request will be tried before throwing an error; default = 3
* `managecookies::Bool`: whether the request client should automatically store and add cookies from/to requests (following appropriate host-specific & expiration rules); default = `true`
* `statusraise::Bool`: whether an `HTTP.StatusError` should be raised on a non-2XX response status code; default = `true`
* `insecure::Bool`: whether an "https" connection should allow insecure connections (no TLS verification); default = `false`
"""
mutable struct Client
    # connection pools for keep-alive; key is host
    httppool::Dict{String, Vector{Connection{TCPSocket}}}
    httpspool::Dict{String, Vector{Connection{TLS.SSLContext}}}
    # cookies are stored in-memory per host and automatically sent when appropriate
    cookies::Dict{String, Set{Cookie}}
    # buffer::Vector{UInt8} #TODO: create a fixed size buffer for reading bytes off the wire and having http_parser use, this should keep allocations down, need to make sure MbedTLS supports blocking readbytes!
    parser::Parser
    logger::Option{IO}
    # global request settings
    options::RequestOptions
    connectioncount::Int
end

Client(logger::Option{IO}, options::RequestOptions) = Client(Dict{String, Vector{Connection{TCPSocket}}}(),
                                                     Dict{String, Vector{Connection{TLS.SSLContext}}}(),
                                                     Dict{String, Set{Cookie}}(),
                                                     Parser(), logger, options, 1)

const DEFAULT_OPTIONS = :((nothing, true, 15.0, 15.0, nothing, 5, true, false, 3, true, true, false))

@eval begin
    Client(logger::Option{IO}; args...) = Client(logger, RequestOptions($(DEFAULT_OPTIONS)...; args...))
    Client(; args...) = Client(nothing, RequestOptions($(DEFAULT_OPTIONS)...; args...))
end

function setclient!(client::Client)
    global const DEFAULT_CLIENT = client
end

Base.haskey(::Type{http}, client, host) = haskey(client.httppool, host)
Base.haskey(::Type{https}, client, host) = haskey(client.httpspool, host)

getconnections(::Type{http}, client, host) = client.httppool[host]
getconnections(::Type{https}, client, host) = client.httpspool[host]

setconnection!(::Type{http}, client, host, conn) = push!(get!(client.httppool, host, Connection[]), conn)
setconnection!(::Type{https}, client, host, conn) = push!(get!(client.httpspool, host, Connection[]), conn)

backtrace() = sprint(Base.show_backtrace, catch_backtrace())

"""
Abstract error type that all other HTTP errors subtype, including:

  * `HTTP.ConnectError`: thrown if a valid connection cannot be opened to the requested host/port
  * `HTTP.SendError`: thrown if a request is not able to be sent to the server
  * `HTTP.ClosedError`: thrown during sending or receiving if the connection to the server has been closed
  * `HTTP.ReadError`: thrown if an I/O error occurs when receiving a response from a server
  * `HTTP.RedirectError`: thrown if the number of http redirects exceeds the http request option `maxredirects`
  * `HTTP.StatusError`: thrown if a non-successful http status code is returned from the server, never thrown if `statusraise=false` is passed as a request option
"""
abstract type HTTPError <: Exception end

function Base.show(io::IO, e::HTTPError)
    println(io, "$(typeof(e)):")
    println(io, "Exception: $(e.e)")
    print(io, e.msg)
end
"An HTTP error thrown if a valid connection cannot be opened to the requested host/port"
struct ConnectError <: HTTPError
    e::Exception
    msg::String
end
"An HTTP error thrown if a request is not able to be sent to the server"
struct SendError <: HTTPError
    e::Exception
    msg::String
end
"An HTTP error thrown during sending or receiving if the connection to the server has been closed"
struct ClosedError <: HTTPError
    e::Exception
    msg::String
end
"An HTTP error thrown if an I/O error occurs when receiving a response from a server"
struct ReadError <: HTTPError
    e::Exception
    msg::String
end
"An HTTP error thrown if the number of http redirects exceeds the http request option `maxredirects`"
struct RedirectError <: HTTPError
    maxredirects::Int
end
function Base.show(io::IO, err::RedirectError)
    print(io, "RedirectError: more than $(err.maxredirects) redirects attempted")
end
"An HTTP error thrown if a non-successful http status code is returned from the server, never thrown if `statusraise=false` is passed as a request option"
struct StatusError <: HTTPError
    status::Int
    response::Response
end
function Base.show(io::IO, err::StatusError)
    print(io, "HTTP.StatusError: received a '$(err.status) - $(Base.get(STATUS_CODES, err.status, "Unknown Code"))' status in response")
end

initTLS!(::Type{http}, hostname, opts, socket) = socket

function initTLS!(::Type{https}, hostname, opts, socket)
    stream = TLS.SSLContext()
    TLS.setup!(stream, get(opts, :tlsconfig, TLS.SSLConfig(!opts.insecure::Bool))::TLS.SSLConfig)
    TLS.associate!(stream, socket)
    TLS.hostname!(stream, hostname)
    TLS.handshake!(stream)
    return stream
end

function stalebytes!(c::TCPSocket)
    !isopen(c) && return
    nb_available(c) > 0 && readavailable(c)
    return
end
stalebytes!(c::TLS.SSLContext) = stalebytes!(c.bio)

function connect(client, sch, hostname, port, opts, verbose)
    logger = client.logger
    if haskey(sch, client, hostname)
        @log "checking if any existing connections to '$hostname' are re-usable"
        conns = getconnections(sch, client, hostname)
        inds = Int[]
        i = 1
        while i <= length(conns)
            c = conns[i]
            # read off any stale bytes left over from a possible error in a previous request
            # this will also trigger any sockets that timed out to be set to closed
            stalebytes!(c.socket)
            if !isopen(c.socket) || c.state == Dead
                @log "found dead connection #$(c.id) to delete"
                dead!(c)
                push!(inds, i)
            elseif c.state == Idle
                @log "found re-usable connection #$(c.id)"
                busy!(c)
                try
                    deleteat!(conns, sort!(unique(inds)))
                end
                return c
            end
            i += 1
        end
        try
            deleteat!(conns, sort!(unique(inds)))
        end
    end
    # if no re-usable connection was found, make a new connection
    try
        # EH: throws DNSError, OutOfMemoryError, or SystemError; retry once, but otherwise, we can't do much
        ip = @retry Base.getaddrinfo(hostname)
        # EH: throws error, ArgumentError for out-of-range port, UVError; retry if UVError
        tcp = @retryif Base.UVError @timeout(opts.connecttimeout::Float64,
                                        Base.connect(ip, Base.parse(Int, port)), error("connect timeout"))
        socket = initTLS!(sch, hostname, opts, tcp)
        conn = Connection(client.connectioncount, socket)
        client.connectioncount += 1
        setconnection!(sch, client, hostname, conn)
        @log "created new connection #$(conn.id) to '$hostname'"
        return conn
    catch e
        throw(ConnectError(e, backtrace()))
    end
end

function addcookies!(client, host, req, verbose)
    logger = client.logger
    # check if cookies should be added to outgoing request based on host
    if haskey(client.cookies, host)
        cookies = client.cookies[host]
        tosend = Set{Cookie}()
        expired = Set{Cookie}()
        for (i, cookie) in enumerate(cookies)
            if Cookies.shouldsend(cookie, scheme(uri(req)) == "https", host, path(uri(req)))
                cookie.expires != DateTime() && cookie.expires < now(Dates.UTC) && (push!(expired, cookie); @log("deleting expired cookie: " * cookie.name); continue)
                push!(tosend, cookie)
            end
        end
        setdiff!(client.cookies[host], expired)
        if length(tosend) > 0
            @log "adding cached cookies for host to request header: " * join(map(x->x.name, tosend), ", ")
            req.headers["Cookie"] = string(Base.get(req.headers, "Cookie", ""), [c for c in tosend])
        end
    end
end

function connectandsend(client, ::Type{sch}, hostname, port, req, opts, verbose) where sch
    logger = client.logger
    conn = connect(client, sch, hostname, port, opts, verbose)
    opts.managecookies::Bool && addcookies!(client, hostname, req, verbose)
    try
        @log "sending request over the wire\n"
        reqstr = string(req, opts)
        verbose && (println(client.logger, "HTTP.Request:\n"); println(client.logger, reqstr))
        # EH: throws ArgumentError if socket is closed, UVError; retry if UVError,
        @retryif Base.UVError write(conn.socket, reqstr)
        !isopen(conn.socket) && throw(CLOSED_ERROR)
    catch e
        @log backtrace()
        typeof(e) <: ArgumentError && throw(ClosedError(e, backtrace()))
        throw(SendError(e, backtrace()))
    end
    return conn
end

function redirect(response, client, req, opts, stream, history, retry, verbose)
    logger = client.logger
    @log "checking for location to redirect"
    key = haskey(response.headers, "Location") ? "Location" :
          haskey(response.headers, "location") ? "location" : ""
    if key != ""
        push!(history, response)
        length(history) > opts.maxredirects::Int && throw(RedirectError(opts.maxredirects::Int))
        newuri = URIs.URL(response.headers[key])
        u = uri(req)
        newuri = !isempty(hostname(newuri)) ? newuri : URIs.URI(scheme=scheme(u), hostname=hostname(u), port=port(u), path=path(newuri), query=query(u))
        if opts.forwardheaders::Bool
            h = headers(req)
            delete!(h, "Host")
            delete!(h, "Cookie")
        else
            h = Headers()
        end
        redirectreq = Request(req.method, newuri, h, req.body)
        @log "redirecting to $(newuri)"
        return request(client, redirectreq, opts, stream, history, retry, verbose)
    end
end

const CLOSED_ERROR = ClosedError(ErrorException(""), "error receiving response; connection was closed prematurely")
function getbytes(socket, tm)
    try
        # EH: returns UInt8[] when socket is closed, error when socket is not readable, AssertionErrors, UVError;
        buffer = @retry @timeout(tm, readavailable(socket), error("read timeout"))
        return buffer, CLOSED_ERROR
    catch e
        return UInt8[], ReadError(e, backtrace())
    end
end

function processresponse!(client, conn, response, host, method, maintask, stream, tm, verbose)
    logger = client.logger
    while true
        buffer, err = getbytes(conn.socket, tm)
        if length(buffer) == 0 && !isopen(conn.socket)
            @log "socket closed before full response received"
            dead!(conn)
            close(response.body)
            # retry the entire request
            return false, err
        end
        @log "received bytes from the wire, processing"
        # EH: throws a couple of "shouldn't get here" errors; probably not much we can do
        errno, headerscomplete, messagecomplete, upgrade = HTTP.parse!(response, client.parser, buffer; host=host, method=method, maintask=maintask)
        if errno != HPE_OK
            dead!(conn)
            throw(ParsingError("error parsing response: $(ParsingErrorCodeMap[errno])\nCurrent response buffer contents: $(String(buffer))"))
        elseif messagecomplete
            http_should_keep_alive(client.parser, response) || (@log("closing connection (no keep-alive)"); dead!(conn))
            # idle! on a Dead will stay Dead
            idle!(conn)
            return true, StatusError(status(response), response)
        elseif stream && headerscomplete
            @log "processing the rest of response asynchronously"
            response.body.task = @async processresponse!(client, conn, response, host, method, maintask, false, tm, false)
            return true, nothing
        end
    end
    # shouldn't ever reach here
    dead!(conn)
    return false
end

function request(client::Client, req::Request, opts::RequestOptions, stream::Bool, history::Vector{Response}, retry::Int, verbose::Bool)
    retry = max(0, retry) # ensure non-negative
    update!(opts, client.options)
    verbose && not(client.logger) && (client.logger = STDOUT)
    logger = client.logger
    @log "using request options:\n\t" * join((s=>getfield(opts, s) for s in fieldnames(typeof(opts))), "\n\t")
    u = uri(req)
    host = hostname(u)
    sch = scheme(u) == "http" ? http : https
    @log "making $(method(req)) request for host: '$host' and resource: '$(resource(u))'"
    # maybe allow retrying for all kinds of errors?
    p = port(u)
    conn = @retryif ClosedError 4 connectandsend(client, sch, host, ifelse(p == "", "80", p), req, opts, verbose)
    
    response = Response(stream ? 2^24 : FIFOBuffers.DEFAULT_MAX, req)
    reset!(client.parser)
    success, err = processresponse!(client, conn, response, host, HTTP.method(req), current_task(), stream, opts.readtimeout::Float64, verbose)
    if !success
        retry >= opts.retries::Int && throw(err)
        return request(client, req, opts, stream, history, retry + 1, verbose)
    end
    @log "received response"
    opts.managecookies::Bool && !isempty(response.cookies) && (@log("caching received cookies for host: " * join(map(x->x.name, response.cookies), ", ")); union!(get!(client.cookies, host, Set{Cookie}()), response.cookies))
    response.history = history
    if opts.allowredirects::Bool && req.method != HEAD && (300 <= status(response) < 400)
        return redirect(response, client, req, opts, stream, history, retry, verbose)
    end
    if success && ((200 <= status(response) < 300) || !opts.statusraise::Bool)
        return response
    else
        retry >= opts.retries::Int && throw(err)
        return request(client, req, opts, stream, history, retry + 1, verbose)
    end
end

request(req::Request; 
            opts::RequestOptions=RequestOptions(),
            stream::Bool=false,
            history::Vector{Response}=Response[],
            retry::Int=0,
            verbose::Bool=false,
            args...) =
    request(DEFAULT_CLIENT, req, RequestOptions(opts; args...), stream, history, retry, verbose)
request(client::Client, req::Request;
            opts::RequestOptions=RequestOptions(),
            stream::Bool=false,
            history::Vector{Response}=Response[],
            retry::Int=0,
            verbose::Bool=false,
            args...) =
    request(client, req, RequestOptions(opts; args...), stream, history, retry, verbose)

# build Request
function request(client::Client, method, uri::URI;
                 headers::Headers=Headers(),
                 body=FIFOBuffers.EMPTYBODY,
                 stream::Bool=false,
                 verbose::Bool=false,
                 args...)
    opts = RequestOptions(; args...)
    not(client.logger) && (client.logger = STDOUT)
    client.logger != STDOUT && (verbose = true)
    req = Request(method, uri, headers, body; options=opts, verbose=verbose, logger=client.logger)
    return request(client, req; opts=opts, stream=stream, verbose=verbose)
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

* `headers::Dict{String,String}`: headers given as Dict to be sent with the request
* `body`: a request body can be given as a `String`, `Vector{UInt8}`, `IO`, `HTTP.FIFOBuffer` or `Dict`; see example below for how to utilize `HTTP.FIFOBuffer` for "streaming" request bodies; a `Dict` argument will be converted to a multipart form upload
* `stream::Bool=false`: enable response body streaming; depending on the response body size, the request will return before the full body has been received; as the response body is read, additional bytes will be recieved and put in the response body. Readers should read until `eof(response.body) == true`; see below for an example of response streaming
* `chunksize::Int`: if a request body is larger than `chunksize`, the "chunked-transfer" http mechanism will be used and chunks will be sent no larger than `chunksize`; default = `nothing`
* `connecttimeout::Float64`: sets a timeout on how long to wait when trying to connect to a remote host; default = 10.0 seconds
* `readtimeout::Float64`: sets a timeout on how long to wait when receiving a response from a remote host; default = 9.0 seconds
* `tlsconfig::TLS.SSLConfig`: a valid `TLS.SSLConfig` which will be used to initialize every https connection; default = `nothing`
* `maxredirects::Int`: the maximum number of redirects that will automatically be followed for an http request; default = 5
* `allowredirects::Bool`: whether redirects should be allowed to be followed at all; default = `true`
* `forwardheaders::Bool`: whether user-provided headers should be forwarded on redirects; default = `false`
* `retries::Int`: # of times a request will be tried before throwing an error; default = 3
* `managecookies::Bool`: whether the request client should automatically store and add cookies from/to requests (following appropriate host-specific & expiration rules); default = `true`
* `statusraise::Bool`: whether an `HTTP.StatusError` should be raised on a non-2XX response status code; default = `true`
* `insecure::Bool`: whether an "https" connection should allow insecure connections (no TLS verification); default = `false`

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
                println("[$(now())]: downloaded $nbytes bytes...")
                flush(STDOUT)
                threshold += threshold_step
            end
        end
        length(body) > 0 && write(f, readavailable(body))
    end
    return file
end
