"""
# Examples
Let's put together an example http REST server for our hypothetical "ZooApplication" that utilizes various
parts of the Servers & Handler frameworks.

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
HTTP.Handler framework in conjuction with running an HTTP server.
"""
module Routers

export Router, @register, register!

using ..Messages, ..URIs, ..Streams, ..IOExtras, ..Servers

"A default 404 Handler"
const FourOhFour = Servers.RequestHandlerFunction(req -> Response(404))

struct Route
    method::String
    scheme::String
    host::String
    path::String
end
getprt(s) = isempty(s) ? "*" : s
Base.show(io::IO, r::Route) = print(io, "HTTP.Route(method=$(getprt(r.method)), scheme=$(getprt(r.scheme)), host=$(getprt(r.host)), path=$(r.path))")

"""
HTTP.Router(h::Handler)
HTTP.Router(f::Function)
HTTP.Router()

An `HTTP.Handler` type that supports pattern matching request url paths to registered `HTTP.Handler`s.
Can accept a default `Handler` or `Function` that will be used in case no other handlers match; by
default, a 404 response handler is used.
Paths can be mapped to a handler via `HTTP.@register(r::Router, path, handler)`, see `?HTTP.@register` for more details.
"""
struct Router{sym} <: Handler
    default::Handler
    routes::Dict{Route, Any}
    segments::Dict{String, Val}
end

function Router(default::Union{Handler, Function, Nothing}=FourOhFour)
    # each router gets a unique symbol as a type parameter so that dispatching
    # requests always go to the correct router
    sym = gensym()
    return Router{sym}(default, Dict{Route, String}(), Dict{String, Val}())
end

const SCHEMES = Dict{String, Val}("http" => Val{:http}(), "https" => Val{:https}())
const EMPTYVAL = Val{()}()

function newsplitsegments(segments)
    vals = Expr[]
    for s in segments
        if s == "*" #TODO: or variable, keep track of variable types and store in handler
            T = Any
        else
            T = Val{Symbol(s)}
        end
        push!(vals, Expr(:(::), T))
    end
    return vals
end

"Dispatch function from a request target to router handler mapping; each `HTTP.@register` defines a new method to `gethandler` for a specific router to dispatch on"
function gethandler end
"fallback for all routers, calls the default handler the router was created with"
gethandler(r::Router, args...) = r.default

# convenience function to turn a path segment in to a Val{:segment} or Any if empty
gh(s::String) = isempty(s) ? Any : Val{Symbol(s)}
gh(s::Symbol) = Val{s}

function generate_gethandler(router, method, scheme, host, path, handler)
    vals = :(HTTP.Routers.newsplitsegments(map(String, split($path, '/'; keepempty=false)))...)
    q = esc(quote
        $(router).routes[HTTP.Routers.Route(string($method), string($scheme), string($host), string($path))] = $handler
        @eval function HTTP.Routers.gethandler(r::$(Expr(:$, :(typeof($router)))),
            ::(HTTP.Routers.gh($method)),
            ::(HTTP.Routers.gh($scheme)),
            ::(HTTP.Routers.gh($host)),
            $(Expr(:$, vals)),
            args...)
            return $(Expr(:$, handler)) isa HTTP.Handler ? $(Expr(:$, handler)) : HTTP.Servers.RequestHandlerFunction($(Expr(:$, handler)))
        end
    end)
    # @show q
    return q
end

"""
HTTP.@register(r::Router, path, handler)
HTTP.@register(r::Router, method::String, path, handler)
HTTP.@register(r::Router, method::String, scheme::String, host::String, path, handler)

Function to map request urls matching `path` and optional method, scheme, host to another `handler::HTTP.Handler`.
URL paths are registered one at a time, and multiple urls can map to the same handler.
The URL can be passed as a String. Requests can be routed based on: method, scheme, hostname, or path.
The following examples show how various urls will direct how a request is routed by a server:

- `"http://*"`: match all HTTP requests, regardless of path
- `"https://*"`: match all HTTPS requests, regardless of path
- `"/gmail"`: regardless of scheme or host, match any request with a path starting with "gmail"
- `"/gmail/userId/*/inbox`: match any request matching the path pattern, "*" is used as a wildcard that matches any value between the two "/"
"""
:(@register)

macro register(r, method, scheme, host, path, handler)
    return generate_gethandler(r, method, scheme, host, path, handler)
end
macro register(r, method, path, handler)
    return generate_gethandler(r, method, "", "", path, handler)
end
macro register(r, path, handler)
    return generate_gethandler(r, "", "", "", path, handler)
end

function gethandler(r::Router, req::Request)
    # get the url/path of the request
    m = Val(Symbol(req.method))
    # get scheme, host, split path into strings and get Vals
    uri = URI(req.target)
    s = get(SCHEMES, uri.scheme, EMPTYVAL)
    h = Val(Symbol(uri.host))
    p = uri.path
    segments = split(p, '/'; keepempty=false)
    # dispatch to the most specific handler, given the path
    vals = (get(r.segments, s, Val(Symbol(s))) for s in segments)
    return gethandler(r, m, s, h, vals...)
end

Servers.handle(r::Router, stream::Stream, args...) = handle(gethandler(r, stream.message), stream, args...)
Servers.handle(r::Router, req::Request, args...) = handle(gethandler(r, req), req, args...)

# deprecated
register!(r::Router, url, handler) = register!(r, "", url, handler)
function register!(r::Router, method::String, url, handler)
    m = isempty(method) ? Any : Val{Symbol(method)}
    # get scheme, host, split path into strings & vals
    uri = url isa String ? URI(url) : url
    s = uri.scheme
    sch = !isempty(s) ? typeof(get!(SCHEMES, s, Val(s))) : Any
    h = !isempty(uri.host) ? Val{Symbol(uri.host)} : Any
    hand = handler isa Handler ? handler : Servers.RequestHandlerFunction(handler)
    register!(r, m, sch, h, uri.path, hand)
end
function splitsegments(r::Router, segments)
    vals = Expr[]
    for s in segments
        if s == "*" #TODO: or variable, keep track of variable types and store in handler
            T = Any
        else
            v = Val(Symbol(s))
            r.segments[s] = v
            T = typeof(v)
        end
        push!(vals, Expr(:(::), T))
    end
    return vals
end
function register!(r::Router{id}, method, scheme, host, path, handler) where {id}
    Base.depwarn("`HTTP.register!(r::Router, ...)` is deprecated, use `HTTP.@register r ...` instead", nothing)
    # save string => Val mappings in r.segments
    segments = map(String, split(path, '/'; keepempty=false))
    vals = splitsegments(r, segments)
    # return a method to get dispatched to
    #TODO: detect whether defining this method will create ambiguity?
    @eval gethandler(r::Router{$(Meta.QuoteNode(id))}, ::$method, ::$scheme, ::$host, $(vals...), args...) = $handler
    return
end

end # module
