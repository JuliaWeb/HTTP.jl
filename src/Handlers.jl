module Handlers

export Handler, Middleware, serve, Router, register!, getparams, getcookies, streamhandler

using URIs
using ..Messages, ..Streams, ..IOExtras, ..Servers, ..Sockets, ..Cookies

"""
    Handler

Abstract type for the handler interface that exists for documentation purposes.
A `Handler` is any function of the form `f(req::HTTP.Request) -> HTTP.Response`.
There is no requirement to subtype `Handler` and users should not rely on or dispatch
on `Handler`. A `Handler` function `f` can be passed to [`HTTP.serve(f, ...)`](@ref)
wherein a server will pass each incoming request to `f` to be handled and a response
to be returned. Handler functions are also the inputs to [`Middleware`](@ref) functions
which are functions of the form `f(::Handler) -> Handler`, i.e. they take a `Handler`
function as input, and return a "modified" or enhanced `Handler` function.

For advanced cases, a `Handler` function can also be of the form `f(stream::HTTP.Stream) -> Nothing`.
In this case, the server would be run like `HTTP.serve(f, ...; stream=true)`. For this use-case,
the handler function reads the request and writes the response to the stream directly. Note that
any middleware used with a stream handler also needs to be of the form `f(stream_handler) -> stream_handler`,
i.e. it needs to accept a stream `Handler` function and return a stream `Handler` function.
"""
abstract type Handler end

"""
    Middleware

Abstract type for the middleware interface that exists for documentation purposes.
A `Middleware` is any function of the form `f(::Handler) -> Handler` (ref: [`Handler`](@ref)).
There is no requirement to subtype `Middleware` and users should not rely on or dispatch
on the `Middleware` type. While `HTTP.serve(f, ...)` requires a _handler_ function `f` to be
passed, middleware can be "stacked" to create a chain of functions that are called in sequence,
like `HTTP.serve(base_handler |> cookie_middleware |> auth_middlware, ...)`, where the
`base_handler` `Handler` function is passed to `cookie_middleware`, which takes the handler
and returns a "modified" handler (that parses and stores cookies). This "modified" handler is
then an input to the `auth_middlware`, which further enhances/modifies the handler.
"""
abstract type Middleware end

"""
    streamhandler(request_handler) -> stream handler

Middleware that takes a request handler and returns a stream handler. Used by default
in `HTTP.serve` to take the user-provided request handler and process the `Stream`
from `HTTP.listen` and pass the parsed `Request` to the handler.

Is included by default in `HTTP.serve` as the base "middleware" when `stream=false` is passed.
"""
function streamhandler(handler)
    return function(stream::Stream)
        request::Request = stream.message
        request.body = read(stream)
        closeread(stream)
        request.response::Response = handler(request)
        request.response.request = request
        startwrite(stream)
        write(stream, request.response.body)
        return
    end
end

"""
    HTTP.serve(f, host, port; stream::Bool=false, kw...)

Start a server on the given host and port; for each incoming request, call the
given handler function `f`, which should be of the form `f(req::HTTP.Request) -> HTTP.Response`.
If `stream` is true, the handler function should be of the form `f(stream::HTTP.Stream) -> Nothing`.
Accepts all the same keyword arguments (and passes them along) to [`HTTP.listen`](@ref), including:
  * `sslconfig`: custom `SSLConfig` to support ssl connections
  * `tcpisvalid`: custom function to validate tcp connections
  * `server`: a server `Socket` that a user can manage (closing listening, etc.)
  * `reuseaddr`: whether another server can listen on the same host/port (unix only)
  * `max_connections`: max number of simultaneous connections allowed
  * `connection_count`: a `Ref{Int}` to keep track of currently open connections
  * `readtimeout`: time in seconds (integer) that the server should wait for a request to be sent
"""
function serve(f, host=Sockets.localhost, port=8081; stream::Bool=false, kw...)
    return Servers.listen(stream ? f : streamhandler(f), host, port; kw...)
end

# tree-based router handler
mutable struct Variable
    name::String
    pattern::Union{Nothing, Regex}
end

const VARREGEX = r"^{([[:alnum:]]+):?(.*)}$"

function Variable(pattern)
    re = match(VARREGEX, pattern)
    if re === nothing
        error("problem parsing path variable for route: `$pattern`")
    end
    pat = re.captures[2]
    return Variable(re.captures[1], pat == "" ? nothing : Regex(pat))
end

struct Leaf
    method::String
    variables::Vector{Tuple{Int, String}}
    path::String
    handler::Any
end

Base.show(io::IO, x::Leaf) = print(io, "Leaf($(x.method))")

export Node
mutable struct Node
    segment::Union{String, Variable}
    exact::Vector{Node} # sorted alphabetically, all x.segment are String
    conditional::Vector{Node} # unsorted; will be applied in source-order; all x.segment are Regex
    wildcard::Union{Node, Nothing} # unconditional variable or wildcard
    doublestar::Union{Node, Nothing} # /** to match any length of path; must be final segment
    methods::Vector{Leaf}
end

Base.show(io::IO, x::Node) = print(io, "Node($(x.segment))")

isvariable(x) = startswith(x, "{") && endswith(x, "}")
segment(x) = segment == "*" ? String(segment) : isvariable(x) ? Variable(x) : String(x)

Node(x) = Node(x, Node[], Node[], nothing, nothing, Leaf[])
Node() = Node("*")

function find(y, itr; by=identity, eq=(==))
    for (i, x) in enumerate(itr)
        eq(by(x), y) && return i
    end
    return nothing
end

function Base.insert!(node::Node, leaf, segments, i)
    if i > length(segments)
        # time to insert leaf method match node
        j = find(leaf.method, node.methods; by=x->x.method, eq=(x, y) -> x == "*" || x == y)
        if j === nothing
            push!(node.methods, leaf)
        else
            # hmmm, we've seen this route before, warn that we're replacing
            @warn "replacing existing registered route; $(node.methods[j].method) => \"$(node.methods[j].path)\" route with new path = \"$(leaf.path)\""
            node.methods[j] = leaf
        end
        return
    end
    segment = segments[i]
    # @show segment, segment isa Variable
    if segment isa Variable
        # if we're inserting a variable segment, add variable name to leaf vars array
        push!(leaf.variables, (i, segment.name))
    end
    # figure out which kind of node this segment is
    if segment == "*" || (segment isa Variable && segment.pattern === nothing)
        # wildcard node
        if node.wildcard === nothing
            node.wildcard = Node(segment)
        end
        return insert!(node.wildcard, leaf, segments, i + 1)
    elseif segment == "**"
        # double-star node
        if node.doublestar === nothing
            node.doublestar = Node(segment)
        end
        if i < length(segments)
            error("/** double wildcard must be last segment in path")
        end
        return insert!(node.doublestar, leaf, segments, i + 1)
    elseif segment isa Variable
        # conditional node
        # check if we've seen this exact conditional segment before
        j = find(segment.pattern, node.conditional; by=x->x.segment.pattern)
        if j === nothing
            # new pattern
            n = Node(segment)
            push!(node.conditional, n)
        else
            n = node.conditional[j]
        end
        return insert!(n, leaf, segments, i + 1)
    else
        # exact node
        @assert segment isa String
        j = find(segment, node.exact; by=x->x.segment)
        if j === nothing
            # new exact match segment
            n = Node(segment)
            push!(node.exact, n)
            sort!(node.exact; by=x->x.segment)
            return insert!(n, leaf, segments, i + 1)
        else
            # existing exact match segment
            return insert!(node.exact[j], leaf, segments, i + 1)
        end
    end
end

function Base.match(node::Node, params, method, segments, i)
    # @show node.segment, i, segments
    if i > length(segments)
        if isempty(node.methods)
            return nothing
        end
        j = find(method, node.methods; by=x->x.method, eq=(x, y) -> x == "*" || x == y)
        if j === nothing
            # we return missing here so we can return a 405 instead of 404
            # i.e. we matched the route, but there wasn't a matching method
            return missing
        else
            leaf = node.methods[j]
            # @show leaf.variables, segments
            if !isempty(leaf.variables)
                # we have variables to fill in
                for (i, v) in leaf.variables
                    params[v] = segments[i]
                end
            end
            return leaf.handler
        end
    end
    segment = segments[i]
    anymissing = false
    # first check for exact matches
    j = find(segment, node.exact; by=x->x.segment)
    if j !== nothing
        # found an exact match, recurse
        m = match(node.exact[j], params, method, segments, i + 1)
        anymissing = m === missing
        m = coalesce(m, nothing)
        # @show :exact, m
        if m !== nothing
            return m
        end
    end
    # check for conditional matches
    for node in node.conditional
        # @show node.segment.pattern, segment
        if match(node.segment.pattern, segment) !== nothing
            # matched a conditional node, recurse
            m = match(node, params, method, segments, i + 1)
            anymissing = m === missing
            m = coalesce(m, nothing)
            if m !== nothing
                return m
            end
        end
    end
    if node.wildcard !== nothing
        m = match(node.wildcard, params, method, segments, i + 1)
        anymissing = m === missing
        m = coalesce(m, nothing)
        if m !== nothing
            return m
        end
    end
    if node.doublestar !== nothing
        m = match(node.doublestar, params, method, segments, length(segments) + 1)
        anymissing = m === missing
        m = coalesce(m, nothing)
        if m !== nothing
            return m
        end
    end
    return anymissing ? missing : nothing
end

"""
    HTTP.Router(_404, _405)

Define a router object that maps incoming requests by path to registered routes and
associated handlers. Paths can be registered using [`HTTP.register!`](@ref). The router
object itself is a "request handler" that can be called like:
```
r = HTTP.Router()
resp = r(reqest)
```

Which will inspect the `request`, find the matching, registered handler from the url,
and pass the request on to be handled further.

See [`HTTP.register!`](@ref) for additional information on registering handlers based on routes.

If a request doesn't have a matching, registered handler, the `_404` handler is called which,
by default, returns a `HTTP.Response(404)`. If a route matches the path, but not the method/verb
(e.g. there's a registerd route for "GET /api", but the request is "POST /api"), then the `_405`
handler is called, which by default returns `HTTP.Response(405)` (method not allowed).
"""
struct Router{T, S}
    _404::T
    _405::S
    routes::Node
end

default404(::Request) = Response(404)
default405(::Request) = Response(405)
default404(s::Stream) = setstatus(s, 404)
default405(s::Stream) = setstatus(s, 405)

Router(_404=default404, _405=default405) = Router(_404, _405, Node())

"""
    HTTP.register!(r::Router, method, path, handler)
    HTTP.register!(r::Router, path, handler)

Register a handler function that should be called when an incoming request matches `path`
and the optionally provided `method` (if not provided, any method is allowed). Can be used
to dynamically register routes.
The following path types are allowed for matching:
  * `/api/widgets`: exact match of static strings
  * `/api/*/owner`: single `*` to wildcard match anything for a single segment
  * `/api/widget/{id}`: Define a path variable `id` that matches any valued provided for this segment; path variables are available in the request context like `HTTP.getparams(req)["id"]`
  * `/api/widget/{id:[0-9]+}`: Define a path variable `id` that does a regex match for integers for this segment
  * `/api/**`: double wildcard matches any number of trailing segments in the request path; the double wildcard must be the last segment in the path
"""
function register! end

function register!(r::Router, method, path, handler)
    segments = map(segment, split(path, '/'; keepempty=false))
    insert!(r.routes, Leaf(method, Tuple{Int, String}[], path, handler), segments, 1)
    return
end

register!(r::Router, path, handler) = register!(r, "*", path, handler)

const Params = Dict{String, String}

function gethandler(r::Router, req::Request)
    url = URI(req.target)
    segments = split(url.path, '/'; keepempty=false)
    params = Params()
    handler = match(r.routes, params, req.method, segments, 1)
    return handler, params
end

function (r::Router)(stream::Stream{<:Request})
    req = stream.message
    handler, params = gethandler(r, req)
    if handler === nothing
        # didn't match a registered route
        return r._404(stream)
    elseif handler === missing
        # matched the path, but method not supported
        return r._405(stream)
    else
        if !isempty(params)
            req.context[:params] = params
        end
        return handler(stream)
    end
end

function (r::Router)(req::Request)
    handler, params = gethandler(r, req)
    if handler === nothing
        # didn't match a registered route
        return r._404(req)
    elseif handler === missing
        # matched the path, but method not supported
        return r._405(req)
    else
        if !isempty(params)
            req.context[:params] = params
        end
        return handler(req)
    end
end

"""
    HTTP.getparams(req) -> Dict{String, String}

Retrieve any matched path parameters from the request context.
If a path was registered with a router via `HTTP.register!` like
"/api/widget/{id}", then the path parameters are available in the request context
and can be retrieved like `id = HTTP.getparams(req)["id"]`.
"""
getparams(req) = get(req.context, :params, nothing)

"""
    HTTP.Handlers.cookie_middleware(handler) -> handler

Middleware that parses and stores any cookies in the incoming
request in the request context. Cookies can then be retrieved by calling
[`HTTP.getcookies(req)`](@ref) in subsequent middlewares/handlers.
"""
function cookie_middleware(handler)
    function (req)
        if !haskey(req.context, :cookies)
            req.context[:cookies] = Cookies.cookies(req)
        end
        return handler(req)
    end
end

"""
    HTTP.getcookies(req) -> Vector{Cookie}

Retrieve any parsed cookies from a request context. Cookies
are expected to be stored in the `req.context[:cookies]` of the
request context as implemented in the [`HTTP.Handlers.cookie_middleware`](@ref)
middleware.
"""
getcookies(req) = get(() => Cookie[], req.context, :cookies)

end # module
