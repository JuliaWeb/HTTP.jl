module Handlers

export Handler
export Middleware
export serve
export serve!
export Router
export register!
export getroute
export getparams
export getparam
export getcookies

import ..Request
import ..Response
import ..Stream
import ..Cookie
import ..Cookies
import ..setstatus
import ..startread
import ..serve
import ..serve!

"""
    Handler

Abstract type for the handler interface that exists for documentation purposes.
A `Handler` is any function of the form `f(req::HTTP.Request) -> HTTP.Response`.
There is no requirement to subtype `Handler` and users should not rely on or
dispatch on `Handler`.

For advanced cases, a `Handler` function can also be of the form
`f(stream::HTTP.Stream) -> Nothing`. In this case, the server would be run like
`HTTP.serve(f, ...; stream=true)`. Any middleware used with a stream handler
also needs to accept and return a stream handler.
"""
abstract type Handler end

"""
    Middleware

Abstract type for the middleware interface that exists for documentation
purposes. A `Middleware` is any function of the form `f(::Handler) -> Handler`.
There is no requirement to subtype `Middleware` and users should not rely on or
dispatch on `Middleware`.
"""
abstract type Middleware end

mutable struct Variable
    name::String
    pattern::Union{Nothing,Regex}
end

const VARREGEX = r"^{([^:{}]+)(?::(.*))?}$"

function Variable(pattern)
    re = Base.match(VARREGEX, pattern)
    re === nothing && error("problem parsing path variable for route: `$pattern`")
    pat = re.captures[2]
    return Variable(re.captures[1], pat === nothing ? nothing : Regex(pat))
end

struct Leaf{H}
    method::String
    variables::Vector{Tuple{Int,String}}
    path::String
    handler::H
end

Base.show(io::IO, x::Leaf) = print(io, "Leaf($(x.method))")

"""
    Node

Internal trie node used by `Router` to store exact, wildcard, and parameterized
path segments.
"""
mutable struct Node
    segment::Union{String,Variable}
    exact::Vector{Node}
    conditional::Vector{Node}
    wildcard::Union{Node,Nothing}
    doublestar::Union{Node,Nothing}
    methods::Vector{Leaf}
end

Base.show(io::IO, x::Node) = print(io, "Node($(x.segment))")

isvariable(x) = startswith(x, "{") && endswith(x, "}")
segment(x) = isvariable(x) ? Variable(x) : String(x)

Node(x) = Node(x, Node[], Node[], nothing, nothing, Leaf[])
Node() = Node("*")

function find(y, itr; by=identity, eq=(==))
    for (i, x) in enumerate(itr)
        eq(by(x), y) && return i
    end
    return nothing
end

function insert!(node::Node, leaf, segments, i)
    if i > length(segments)
        j = find(leaf.method, node.methods; by=x -> x.method, eq=(x, y) -> x == "*" || x == y)
        if j === nothing
            push!(node.methods, leaf)
        else
            @warn "replacing existing registered route; $(node.methods[j].method) => \"$(node.methods[j].path)\" route with new path = \"$(leaf.path)\""
            node.methods[j] = leaf
        end
        return nothing
    end
    segment_value = segments[i]
    if segment_value isa Variable
        push!(leaf.variables, (i, segment_value.name))
    end
    if segment_value == "*" || (segment_value isa Variable && segment_value.pattern === nothing)
        if node.wildcard === nothing
            node.wildcard = Node(segment_value)
        end
        return insert!(node.wildcard::Node, leaf, segments, i + 1)
    elseif segment_value == "**"
        if node.doublestar === nothing
            node.doublestar = Node(segment_value)
        end
        i < length(segments) && error("/** double wildcard must be last segment in path")
        return insert!(node.doublestar::Node, leaf, segments, i + 1)
    elseif segment_value isa Variable
        j = find(segment_value.pattern, node.conditional; by=x -> x.segment.pattern)
        if j === nothing
            n = Node(segment_value)
            push!(node.conditional, n)
        else
            n = node.conditional[j]
        end
        return insert!(n, leaf, segments, i + 1)
    else
        j = find(segment_value, node.exact; by=x -> x.segment)
        if j === nothing
            n = Node(segment_value)
            push!(node.exact, n)
            sort!(node.exact; by=x -> x.segment)
            return insert!(n, leaf, segments, i + 1)
        end
        return insert!(node.exact[j], leaf, segments, i + 1)
    end
end

function match(node::Node, method, segments, i)
    if i > length(segments)
        isempty(node.methods) && return nothing
        j = find(method, node.methods; by=x -> x.method, eq=(x, y) -> x == "*" || x == y)
        return j === nothing ? missing : node.methods[j]
    end
    segment_value = segments[i]
    anymissing = false
    j = find(segment_value, node.exact; by=x -> x.segment)
    if j !== nothing
        m = match(node.exact[j], method, segments, i + 1)
        anymissing = m === missing
        m = coalesce(m, nothing)
        m !== nothing && return m
    end
    for conditional_node in node.conditional
        if Base.match(conditional_node.segment.pattern, segment_value) !== nothing
            m = match(conditional_node, method, segments, i + 1)
            anymissing = m === missing
            m = coalesce(m, nothing)
            m !== nothing && return m
        end
    end
    if node.wildcard !== nothing
        m = match(node.wildcard::Node, method, segments, i + 1)
        anymissing = m === missing
        m = coalesce(m, nothing)
        m !== nothing && return m
    end
    if node.doublestar !== nothing
        m = match(node.doublestar::Node, method, segments, length(segments) + 1)
        anymissing = m === missing
        m = coalesce(m, nothing)
        m !== nothing && return m
    end
    return anymissing ? missing : nothing
end

"""
    HTTP.Router(_404, _405, middleware=nothing)

Define a router object that maps incoming requests by path to registered routes
and associated handlers.
"""
struct Router{T,S,F}
    _404::T
    _405::S
    routes::Node
    middleware::F
end

default404(::Request) = Response(404)
default405(::Request) = Response(405)
default404(stream::Stream) = setstatus(stream, 404)
default405(stream::Stream) = setstatus(stream, 405)

Router(_404=default404, _405=default405, middleware=nothing) = Router(_404, _405, Node(), middleware)

"""
    register!(router, method, path, handler) -> Nothing
    register!(router, path, handler) -> Nothing

Register a new route in `router`.

The `path` may include named path variables like `/{id}` or wildcard segments.
The 3-argument form registers the handler for all methods.
"""
function register! end

function register!(r::Router, method, path, handler)
    segments = map(segment, split(path, '/'; keepempty=false))
    if r.middleware !== nothing
        handler = r.middleware(handler)
    end
    insert!(r.routes, Leaf(method, Tuple{Int,String}[], path, handler), segments, 1)
    return nothing
end

register!(r::Router, path, handler) = register!(r, "*", path, handler)

const Params = Dict{String,String}

@inline function _split_query_target(target::String)::String
    idx = findfirst(isequal('?'), target)
    idx === nothing && return target
    idx == firstindex(target) && return ""
    return String(SubString(target, firstindex(target), prevind(target, idx)))
end

function _router_request_path(target::String)::String
    isempty(target) && return "/"
    target == "*" && return target
    startswith(target, "/") && return _split_query_target(target)
    scheme_idx = findfirst("://", target)
    if scheme_idx === nothing
        return _split_query_target(target)
    end
    authority_start = last(scheme_idx) + 1
    authority_start > lastindex(target) && return "/"
    slash_idx = findnext(isequal('/'), target, authority_start)
    slash_idx === nothing && return "/"
    return _split_query_target(String(SubString(target, slash_idx, lastindex(target))))
end

function gethandler(r::Router, req::Request)
    segments = split(_router_request_path(req.target), '/'; keepempty=false)
    leaf = match(r.routes, req.method, segments, 1)
    params = Params()
    if leaf isa Leaf
        if !isempty(leaf.variables)
            for (i, v) in leaf.variables
                params[v] = segments[i]
            end
        end
        return leaf.handler, leaf.path, params
    end
    return leaf, "", params
end

function (r::Router)(stream::Stream)
    req = startread(stream)
    handler, route, params = gethandler(r, req)
    if handler === nothing
        return r._404(stream)
    elseif handler === missing
        return r._405(stream)
    end
    req.context[:route] = route
    isempty(params) || (req.context[:params] = params)
    return handler(stream)
end

function (r::Router)(req::Request)
    handler, route, params = gethandler(r, req)
    if handler === nothing
        return r._404(req)
    elseif handler === missing
        return r._405(req)
    end
    req.context[:route] = route
    isempty(params) || (req.context[:params] = params)
    return handler(req)
end

"""
    HTTP.getroute(req) -> Union{Nothing, String}

Retrieve the original route registration string for a request after its target
has been matched against a router.
"""
getroute(req) = get(req.context, :route, nothing)

"""
    HTTP.getparams(req) -> Union{Nothing, Dict{String, String}}

Retrieve any matched path parameters from the request context.
"""
getparams(req) = get(req.context, :params, nothing)

"""
    HTTP.getparam(req, name, default=nothing) -> Any

Retrieve a matched path parameter with name `name` from request context.
"""
function getparam(req, name, default=nothing)
    params = getparams(req)
    params === nothing && return default
    return get(params, name, default)
end

"""
    cookie_middleware(handler) -> handler

Middleware that parses and stores any cookies in the incoming request context.
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

Retrieve any parsed cookies from a request context.
"""
getcookies(req) = get(() -> Cookie[], req.context, :cookies)

end
