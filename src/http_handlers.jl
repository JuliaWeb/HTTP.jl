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
export streamhandler
export Node

import ..Request
import ..RequestContext
import ..Response
import ..Stream
import ..Cookie
import ..Cookies
import ..BytesBody
import ..Headers
import ..setstatus
import ..setheader
import ..startread
import ..serve
import ..serve!
import ..streamhandler
import ..IOPoll
import ..cancel!
import ..canceled
import ..body_close!
import ..get_request_context
import .._request_with_context
import ..@try_ignore

"""
    Handler

Abstract type for the handler interface that exists for documentation purposes.
A `Handler` is any function of the form `f(req::HTTP.Request) -> HTTP.Response`.
There is no requirement to subtype `Handler` and users should not rely on or
dispatch on `Handler`.

For advanced cases, a `Handler` function can also be of the form
`f(stream::HTTP.Stream) -> Nothing`. In this case, the server would be run like
`HTTP.listen(f, ...)`. Any middleware used with a stream handler
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
    HTTP.Handlers.Router([_404], [_405], [middleware])
    HTTP.Router([_404], [_405], [middleware])

Define a router object that maps incoming requests by path to registered routes
and associated handlers.

Routes are matched by method and path segments. Supported segment patterns are:

- exact segments, such as `/users`
- named variables, such as `/users/{id}`
- named variables with regular expressions, such as `/files/{name:\\w+}`
- single-segment wildcards with `*`
- trailing multi-segment wildcards with `**`

Matched route metadata is stored on the request context and can be read with
[`getroute`](@ref), [`getparams`](@ref), and [`getparam`](@ref).
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
    register!(handler, router, method, path) -> Nothing
    register!(handler, router, path) -> Nothing

Register a new route in `router`.

The `path` may include named path variables like `/{id}` or wildcard segments.
The 3-argument form registers the handler for all methods.

`handler` may be a `Request -> Response` handler for `serve!` or a
`Stream -> Nothing` handler for `listen!`, as long as the router is used with
the matching server entrypoint.

The handler-first forms accept the handler as the first positional argument so
that `do`-block syntax may be used:

```julia
register!(router, "GET", "/users/{id}") do req
    return HTTP.Response(200; body = HTTP.Handlers.getparam(req, "id"))
end
```
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

register!(handler, r::Router, method, path) = register!(r, method, path, handler)
register!(handler, r::Router, path) = register!(r, "*", path, handler)

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

Returns `nothing` when the request has not been routed or the route contained
no path variables.
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

mutable struct _HandlerTimeoutMiddleware{H}
    handler::H
    timeout_ns::Int64
    status::Int
    response_body::Vector{UInt8}
    content_type::String
end

function _timeout_child_context(parent::RequestContext, timeout_ns::Int64)::RequestContext
    now = Int64(time_ns())
    child_deadline = timeout_ns <= 0 ? Int64(0) : (now + timeout_ns)
    parent_deadline = parent.deadline_ns
    if parent_deadline > 0
        child_deadline = child_deadline > 0 ? min(child_deadline, parent_deadline) : parent_deadline
    end
    child = RequestContext(; deadline_ns=child_deadline)
    if parent.metadata !== nothing
        child.metadata = copy(parent.metadata)
    end
    if canceled(parent)
        cancel!(child; message=parent.cancel_message === nothing ? "request canceled" : parent.cancel_message::String)
    end
    return child
end

function _handler_timeout_response(
    request::Request,
    middleware::_HandlerTimeoutMiddleware,
)::Response
    headers = Headers()
    setheader(headers, "Content-Type", middleware.content_type)
    body_bytes = copy(middleware.response_body)
    return Response(
        middleware.status,
        BytesBody(body_bytes);
        headers=headers,
        content_length=length(body_bytes),
        proto_major=Int(request.proto_major),
        proto_minor=Int(request.proto_minor),
        request=request,
    )
end

function (middleware::_HandlerTimeoutMiddleware)(req::Request)
    derived_ctx = _timeout_child_context(get_request_context(req), middleware.timeout_ns)
    timed_req = _request_with_context(req, derived_ctx)
    result = Channel{Tuple{Bool,Any}}(1)
    Threads.@spawn begin
        try
            put!(result, (true, middleware.handler(timed_req)))
        catch err
            put!(result, (false, err))
        end
        return nothing
    end
    timeout_s = middleware.timeout_ns / 1.0e9
    status = IOPoll.timedwait(() -> isready(result), timeout_s; pollint=0.001)
    if status == :ok
        success, value = take!(result)
        success && return value
        throw(value)
    end
    cancel!(derived_ctx; message="handler timed out")
    @try_ignore begin
        body_close!(timed_req.body)
    end
    return _handler_timeout_response(req, middleware)
end

function (middleware::_HandlerTimeoutMiddleware)(::Stream)
    throw(ArgumentError("handlertimeout only supports request handlers"))
end

"""
    handlertimeout(timeout_s; status=503, body="handler timed out", content_type="text/plain; charset=utf-8")
        -> middleware

Wrap a request handler with a wall-clock timeout and synthesize a timeout
response when the handler does not finish in time.

The wrapped handler receives a child `RequestContext` whose deadline is bounded
by both the configured timeout and any existing parent request deadline. On
timeout, the child context is canceled and a response with `status`, `body`,
and `content_type` is returned.
"""
function handlertimeout(
    timeout_s::Real;
    status::Integer=503,
    body::Union{AbstractString,AbstractVector{UInt8}}="handler timed out",
    content_type::AbstractString="text/plain; charset=utf-8",
)
    timeout_s > 0 || throw(ArgumentError("timeout_s must be > 0"))
    status >= 0 || throw(ArgumentError("status must be >= 0"))
    timeout_ns = round(Int64, timeout_s * 1.0e9)
    timeout_ns > 0 || throw(ArgumentError("timeout_s must be > 0"))
    response_body = body isa AbstractString ? Vector{UInt8}(codeunits(String(body))) : Vector{UInt8}(body)
    return handler -> _HandlerTimeoutMiddleware(handler, timeout_ns, Int(status), response_body, String(content_type))
end

"""
    HTTP.getcookies(req) -> Vector{Cookie}

Retrieve any parsed cookies from a request context.
"""
getcookies(req) = get(() -> Cookie[], req.context, :cookies)

end
