@enum ConnectionState Busy Idle Dead

"""
    HTTP.Connection

Represents a persistent client connection to a remote host; only created
when a server response includes the "Connection: keep-alive" header. An open and non-idle connection
will be reused when sending subsequent requests to the same host.
"""
type Connection{I <: IO}
    tcp::I
    state::ConnectionState
    statetime::DateTime
end

Connection(tcp::IO) = Connection(tcp, Busy, now(Dates.UTC))
busy!(conn::Connection) = (conn.state = conn.state == Dead ? (return nothing) : Busy; conn.statetime = now(Dates.UTC); return nothing)
idle!(conn::Connection) = (conn.state = conn.state == Dead ? (return nothing) : Idle; conn.statetime = now(Dates.UTC); return nothing)
dead!(conn::Connection) = (conn.state = Dead; conn.statetime = now(Dates.UTC); close(conn.tcp); return nothing)

Base.haskey(::Type{http}, client, host) = haskey(client.httppool, host)
Base.haskey(::Type{https}, client, host) = haskey(client.httpspool, host)

getconnections(::Type{http}, client, host) = client.httppool[host]
getconnections(::Type{https}, client, host) = client.httpspool[host]

setconnection!(::Type{http}, client, host, conn) = push!(get!(client.httppool, host, Connection[]), conn)
setconnection!(::Type{https}, client, host, conn) = push!(get!(client.httpspool, host, Connection[]), conn)

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
"""
type Client{I <: IO}
    # connection pools for keep-alive; key is host
    httppool::Dict{String, Vector{Connection{TCPSocket}}}
    httpspool::Dict{String, Vector{Connection{TLS.SSLContext}}}
    # cookies are stored in-memory per host and automatically sent when appropriate
    cookies::Dict{String, Set{Cookie}}
    # buffer::Vector{UInt8} #TODO: create a fixed size buffer for reading bytes off the wire and having http_parser use, this should keep allocations down, need to make sure MbedTLS supports blocking readbytes!
    parser::Parser
    logger::I
    # global request settings
    options::RequestOptions
end

Client(logger::IO, options::RequestOptions) = Client(Dict{String, Vector{Connection{TCPSocket}}}(),
                                                     Dict{String, Vector{Connection{TLS.SSLContext}}}(),
                                                     Dict{String, Set{Cookie}}(),
                                                     Parser(), logger, options)

const DEFAULT_CHUNK_SIZE = 2^20
const DEFAULT_OPTIONS = :((DEFAULT_CHUNK_SIZE, true, 10.0, 10.0, TLS.SSLConfig(true), 5, true))

@eval begin
    Client(logger::IO; args...) = Client(logger, RequestOptions($(DEFAULT_OPTIONS)...; args...))
    Client(; args...) = Client(STDOUT, RequestOptions($(DEFAULT_OPTIONS)...; args...))
end

"""
    HTTP.request([client::HTTP.Client,] req::HTTP.Request; stream::Bool=false, verbose=false)
    HTTP.request([client,] method, uri; headers=HTTP.Headers(), body="", stream=false, verbose=false)

Make an `HTTP.Request` to its associated host/uri. Set the keyword argument `stream=true` to enable
response streaming, which will result in `HTTP.request` potentially returning before the entire response
body has been received. If the response body buffer fills all the way up, it will block until its contents
are read, freeing up additional space to write.
"""
function request end

request(uri::String; verbose::Bool=false, query="", args...) = (@log(verbose, STDOUT, "using default client"); request(DEFAULT_CLIENT, GET, URI(uri; query=query); verbose=verbose, args...))
request(uri::URI; verbose::Bool=false, args...) = (@log(verbose, STDOUT, "using default client"); request(DEFAULT_CLIENT, GET, uri; verbose=verbose, args...))
request(method, uri::String; verbose::Bool=false, query="", args...) = (@log(verbose, STDOUT, "using default client"); request(DEFAULT_CLIENT, convert(HTTP.Method, method), URI(uri; query=query); verbose=verbose, args...))
request(method, uri::URI; verbose::Bool=false, args...) = (@log(verbose, STDOUT, "using default client"); request(DEFAULT_CLIENT, convert(HTTP.Method, method), uri; verbose=verbose, args...))
function request(client::Client, method, uri::URI;
                    headers::Headers=Headers(),
                    body=EMPTYBODY,
                    stream::Bool=false,
                    verbose::Bool=false,
                    args...)
    opts = RequestOptions(; args...)
    req = Request(method, uri, headers, body; options=opts, verbose=verbose, io=client.logger)
    return request(client, req, opts; stream=stream, verbose=verbose)
end

request(req::Request; stream::Bool=false, verbose::Bool=false, args...) = request(DEFAULT_CLIENT, req, RequestOptions(; args...); stream=stream, verbose=verbose)

function request(client::Client, req::Request, opts::RequestOptions; history::Vector{Response}=Response[], stream::Bool=false, verbose::Bool=false)
    client.logger != STDOUT && (verbose = true)
    # ensure all Request options are set, using client.options if necessary
    # this works because req.options are null by default whereas client.options always have a default
    update!(opts, client.options)
    @log(verbose, client.logger, "using request options: " * join((s=>getfield(opts, s) for s in fieldnames(opts)), ", "))
    # if the provided req body is compressed, avoid any chunked transfer since it ruins the compression scheme
    if iscompressed(String(req.body)) && length(req.body) > opts.chunksize
        opts.chunksize = length(req.body) + 1
    end
    h = host(uri(req))
    return scheme(uri(req)) == "https" ? request(client, req, opts, getconn(https, client, h, opts, verbose), history, stream, verbose) :
                                           request(client, req, opts, getconn(http, client, h, opts, verbose), history, stream, verbose)
end

function stalebytes!(c::TCPSocket)
    !isopen(c) && return
    @debug(DEBUG, @__LINE__, nb_available(c))
    nb_available(c) > 0 && readavailable(c)
    return
end
# this is an ugly hack for MbedTLS since nb_available seems to be unreliable sometimes
stalebytes!(c::TLS.SSLContext) = stalebytes!(c.bio)

function getconn{S}(::Type{S}, client, host, opts, verbose)
    # connect to remote host
    # check if an open connection to host already exists
    reused = false
    hostname, port = split(host, ':'; limit=2)
    local conn::Connection{sockettype(S)}
    if haskey(S, client, hostname)
        @log(verbose, client.logger, "checking if any existing connections to '$hostname' are re-usable")
        conns = getconnections(S, client, hostname)
        inds = Int[]
        for (i, c) in enumerate(conns)
            # read off any stale bytes left over from a possible error in a previous request
            # this will also trigger any sockets that timed out to be set to closed
            stalebytes!(c.tcp)
            if !isopen(c.tcp) || c.state == Dead
                @log(verbose, client.logger, "found a dead connection to delete")
                dead!(c)
                push!(inds, i)
            elseif c.state == Idle
                @log(verbose, client.logger, "found re-usable connection")
                busy!(c)
                conn = c
                reused = true
            end
        end
        deleteat!(conns, inds)
    end
    if !reused
        @log(verbose, client.logger, "creating a new connection to '$hostname'")
        socket = @timeout opts.connecttimeout::Float64 Base.connect(Base.getaddrinfo(hostname), Base.parse(Int, port)) throw(TimeoutException(opts.connecttimeout::Float64))
        # initialize TLS if necessary
        tcp = initTLS!(S, hostname, opts, socket)
        conn = Connection(tcp)
        setconnection!(S, client, hostname, conn)
    end
    return conn
end

initTLS!(::Type{http}, hostname, opts, socket) = socket
function initTLS!(::Type{https}, hostname, opts, socket)
    stream = TLS.SSLContext()
    TLS.setup!(stream, opts.tlsconfig::TLS.SSLConfig)
    TLS.associate!(stream, socket)
    TLS.hostname!(stream, hostname)
    TLS.handshake!(stream)
    return stream
end

function request{T}(client::Client, req::Request, opts::RequestOptions, conn::Connection{T}, history, stream::Bool, verbose::Bool)
    host = hostname(uri(req))
    # check if cookies should be added to outgoing request based on host
    if haskey(client.cookies, host)
        cookies = client.cookies[host]
        tosend = Set{Cookie}()
        expired = Set{Cookie}()
        for (i, cookie) in enumerate(cookies)
            if Cookies.shouldsend(cookie, scheme(uri(req)) == "https", host, path(uri(req)))
                cookie.expires != DateTime() && cookie.expires < now(Dates.UTC) && (push!(expired, cookie); @log(verbose, client.logger, "deleting expired cookie"); continue)
                push!(tosend, cookie)
            end
        end
        setdiff!(client.cookies[host], expired)
        if length(tosend) > 0
            @log(verbose, client.logger, "adding cached cookies for host to request header")
            req.headers["Cookie"] = string(Base.get(req.headers, "Cookie", ""), [c for c in tosend])
        end
    end
    # send request over the wire
    @log(verbose, client.logger, "sending request over the wire")
    verbose && show(client.logger, req); verbose && print(client.logger, "\n")
    try
        write(conn.tcp, req, opts)
    catch
        @log(verbose, client.logger, "error sending request, retrying on a new connection")
        conn = getconn(schemetype(T), client, host, opts, verbose)
        write(conn.tcp, req, opts)
    end
    # create a Response to fill
    response = Response(stream ? DEFAULT_CHUNK_SIZE : DEFAULT_MAX, req)
    # process the response
    reset!(client.parser)
    success = process!(client, conn, opts, host, method(req), response, Ref{Float64}(time()), stream, verbose)
    !success && return request(client, req, opts; history=history, stream=stream, verbose=verbose)
    !isempty(response.cookies) && (@log(verbose, client.logger, "caching received cookies for host"); union!(get!(client.cookies, host, Set{Cookie}()), response.cookies))
    # return immediately for streaming responses
    stream && return response
    @log(verbose, client.logger, "received response")
    verbose && show(client.logger, response); verbose && print(client.logger, "\n")
    # check for redirect
    response.history = history
    if req.method != HEAD && (300 <= status(response) < 400) && opts.allowredirects::Bool
        @log(verbose, client.logger, "checking for location to redirect")
        key = haskey(response.headers, "Location") ? "Location" :
              haskey(response.headers, "location") ? "location" : ""
        if key != ""
            push!(history, response)
            length(history) > opts.maxredirects::Int && throw(RedirectException(opts.maxredirects::Int))
            newuri = URI(response.headers[key])
            u = uri(req)
            newuri = !isempty(hostname(newuri)) ? newuri : URI(scheme=scheme(u), hostname=hostname(u), port=port(u), path=path(newuri), query=query(u))
            delete!(req.headers, "Host")
            delete!(req.headers, "Cookie")
            redirectreq = Request(req.method, newuri, req.headers, req.body)
            @log(verbose, client.logger, "redirecting to $(newuri)")
            return request(client, redirectreq, opts, conn, history, false, verbose)
        end
    end
    return response
end

function process!(client, conn, opts, host, method, response, starttime, stream, verbose)
    parser = client.parser
    tsk = @async begin
        while true
            # if no data after 30 seconds, break out
            @log(verbose, client.logger, "waiting for response; will timeout afer $(opts.readtimeout) seconds")
            buffer = readavailable(conn.tcp)
            @debug(DEBUG, @__LINE__, length(buffer))
            @debug(DEBUG, @__LINE__, isopen(conn.tcp))
            if length(buffer) == 0 && !isopen(conn.tcp)
                dead!(conn)
                @log(verbose, client.logger, "request was sent, but connection closed before receiving response, retrying request")
                return false
            end
            starttime[] = time() # reset the timeout while still receiving bytes
            @log(verbose, client.logger, "received bytes from the wire, processing")
            errno, headerscomplete, messagecomplete, upgrade = HTTP.parse!(response, client.parser, buffer; host=host, method=method)
            @debug(DEBUG, @__LINE__, errno)
            @debug(DEBUG, @__LINE__, headerscomplete)
            @debug(DEBUG, @__LINE__, messagecomplete)
            if errno != HPE_OK
                throw(ParsingError("error parsing response: $(ParsingErrorCodeMap[errno])"))
            elseif messagecomplete
                http_should_keep_alive(parser, response) || (@log(verbose, client.logger, "closing connection (no keep-alive)"); dead!(conn))
                break
            elseif stream && headerscomplete
                # async read the response body, returning the current response immediately
                @log(verbose, client.logger, "processing the rest of response asynchronously")
                response.body.task = @async process!(client, conn, opts, host, method, response, starttime, false, false)
                break
            end
            !isopen(conn.tcp) && (dead!(conn); break)
        end
        !stream && idle!(conn)
    end
    timeout = opts.readtimeout::Float64
    while !istaskdone(tsk) && (time() - starttime[] < timeout)
        sleep(0.001)
    end
    istaskdone(tsk) || throw(TimeoutException(timeout))
    return true
end

immutable RedirectException <: Exception
    maxredirects::Int
end

function Base.show(io::IO, err::RedirectException)
    print(io, "RedirectException: more than $(err.maxredirects) redirects attempted")
end

immutable TimeoutException <: Exception
    timeout::Float64
end

function Base.show(io::IO, err::TimeoutException)
    print(io, "TimeoutException: server did not respond for more than $(err.timeout) seconds. ")
end

for f in [:get, :post, :put, :delete, :head,
          :trace, :options, :patch, :connect]
    f_str = uppercase(string(f))
    meth = convert(HTTP.Method, f_str)
    @eval begin
        @doc """
    $($f)(uri) -> Response
    $($f)(client::HTTP.Client, uri) -> Response

Build and execute an http "$($f_str)" request. Query parameters can be passed via the `query` keyword argument as a `Dict`.
Returns a `Response` object that includes the resulting status code (`HTTP.status(r)` and `HTTP.statustext(r)`),
response headers (`HTTP.headers(r)`), cookies (`HTTP.cookies(r)`), response history if redirects were involved
(`HTTP.history(r)`), and response body (`HTTP.body(r)` or `string(r)` or `HTTP.bytes(r)`).

Additional keyword arguments supported, include:

* `headers::Dict{String,String}`: headers given as Dict to be sent with the request
* `body`: a request body can be given as a `String`, `Vector{UInt8}`, `IO`, or `HTTP.FIFOBuffer`; see example below for how to utilize `HTTP.FIFOBuffer` for "streaming" request bodies
* `stream::Bool=false`: enable response body streaming; depending on the response body size, the request will return before the full body has been received; as the response body is read, additional bytes will be recieved and put in the response body. Readers should read until `eof(response.body) == true`; see below for an example of response streaming
* `chunksize::Int`: if a request body is larger than `chunksize`, the "chunked-transfer" http mechanism will be used and chunks will be sent no larger than `chunksize`
* `connecttimeout::Float64`: sets a timeout on how long to wait when trying to connect to a remote host; default = 10.0 seconds
* `readtimeout::Float64`: sets a timeout on how long to wait when receiving a response from a remote host; default = 9.0 seconds
* `tlsconfig::TLS.SSLConfig`: a valid `TLS.SSLConfig` which will be used to initialize every https connection
* `maxredirects::Int`: the maximum number of redirects that will automatically be followed for an http request
* `allowredirects::Bool`: whether redirects should be allowed to be followed at all; default = `true`

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
        ($f)(uri::AbstractString; verbose::Bool=false, query="", args...) = (@log(verbose, STDOUT, "using default client"); request(DEFAULT_CLIENT, $meth, URI(uri; query=query, isconnect=$(f_str == "CONNECT")); verbose=verbose, args...))
        ($f)(uri::URI; verbose::Bool=false, args...) = (@log(verbose, STDOUT, "using default client"); request(DEFAULT_CLIENT, $meth, uri; verbose=verbose, args...))
        ($f)(client::Client, uri::AbstractString; query="", args...) = request(client, $meth, URI(uri; query=query, isconnect=$(f_str == "CONNECT")); args...)
        ($f)(client::Client, uri::URI; args...) = request(client, $meth, uri; args...)
    end
end
