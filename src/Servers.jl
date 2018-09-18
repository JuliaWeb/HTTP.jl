"""
The `HTTP.Servers` module provides server-side http functionality in pure Julia.

The main entry point is `HTTP.listen(handler, host, port; kw...)` which takes a `handler` argument (see `?HTTP.Handlers`),
a `host` and `port` and optional keyword arguments. For full details, see `?HTTP.listen`.

# Examples
Let's put together an example http REST server for our hypothetical "ZooApplication" that utilizes various
parts of the Servers & Handlers frameworks.

Our application allows users to interact with custom "animal" JSON objects.

First we have our "model" or data structures:
```julia
mutable struct Animal
    id::Int
    type::String
    name::String
end
```

Now we want to define our REST api, or how do we allow users to create, update,
retrieve and delete animals:
```julia
# use a plain `Dict` as a "data store"
const ANIMALS = Dict{Int, Animal}()
const NEXT_ID = Ref(0)
function getNextId()
    id = NEXT_ID[]
    NEXT_ID[] += 1
    return id
end

# "service" functions to actually do the work
function createAnimal(req::HTTP.Request)
    animal = JSON2.read(IOBuffer(HTTP.payload(req)), Animal)
    animal.id = getNextId()
    ANIMALS[animal.id] = animal
    return HTTP.Response(200, JSON2.write(animal))
end

function getAnimal(req::HTTP.Request)
    animalId = HTTP.URIs.splitpath(req.target)[5] # /api/zoo/v1/animals/10, get 10
    animal = ANIMALS[animalId]
    return HTTP.Response(200, JSON2.write(animal))
end

function updateAnimal(req::HTTP.Request)
    animal = JSON2.read(IOBuffer(HTTP.payload(req)), Animal)
    ANIMALS[animal.id] = animal
    return HTTP.Response(200, JSON2.write(animal))
end

function deleteAnimal(req::HTTP.Request)
    animalId = HTTP.URIs.splitpath(req.target)[5] # /api/zoo/v1/animals/10, get 10
    delete!(ANIMALS, animal.id)
    return HTTP.Response(200)
end

# define REST endpoints to dispatch to "service" functions
const ANIMAL_ROUTER = HTTP.Router()
HTTP.@register(ANIMAL_ROUTER, "POST", "/api/zoo/v1/animals", createAnimal)
HTTP.@register(ANIMAL_ROUTER, "GET", "/api/zoo/v1/animals/*", getAnimal)
HTTP.@register(ANIMAL_ROUTER, "PUT", "/api/zoo/v1/animals", updateAnimal)
HTTP.@register(ANIMAL_ROUTER, "DELETE", "/api/zoo/v1/animals/*", deleteAnimal)
```

Great! At this point, we could spin up our server and let users start managing their animals:
```julia
HTTP.listen(ANIMAL_ROUTER, Sockets.localhost, 8081)
```

Now, you may have noticed that there was a bit of repitition in our "service" functions, particularly
with regards to the JSON serialization/deserialization. Perhaps we can simplify things by writing
a custom "JSONHandler" to do some of the repetitive work for us.
```julia
function JSONHandler(req::HTTP.Request)
    # first check if there's any request body
    body = IOBuffer(HTTP.payload(req))
    if eof(body)
        # no request body
        response_body = handle(ANIMAL_ROUTER, req)
    else
        # there's a body, so pass it on to the handler we dispatch to
        response_body = handle(ANIMAL_ROUTER, req, JSON2.read(body, Animal))
    end
    return HTTP.Response(200, JSON2.write(response_body))
end

# **simplified** "service" functions
function createAnimal(req::HTTP.Request, animal)
    animal.id = getNextId()
    ANIMALS[animal.id] = animal
    return animal
end

function getAnimal(req::HTTP.Request)
    animalId = HTTP.URIs.splitpath(req.target)[5] # /api/zoo/v1/animals/10, get 10
    return ANIMALS[animalId]
end

function updateAnimal(req::HTTP.Request, animal)
    ANIMALS[animal.id] = animal
    return animal
end

function deleteAnimal(req::HTTP.Request)
    animalId = HTTP.URIs.splitpath(req.target)[5] # /api/zoo/v1/animals/10, get 10
    delete!(ANIMALS, animal.id)
    return ""
end
```

And we modify slightly how we run our server, letting our new `JSONHandler` be the entry point
instead of our router:
```julia
HTTP.listen(JSONHandler, Sockets.localhost, 8081)
```

Our `JSONHandler` is nice because it saves us a bunch of repitition: if a request body comes in,
we automatically deserialize it and pass it on to the service function. And each service function
doesn't need to worry about returning `HTTP.Response`s anymore, but can just focus on returning
plain Julia objects/strings. The other huge advantage is it provides a clean separation of concerns
between the "service" layer, which should really concern itself with application logic, and the
"REST API" layer, which should take care of translating between a web data format (JSON).

Let's take this one step further and allow multiple users to manage users, and add in one more
custom handler to provide an authentication layer to our application. We can't just let anybody
be modifying another user's animals!
```julia
# modified Animal struct to associate with specific user
mutable struct Animal
    id::Int
    userId::Base.UUID
    type::String
    name::String
end

# modify our data store to allow for multiple users
const ANIMALS = Dict{Base.UUID, Dict{Int, Animal}}()

# creating a user returns a new UUID key unique to the user
createUser(req) = Base.UUID(rand(UInt128))

# add an additional endpoint for user creation
HTTP.@register(ANIMAL_ROUTER, "POST", "/api/zoo/v1/users", createUser)
# modify service endpoints to have user pass UUID in
HTTP.@register(ANIMAL_ROUTER, "GET", "/api/zoo/v1/users/*/animals/*", getAnimal)
HTTP.@register(ANIMAL_ROUTER, "DELETE", "/api/zoo/v1/users/*/animals/*", deleteAnimal)

# modified service functions to account for multiple users
function createAnimal(req::HTTP.Request, animal)
    animal.id = getNextId()
    ANIMALS[animal.userId][animal.id] = animal
    return animal
end

function getAnimal(req::HTTP.Request)
    paths = HTTP.URIs.splitpath(req.target)
    userId = path[5] # /api/zoo/v1/users/x92jf-.../animals/10, get user UUID
    animalId = path[7] # /api/zoo/v1/users/x92jf-.../animals/10, get 10
    return ANIMALS[userId][animalId]
end

function updateAnimal(req::HTTP.Request, animal)
    ANIMALS[animal.userId][animal.id] = animal
    return animal
end

function deleteAnimal(req::HTTP.Request)
    paths = HTTP.URIs.splitpath(req.target)
    userId = path[5] # /api/zoo/v1/users/x92jf-.../animals/10, get user UUID
    animalId = path[7] # /api/zoo/v1/users/x92jf-.../animals/10, get 10
    delete!(ANIMALS[userId], animal.id)
    return ""
end

# AuthHandler to reject any unknown users
function AuthHandler(req)
    if HTTP.hasheader(req, "Animal-UUID")
        uuid = HTTP.header(req, "Animal-UUID")
        if haskey(ANIMALS, uuid)
            return JSONHandler(req)
        end
    end
    return HTTP.Response(401, "unauthorized")
end
```

And our mofidified server invocation:
```julia
HTTP.listen(AuthHandler, Sockets.localhost, 8081)
```

Let's review what's going on here:
  * Each `Animal` object now includes a `UUID` object unique to a user
  * We added a `/api/zoo/v1/users` endpoint for creating a new user
  * Each of our service functions now account for individual users
  * We made a new `AuthHandler` as the very first entry point in our middleware stack,
    this means that every single request must first pass through this authentication
    layer before reaching the service layer. Our `AuthHandler` checks that the user
    provided our security request header `Animal-UUID` and if so, ensures the provided
    UUID corresponds to a valid user. If not, the `AuthHandler` returns a 401
    HTTP response, signalling that the request is unauthorized

Voila, hopefully that helps provide a slightly-more-than-trivial example of utilizing the
HTTP.Handlers framework in conjuction with running an HTTP server.
"""
module Servers

export listen

using Sockets, Dates, MbedTLS
using ..ConnectionPool, ..Parsers, ..IOExtras, ..Messages, ..Streams, ..Handlers

import ..Handlers.handle

# rate limiting
mutable struct RateLimit
    allowance::Float64
    lastcheck::Dates.DateTime
end

function update!(rl::RateLimit, ratelimit)
    current = Dates.now()
    timepassed = float(Dates.value(current - rl.lastcheck)) / 1000.0
    rl.lastcheck = current
    rl.allowance += timepassed * ratelimit
    return nothing
end

const RATE_LIMITS = Dict{IPAddr, RateLimit}()
check_rate_limit(tcp::Base.PipeEndpoint; kw...) = true

"""
`check_rate_limit` takes a new connection (socket), and checks in the global RATE_LIMITS
store for the last time a connection was seen for the same ip address. If the new 
connection has come too soon, it is closed and discarded, otherwise, the timestamp for
the ip address is updated in the global cache.
"""
function check_rate_limit(tcp, ratelimit::Rational{Int})
    ip = Sockets.getsockname(tcp)[1]
    rate = Float64(ratelimit.num)
    rl = get!(RATE_LIMITS, ip, RateLimit(rate, Dates.now()))
    update!(rl, ratelimit)
    if rl.allowance > rate
        @warn "throttling $ip"
        rl.allowance = rate
    end
    if rl.allowance < 1.0
        @warn "discarding connection from $ip due to rate limiting"
        return false
    else
        rl.allowance -= 1.0
    end
    return true
end

"""
Transaction handler: creates a new Stream for the Transaction, calls startread on it,
then dispatches the stream to the user-provided handler function. Catches errors on all
IO operations and closes gracefully if encountered.
"""
function handle(h::Handler, t::Transaction, last::Bool=false)
    request = Request()
    stream = Stream(request, t)

    try
        startread(stream)
    catch e
        if e isa EOFError && isempty(request.method)
            return
        elseif e isa ParseError
            status = e.code == :HEADER_SIZE_EXCEEDS_LIMIT  ? 413 : 400
            write(t, Response(status, body = string(e.code)))
            close(t)
            return
        elseif e isa Base.IOError && e.code == -54
            # read: connection reset by peer (ECONNRESET)
            return
        else
            rethrow(e)
        end
    end

    request.response.status = 200
    (last || hasheader(request, "Connection", "close")) &&
        setheader(request.response, "Connection" => "close")

    try
        handle(h, stream)
        closeread(stream)
        closewrite(stream)
    catch e
        @error "error handling request" exception=(e, stacktrace(catch_backtrace()))
        if isopen(stream) && !iswritable(stream)
            stream.message.response.status = 500
            startwrite(stream)
            write(stream, sprint(showerror, e))
        end
        last = true
    finally
        last && close(t.c.io)
    end
    return
end

"creates an async thread that waits a specified amount of time before closing the connection"
function check_readtimeout(c, readtimeout, wait_for_timeout)
    @async while wait_for_timeout[]
        if inactiveseconds(c) > readtimeout
            @warn "Connection Timeout: $c"
            try
                writeheaders(c.io, Response(408, ["Connection" => "close"]))
            finally
                close(c)
            end
            break
        end
        sleep(8 + rand() * 4)
    end
    return
end

"""
Connection handler: starts an async readtimeout thread if needed, then creates
Transactions to be handled as long as the Connection stays open. Only reuse_limit + 1
# of Transactions will be allowed during the lifetime of the Connection.
"""
function handle(h::Handler, c::Connection,
    reuse_limit::Int=10, readtimeout::Int=0)
    wait_for_timeout = Ref{Bool}(true)
    readtimeout > 0 && check_readtimeout(c, readtimeout, wait_for_timeout)
    try
        count = 0
        while isopen(c)
            handle(h, Transaction(c), count == reuse_limit)
            count += 1
        end
    finally
        wait_for_timeout[] = false
    end
    return
end

"Convenience object for passing around server details"
struct Server2{S, I}
    ssl::S # Union{SSLConfig, Nothing}; Nothing if non-SSL
    server::I
    hostname::String
    hostport::String
end
Base.isopen(s::Server2) = isopen(s.server)
Sockets.accept(s::Server2{Nothing, S}) where {S} = Sockets.accept(s.server)
function getsslcontext(tcp, sslconfig)
    ssl = SSLContext()
    setup!(ssl, sslconfig)
    associate!(ssl, tcp)
    handshake!(ssl)
    return ssl
end
Sockets.accept(s::Server2) = getsslcontext(accept(s.server), s.ssl)
Base.close(s::Server2) = close(s.server)

"main server loop that accepts new tcp connections and spawns async threads to handle them"
function listenloop(h::Handler, server,
    tcpisvalid=x->true, connectioncounter=Ref(0),
    reuse_limit::Int=1, readtimeout::Int=0, verbose::Bool=false)
    count = 1
    while isopen(server)
        try
            io = accept(server)
            io === nothing && continue
            if !tcpisvalid(io)
                verbose && @info "Accept-Reject:  $io"
                close(io)
                continue
            end
            connectioncounter[] += 1
            conn = Connection(server.hostname, server.hostport, 0, 0, true, io)
            let io=io, count=count
                @async begin
                    try
                        verbose && @info "Accept ($count):  $conn"
                        handle(h, conn, reuse_limit, readtimeout)
                        verbose && @info "Closed ($count):  $conn"
                    catch e
                        @error exception=(e, stacktrace(catch_backtrace()))
                    finally
                        connectioncounter[] -= 1
                        close(io)
                        verbose && @info "Closed ($count):  $conn"
                    end
                end
            end
        catch e
            if e isa InterruptException
                @warn "Interrupted: listen($server)"
                close(server)
                break
            end
            @error exception=(e, stacktrace(catch_backtrace()))
        end
        count += 1
    end
    return
end

getinet(host::String, port::Integer) = Sockets.InetAddr(parse(IPAddr, host), port)
getinet(host::IPAddr, port::Integer) = Sockets.InetAddr(host, port)

"""
    HTTP.listen([host=Sockets.localhost[, port=8081]]; kw...) do req
        ...
    end
    HTTP.listen(handler::HTTP.Handler, host=Sockets.localhost, port=8081; kw...)

Listen for HTTP connections and either execute the `do` function for each request, or dispatch to the
provided `handler`. Both the function or `handler` can accept an `HTTP.Request` object, or a raw
`HTTP.Stream` connection to read & write from directly.

Optional keyword arguments:
 - `sslconfig=nothing`: Provide an `MbedTLS.SSLConfig` object to handle ssl connections
 - `reuse_limit = nolimit`, number of times a connection is allowed to be reused
                            after the first request.
 - `tcpisvalid::Function (::TCPSocket) -> Bool`, check accepted connection before
    processing requests. e.g. to implement source IP filtering, rate-limiting,
    etc.
 - `readtimeout::Int=0`: # of seconds to wait on an incoming request before closing a connection
 - `reuseaddr::Bool=false`: whether multiple servers should be allowed to listen on the same port
 - `tcpref::Ref{Base.IOServer}`, this reference is set to the underlying
                                 `IOServer`. e.g. to allow closing the server.
 - `connectioncounter::Ref{Int}`: a `Ref{Int}` that can be used to track the # of currently open (i.e
        currently being handled) connections for a server
 - `ratelimit`: a `Rational{Int}` of the form `5//1` indicating how many `messages//second`
        should be allowed per client IP address; requests exceeding the rate limit will be auto-closed
 - `verbose::Bool=false`: whether simple logging should print to stdout for connections handled

e.g.
```
    HTTP.listen() do http::HTTP.Stream
        @show http.message
        @show HTTP.header(http, "Content-Type")
        while !eof(http)
            println("body data: ", String(readavailable(http)))
        end
        setstatus(http, 404)
        setheader(http, "Foo-Header" => "bar")
        startwrite(http)
        write(http, "response body")
        write(http, "more response body")
        return
    end

    HTTP.listen() do request::HTTP.Request
        @show HTTP.header(request, "Content-Type")
        @show HTTP.payload(request, String)
        return HTTP.Response(404)
    end
```
"""
function listen end

function listen(h::Handler, host::Union{IPAddr, String}, port::Integer=8081;
    tcpref::Union{Ref, Nothing}=nothing,
    reuseaddr::Bool=false,
    sslconfig::Union{MbedTLS.SSLConfig, Nothing}=nothing,
    tcpisvalid::Union{Function, Nothing}=nothing,
    ratelimit::Union{Rational{Int}, Nothing}=nothing,
    connectioncounter::Ref{Int}=Ref(0),
    reuse_limit::Int=1, readtimeout::Int=0, verbose::Bool=false)

    inet = getinet(host, port)
    if tcpref !== nothing
        tcpserver = tcpref[]
    elseif reuseaddr
        tcpserver = Sockets.TCPServer(; delay=false)
        if Sys.isunix()
            rc = ccall(:jl_tcp_reuseport, Int32, (Ptr{Cvoid},), tcpserver.handle)
            Sockets.bind(tcpserver, inet.host, inet.port; reuseaddr=true)
        else
            @warn "reuseaddr=true may not be supported on this platform: $(Sys.KERNEL)"
            Sockets.bind(tcpserver, inet.host, inet.port; reuseaddr=true)
        end
        Sockets.listen(tcpserver)
    else
        tcpserver = Sockets.listen(inet)
    end
    verbose && @info "Listening on: $host:$port"

    if tcpisvalid === nothing
        tcpisvalid = ratelimit === nothing ? x->true : x->check_rate_limit(x, ratelimit)
    end

    return listenloop(h, Server2(sslconfig, tcpserver, string(host), string(port)), tcpisvalid,
        connectioncounter, reuse_limit, readtimeout, verbose)
end

listen(f::Base.Callable, host, port::Integer=8081; kw...) = listen(Handlers.Handler(f), host, port; kw...)

function serve(host, port=8081; handler=req->HTTP.Response(200, "Hello World!"),
    ssl::Bool=false, require_ssl_verification::Bool=true, kw...)
    Base.depwarn("`HTTP.serve` is deprecated, use `HTTP.listen(f_or_handler, host, port; kw...)` instead", nothing)
    sslconfig = ssl ? MbedTLS.SSLConfig(require_ssl_verification) : nothing
    return listen(handler, host, port; sslconfig=sslconfig, kw...)
end

end # module