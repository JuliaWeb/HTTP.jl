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

* `chunksize::Int`: if a request body is larger than `chunksize`, the "chunked-transfer" http mechanism will be used and chunks will be sent no larger than `chunksize`
* `connecttimeout::Float64`: sets a timeout on how long to wait when trying to connect to a remote host; default = 10.0 seconds
* `readtimeout::Float64`: sets a timeout on how long to wait when receiving a response from a remote host; default = 9.0 seconds
* `tlsconfig::TLS.SSLConfig`: a valid `TLS.SSLConfig` which will be used to initialize every https connection
* `maxredirects::Int`: the maximum number of redirects that will automatically be followed for an http request
* `allowredirects::Bool`: whether redirects should be allowed to be followed at all; default = `true`
* `forwardheaders::Bool`: whether user-provided headers should be forwarded on redirects; default = `false`
* `retries::Int`: # of times a request will be tried before throwing an error; default = 3
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

const DEFAULT_CHUNK_SIZE = 2^20
const DEFAULT_OPTIONS = :((DEFAULT_CHUNK_SIZE, true, 15.0, 15.0, nothing, 5, true, false, 3, true))

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

abstract type HTTPError <: Exception end

function Base.show(io::IO, e::HTTPError)
    println(io, "$(typeof(e)):")
    println(io, "Exception: $(e.e)")
    print(io, e.msg)
end

struct ConnectError <: HTTPError
    e::Exception
    msg::String
end

struct SendError <: HTTPError
    e::Exception
    msg::String
end

struct ClosedError <: HTTPError
    e::Exception
    msg::String
end

struct ReadError <: HTTPError
    e::Exception
    msg::String
end

struct RedirectException <: Exception
    maxredirects::Int
end
function Base.show(io::IO, err::RedirectException)
    print(io, "RedirectException: more than $(err.maxredirects) redirects attempted")
end

struct RetryException <: Exception
    retries::Int
end
function Base.show(io::IO, err::RetryException)
    print(io, "RetryException: # of allowed retries ($(err.retries)) was exceeded when making request")
end

initTLS!(::Type{http}, hostname, opts, socket) = socket

function initTLS!(::Type{https}, hostname, opts, socket)
    stream = TLS.SSLContext()
    TLS.setup!(stream, get(opts, :tlsconfig, TLS.SSLConfig(true))::TLS.SSLConfig)
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
    if haskey(sch, client, hostname)
        @log(verbose, client.logger, "checking if any existing connections to '$hostname' are re-usable")
        conns = getconnections(sch, client, hostname)
        inds = Int[]
        i = 1
        while i <= length(conns)
            c = conns[i]
            # read off any stale bytes left over from a possible error in a previous request
            # this will also trigger any sockets that timed out to be set to closed
            stalebytes!(c.socket)
            if !isopen(c.socket) || c.state == Dead
                @log(verbose, client.logger, "found dead connection #$(c.id) to delete")
                dead!(c)
                push!(inds, i)
            elseif c.state == Idle
                @log(verbose, client.logger, "found re-usable connection #$(c.id)")
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
        tcp = @retryif Base.UVError Base.connect(ip, Base.parse(Int, port))
        socket = initTLS!(sch, hostname, opts, tcp)
        conn = Connection(client.connectioncount, socket)
        client.connectioncount += 1
        setconnection!(sch, client, hostname, conn)
        @log(verbose, client.logger, "created new connection #$(conn.id) to '$hostname'")
        return conn
    catch e
        throw(ConnectError(e, backtrace()))
    end
end

function addcookies!(client, host, req, verbose)
    # check if cookies should be added to outgoing request based on host
    if haskey(client.cookies, host)
        cookies = client.cookies[host]
        tosend = Set{Cookie}()
        expired = Set{Cookie}()
        for (i, cookie) in enumerate(cookies)
            if Cookies.shouldsend(cookie, scheme(uri(req)) == "https", host, path(uri(req)))
                cookie.expires != DateTime() && cookie.expires < now(Dates.UTC) && (push!(expired, cookie); @log(verbose, client.logger, "deleting expired cookie: " * cookie.name); continue)
                push!(tosend, cookie)
            end
        end
        setdiff!(client.cookies[host], expired)
        if length(tosend) > 0
            @log(verbose, client.logger, "adding cached cookies for host to request header: " * join(map(x->x.name, tosend), ", "))
            req.headers["Cookie"] = string(Base.get(req.headers, "Cookie", ""), [c for c in tosend])
        end
    end
end

function connectandsend(client, ::Type{sch}, hostname, port, req, opts, verbose) where sch
    conn = connect(client, sch, hostname, port, opts, verbose)
    opts.managecookies::Bool && addcookies!(client, hostname, req, verbose)
    try
        @log(verbose, client.logger, "sending request over the wire")
        verbose && show(client.logger, req, opts); verbose && print(client.logger, "\n")
        # EH: throws ArgumentError if socket is closed, UVError; retry if UVError,
        @retryif Base.UVError write(conn.socket, req, opts)
        !isopen(conn.socket) && throw(CLOSED_ERROR)
    catch e
        typeof(e) <: ArgumentError && throw(ClosedError(e, backtrace()))
        throw(SendError(e, backtrace()))
    end
    return conn
end

const CLOSED_ERROR = ClosedError(ErrorException(""), "error receiving response; connection was closed prematurely")
function getbytes(socket)
    try
        # EH: returns UInt8[] when socket is closed, error when socket is not readable, AssertionErrors, UVError;
        buffer = @retry readavailable(socket)
        return buffer, CLOSED_ERROR
    catch e
        return UInt8[], ReadError(e, backtrace())
    end
end

function processresponse!(client, conn, response, host, method, maintask, stream, verbose)
    while true
        buffer, err = getbytes(conn.socket)
        if length(buffer) == 0 || !isopen(conn.socket)
            dead!(conn)
            if method in (GET, HEAD, OPTIONS)
                # retry the entire request
                return false
            else
                throw(err)
            end
        end
        @log(verbose, client.logger, "received bytes from the wire, processing")
        # EH: throws a couple of "shouldn't get here" errors; probably not much we can do
        errno, headerscomplete, messagecomplete, upgrade = HTTP.parse!(response, client.parser, buffer; host=host, method=method, maintask=maintask)
        if errno != HPE_OK
            dead!(conn)
            throw(ParsingError("error parsing response: $(ParsingErrorCodeMap[errno])\nCurrent response buffer contents: $(String(buffer))"))
        elseif messagecomplete
            http_should_keep_alive(client.parser, response) || (@log(verbose, client.logger, "closing connection (no keep-alive)"); dead!(conn))
            # idle! on a Dead will stay Dead
            idle!(conn)
            return true
        elseif stream && headerscomplete
            @log(verbose, client.logger, "processing the rest of response asynchronously")
            response.body.task = @async processresponse!(client, conn, response, host, method, maintask, false, false)
            return true
        end
    end
    # shouldn't ever reach here
    dead!(conn)
    return false
end

function redirect(response, client, req, opts, stream, history, retry, verbose)
    @log(verbose, client.logger, "checking for location to redirect")
    key = haskey(response.headers, "Location") ? "Location" :
          haskey(response.headers, "location") ? "location" : ""
    if key != ""
        push!(history, response)
        length(history) > opts.maxredirects::Int && throw(RedirectException(opts.maxredirects::Int))
        newuri = URI(response.headers[key])
        u = uri(req)
        newuri = !isempty(hostname(newuri)) ? newuri : URI(scheme=scheme(u), hostname=hostname(u), port=port(u), path=path(newuri), query=query(u))
        if opts.forwardheaders::Bool
            h = headers(req)
            delete!(h, "Host")
            delete!(h, "Cookie")
        else
            h = Headers()
        end
        redirectreq = Request(req.method, newuri, h, req.body)
        @log(verbose, client.logger, "redirecting to $(newuri)")
        return request(client, redirectreq, opts, stream, history, retry, verbose)
    end
end

function request(client::Client, req::Request, opts::RequestOptions, stream::Bool, history::Vector{Response}, retry::Int, verbose::Bool)
    retry = max(0, retry) # ensure non-negative
    update!(opts, client.options)
    verbose && not(client.logger) && (client.logger = STDOUT)
    @log(verbose, client.logger, "using request options: " * join((s=>getfield(opts, s) for s in fieldnames(typeof(opts))), ", "))
    u = uri(req)
    host = hostname(u)
    sch = scheme(u) == "http" ? http : https
    @log(verbose, client.logger, "making $(method(req)) request for host: '$host' and resource: '$(resource(u))'")
    # maybe allow retrying for all kinds of errors?
    p = port(u)
    conn = @retryif ClosedError 4 connectandsend(client, sch, host, ifelse(p == "", "80", p), req, opts, verbose)
    
    response = Response(stream ? DEFAULT_CHUNK_SIZE : FIFOBuffers.DEFAULT_MAX, req)
    reset!(client.parser)
    success = processresponse!(client, conn, response, host, HTTP.method(req), current_task(), stream, verbose)
    if !success
        retry >= opts.retries::Int && throw(RetryException(opts.retries::Int))
        return request(client, req, opts, stream, history, retry + 1, verbose)
    end
    @log(verbose, client.logger, "received response")
    opts.managecookies::Bool && !isempty(response.cookies) && (@log(verbose, client.logger, "caching received cookies for host: " * join(map(x->x.name, response.cookies), ", ")); union!(get!(client.cookies, host, Set{Cookie}()), response.cookies))
    response.history = history
    if opts.allowredirects::Bool && req.method != HEAD && (300 <= status(response) < 400)
        return redirect(response, client, req, opts, stream, history, retry, verbose)
    end
    return response
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
    req = Request(method, uri, headers, body; options=opts, verbose=verbose, io=client.logger)
    return request(client, req; opts=opts, stream=stream, verbose=verbose)
end
request(uri::String; verbose::Bool=false, query="", args...) = request(DEFAULT_CLIENT, GET, URI(uri; query=query); verbose=verbose, args...)
request(uri::URI; verbose::Bool=false, args...) = request(DEFAULT_CLIENT, GET, uri; verbose=verbose, args...)
request(method, uri::String; verbose::Bool=false, query="", args...) = request(DEFAULT_CLIENT, convert(HTTP.Method, method), URI(uri; query=query); verbose=verbose, args...)
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
(`HTTP.history(r)`), and response body (`HTTP.body(r)` or `String(take!(r)` or `take!(r)`).

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
* `chunksize::Int`: if a request body is larger than `chunksize`, the "chunked-transfer" http mechanism will be used and chunks will be sent no larger than `chunksize`
* `connecttimeout::Float64`: sets a timeout on how long to wait when trying to connect to a remote host; default = 10.0 seconds
* `readtimeout::Float64`: sets a timeout on how long to wait when receiving a response from a remote host; default = 9.0 seconds
* `tlsconfig::TLS.SSLConfig`: a valid `TLS.SSLConfig` which will be used to initialize every https connection
* `maxredirects::Int`: the maximum number of redirects that will automatically be followed for an http request
* `allowredirects::Bool`: whether redirects should be allowed to be followed at all; default = `true`
* `forwardheaders::Bool`: whether user-provided headers should be forwarded on redirects; default = `false`
* `retries::Int`: # of times a request will be tried before throwing an error; default = 3

Simple request example:
```julia
julia> resp = HTTP.get("http://httpbin.org/ip")
HTTP.Response:
HTTP/1.1 200 OK
Connection: keep-alive
Content-Length: 32
Access-Control-Allow-Credentials: true
Date: Fri, 06 Jan 2017 05:07:07 GMT
Content-Type: application/json
Access-Control-Allow-Origin: *
Server: nginx

{
  "origin": "65.130.216.45"
}


julia> string(resp)
"{\n  \"origin\": \"65.130.216.45\"\n}\n"
```

Response streaming example:
```julia
julia> r = HTTP.get("http://httpbin.org/stream/100"; stream=true)
HTTP.Response:
HTTP/1.1 200 OK
Content-Length: 0


julia> body = HTTP.body(r)
HTTP.FIFOBuffer(0,1048576,0,1,1,UInt8[],Condition(Any[]),Task (runnable) @0x000000010d221690,false)

julia> while true
    println(String(readavailable(body)))
    eof(body) && break
end
{"url": "http://httpbin.org/stream/100", "headers": {"Host": "httpbin.org", "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "User-Agent": "HTTP.jl/0.0.0"}, "args": {}, "id": 0, "origin": "65.130.216.45"}
{"url": "http://httpbin.org/stream/100", "headers": {"Host": "httpbin.org", "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "User-Agent": "HTTP.jl/0.0.0"}, "args": {}, "id": 1, "origin": "65.130.216.45"}
{"url": "http://httpbin.org/stream/100", "headers": {"Host": "httpbin.org", "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "User-Agent": "HTTP.jl/0.0.0"}, "args": {}, "id": 2, "origin": "65.130.216.45"}
{"url": "http://httpbin.org/stream/100", "headers": {"Host": "httpbin.org", "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "User-Agent": "HTTP.jl/0.0.0"}, "args": {}, "id": 3, "origin": "65.130.216.45"}
...
```

Request streaming example:
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
        ($f)(uri::AbstractString; verbose::Bool=false, query="", args...) = request(DEFAULT_CLIENT, $meth, URI(uri; query=query, isconnect=$(f_str == "CONNECT")); verbose=verbose, args...)
        ($f)(uri::URI; verbose::Bool=false, args...) = request(DEFAULT_CLIENT, $meth, uri; verbose=verbose, args...)
        ($f)(client::Client, uri::AbstractString; query="", args...) = request(client, $meth, URI(uri; query=query, isconnect=$(f_str == "CONNECT")); args...)
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
