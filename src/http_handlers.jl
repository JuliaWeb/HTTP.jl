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
import ..Cookies
import ..BytesBody
import ..EmptyBody
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
import ..peeraddr
import .._stream_error_status
import ..@_spawn_interactive
import ..@try_ignore

using Logging: Logging, AbstractLogger, LogLevel, with_logger, @logmsg

"""
    Handler

The name of the handler interface. Nothing subtypes or dispatches on it.

A handler is a function `f(req::HTTP.Request) -> HTTP.Response`, run with
`serve!`. A stream handler is a function `f(stream::HTTP.Stream)`, run with
`listen!`. Middleware used with stream handlers must take and return stream
handlers.
"""
abstract type Handler end

"""
    Middleware

The name of the middleware interface. Nothing subtypes or dispatches on it.
Middleware is a function that takes a [`Handler`](@ref) and returns a new one.
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

function _route_variable_matches(pattern::Regex, segment::AbstractString)
    m = Base.match(pattern, segment)
    return m !== nothing && m.match == segment
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

# `@nospecialize`: the trie code is the same for every handler type, so it is
# compiled once rather than for each route's handler.
function insert!(node::Node, @nospecialize(leaf::Leaf), segments, i)
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
        if _route_variable_matches(conditional_node.segment.pattern, segment_value)
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
    HTTP.Router([_404], [_405], [middleware])

A handler that calls the handler [`register!`](@ref)ed for the request's method
and path. `_404` handles a path with no route, and `_405` a path whose routes
do not accept the method; by default they return empty 404 and 405 responses.
`middleware`, if given, wraps each handler as it is registered. A router works
with request handlers (`serve!`) and with stream handlers (`listen!`).

A route path is made of segments:

- exact segments, such as `/users`
- variables, such as `/users/{id}`
- variables with a regular expression, such as `/files/{name:\\w+}`
- `*`, which matches any one segment
- `**` at the end, which matches the rest of the path

A handler reads the matched route with [`getroute`](@ref) and its variables with
[`getparams`](@ref) and [`getparam`](@ref).
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

Add a route to `router`: requests with `method` and a path matching `path` go to
`handler`. Without `method`, the route accepts every method. See
[`Router`](@ref) for the path syntax.

The handler-first forms allow `do` blocks:

```julia
HTTP.register!(router, "GET", "/users/{id}") do req
    return HTTP.Response(200; body = HTTP.getparam(req, "id"))
end
```
"""
function register! end

# `handler::F` makes Julia compile `register!` for each handler type. Julia does
# not otherwise specialize on a function it only passes along, and the
# middleware and `Leaf` calls below would be dynamically dispatched.
function register!(r::Router, method, path, handler::F) where {F}
    wrapped = r.middleware === nothing ? handler : r.middleware(handler)
    _insert_route!(r.routes, Leaf(method, Tuple{Int,String}[], path, wrapped))
    return nothing
end

function _insert_route!(routes::Node, @nospecialize(leaf::Leaf))
    segments = Union{String,Variable}[segment(part) for part in split(leaf.path, '/'; keepempty=false)]
    insert!(routes, leaf, segments, 1)
    return nothing
end

register!(r::Router, path, handler::F) where {F} = register!(r, "*", path, handler)

register!(handler::F, r::Router, method, path) where {F} = register!(r, method, path, handler)
register!(handler::F, r::Router, path) where {F} = register!(r, "*", path, handler)

"""
    HTTP.Handlers.static_dispatch(middleware=nothing)

Router middleware for natively compiled servers (`juliac --trim=safe`). Pass it
as the third argument of [`Router`](@ref). It wraps each handler with
`middleware`, when given, and then compiles a direct call to the wrapped handler
for each request type that [`serve!`](@ref) passes to handlers. A plain router
calls its handlers through dynamic dispatch, which a trimmed executable cannot do.

```julia
router = HTTP.Router(HTTP.Handlers.default404, HTTP.Handlers.default405,
    HTTP.Handlers.static_dispatch(auth_middleware))
```

Registering a route compiles its handler for both request body types, so
startup takes longer than with a plain router, which compiles a handler on its
first request. The router keeps a function pointer for each handler, and
pointers do not survive precompilation: register routes at run time, not at the
top level of a package. Such a router serves `serve!` requests only, not
`listen!` streams. Other request types, such as a `Request` built in a test, go
through ordinary dispatch.
"""
static_dispatch(middleware=nothing) = _StaticDispatch(middleware)

struct _StaticDispatch{M}
    middleware::M
end

(s::_StaticDispatch)(handler::F) where {F} = _HandlerFn(s.middleware === nothing ? handler : s.middleware(handler))

# One request crossing the function-pointer call below. Its fields are concrete
# for each request type, so the pointer's signature has no `Any` argument.
mutable struct _HandlerCall{R}
    request::R
    response::Any
end

struct _CallHandler{R} <: Function end

function (::_CallHandler{R})(handler::H, callptr::Ptr{Cvoid}) where {R,H}
    call = unsafe_pointer_to_objref(callptr)::_HandlerCall{R}
    call.response = handler(call.request)
    return nothing
end

@generated function _handler_fptr(::Type{H}, ::Type{R}) where {H,R}
    return quote
        @cfunction($(_CallHandler{R}()), Cvoid, (Ref{$H}, Ptr{Cvoid}))
    end
end

# A handler behind compiled function pointers, one for each request type that
# `serve!` passes to handlers. The trim verifier accepts a `ccall` through
# these pointers, while a call to a handler of unknown type is dynamic dispatch.
struct _HandlerFn
    handler::Any
    root::Any              # Base.RefValue holding the handler; the pointer below points into it
    root_address::Ptr{Cvoid}
    handler_ptr::Ptr{Cvoid}
    empty_ptr::Ptr{Cvoid}  # for Request{EmptyBody}
    bytes_ptr::Ptr{Cvoid}  # for Request{BytesBody{Vector{UInt8}}}
end

function _HandlerFn(handler::H) where {H}
    root = Base.cconvert(Ref{H}, handler)
    return _HandlerFn(
        handler,
        root,
        pointer_from_objref(root),
        Ptr{Cvoid}(Base.unsafe_convert(Ref{H}, root)),
        _handler_fptr(H, Request{EmptyBody}),
        _handler_fptr(H, Request{BytesBody{Vector{UInt8}}}),
    )
end

function _call_handler_fn(h::_HandlerFn, fptr::Ptr{Cvoid}, req::R) where {R}
    # A handler stored in a precompiled image comes back at a new address, with
    # function pointers from the process that built the image.
    pointer_from_objref(h.root) == h.root_address ||
        throw(ArgumentError("route registered during precompilation; register static_dispatch routes at run time"))
    call = _HandlerCall{R}(req, nothing)
    GC.@preserve h call begin
        ccall(fptr, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), h.handler_ptr, pointer_from_objref(call))
    end
    return call.response
end

(h::_HandlerFn)(req::Request{EmptyBody}) = _call_handler_fn(h, h.empty_ptr, req)
(h::_HandlerFn)(req::Request{BytesBody{Vector{UInt8}}}) = _call_handler_fn(h, h.bytes_ptr, req)
(h::_HandlerFn)(req) = h.handler(req)
# `serve!` also compiles its stream-handler path, so a stream must not reach
# ordinary dispatch here.
(::_HandlerFn)(::Stream) = throw(ArgumentError("a static_dispatch router handles serve! requests, not listen! streams"))

_route_handler(::Router, handler) = handler
_route_handler(::Router{T,S,<:_StaticDispatch}, handler) where {T,S} = handler::_HandlerFn

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
    return _route_handler(r, handler)(stream)
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
    return _route_handler(r, handler)(req)
end

"""
    HTTP.getroute(req) -> Union{Nothing, String}

Return the registered path, such as `"/users/{id}"`, of the route that matched
`req`, or `nothing`.
"""
getroute(req) = get(req.context, :route, nothing)::Union{Nothing,String}

"""
    HTTP.getparams(req) -> Union{Nothing, Dict{String, String}}

Return the path variables of the route that matched `req`, or `nothing` when no
route matched or it has no variables.
"""
getparams(req) = get(req.context, :params, nothing)::Union{Nothing,Params}

"""
    HTTP.getparam(req, name, default=nothing)

Return the path variable `name` of the route that matched `req`, or `default`.
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

struct _LoggingMiddleware{H,L}
    handler::H
    logger::L
    level::LogLevel
end

"""
    logging_middleware(handler; logger=nothing, level=Logging.Info) -> handler

Wrap `handler` so that each request it handles logs one record, an access log.

The message reads like `GET /users/1 200 0.412ms`. The record has the request
`method` and `target`, the response `status`, the handler's time in
`elapsed_ms`, and the response body `length` in bytes when it is known without
reading the body (`nothing` otherwise). Records are in the `:access` log group
and logged at `level`, to `logger` when given and to the current logger
otherwise. When the handler throws, the record is logged at `Logging.Error`
with the exception and the status the server sends, and the exception is
rethrown.

It wraps request handlers and stream handlers. Stream handler records also have
the client's `peer` address from [`peeraddr`](@ref). For a stream handler, the
middleware finishes the response (`closewrite`) before logging, so a response
that fails then, such as a body shorter than its `Content-Length`, is logged as
that failure.

```julia
server = HTTP.serve!(HTTP.Handlers.logging_middleware(router), "127.0.0.1", 8080)
```
"""
function logging_middleware(
    handler;
    logger::Union{Nothing,AbstractLogger}=nothing,
    level::LogLevel=Logging.Info,
)
    return _LoggingMiddleware(handler, logger, level)
end

@inline _with_access_logger(f::F, ::Nothing) where {F} = f()
@inline _with_access_logger(f::F, logger::AbstractLogger) where {F} = with_logger(f, logger)

# The server answers 500 when a request handler returns anything but a
# `Response`, so the record reports the status that reaches the client.
@inline _access_status(response::Response)::Int = response.status
@inline _access_status(@nospecialize(::Any))::Int = 500
@inline _access_length(response::Response)::Union{Nothing,Int64} = response.content_length >= 0 ? response.content_length : nothing
@inline _access_length(@nospecialize(::Any))::Union{Nothing,Int64} = nothing

@inline function _access_stream_status(stream::Stream)::Int
    response = stream.response
    return response === nothing ? 0 : response.status
end

function _log_access(
    middleware::_LoggingMiddleware,
    level::LogLevel,
    method::String,
    target::String,
    status::Int,
    body_length::Union{Nothing,Int64},
    start_ns::UInt64,
    extra::NamedTuple,
)::Nothing
    elapsed_ms = round((time_ns() - start_ns) / 1.0e6; digits=3)
    _with_access_logger(middleware.logger) do
        @logmsg level "$method $target $status $(elapsed_ms)ms" method target status elapsed_ms length = body_length extra... _group = :access
        return nothing
    end
    return nothing
end

function (middleware::_LoggingMiddleware)(req::Request)
    start_ns = time_ns()
    response = try
        middleware.handler(req)
    catch err
        # The server answers 500 for any error a request handler throws.
        _log_access(
            middleware, Logging.Error, req.method, req.target, 500, nothing, start_ns,
            (; exception=(err, catch_backtrace())),
        )
        rethrow()
    end
    _log_access(
        middleware, middleware.level, req.method, req.target, _access_status(response), _access_length(response), start_ns,
        (;),
    )
    return response
end

function (middleware::_LoggingMiddleware)(stream::Stream)
    start_ns = time_ns()
    request = startread(stream)
    peer = peeraddr(stream)
    try
        middleware.handler(stream)
        # Finish the response first, so the record shows what the client got,
        # such as a 500 for a body shorter than its Content-Length.
        closewrite(stream)
    catch err
        # A committed head keeps its status, including transport failures that
        # may have sent part of it. Before commitment the server can still send
        # an error status; fixed-length h1 heads can be deferred until
        # closewrite.
        status = (@atomic :acquire stream.head_committed) ? _access_stream_status(stream) : _stream_error_status(stream, err)
        _log_access(
            middleware, Logging.Error, request.method, request.target, status, stream.written_bytes, start_ns,
            (; peer=peer, exception=(err, catch_backtrace())),
        )
        rethrow()
    end
    _log_access(
        middleware, middleware.level, request.method, request.target, _access_stream_status(stream), stream.written_bytes, start_ns,
        (; peer=peer),
    )
    return nothing
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
    now_ns = Int64(time_ns())
    deadline_ns = middleware.timeout_ns > typemax(Int64) - now_ns ? typemax(Int64) : now_ns + middleware.timeout_ns
    # Wait on a poller timer that fires at the deadline; the handler task
    # re-arms it for now when it finishes. The superseded deadline entry can
    # stay in the poller's timer heap until that deadline.
    timer = IOPoll.TimerState(deadline_ns, Int64(0))
    armed = IOPoll.schedule_timer!(timer, deadline_ns)
    @_spawn_interactive begin
        try
            put!(result, (true, middleware.handler(timed_req)))
        catch err
            put!(result, (false, err))
        end
        # Re-arming the timer for now wakes the waiting task early.
        armed && IOPoll.schedule_timer!(timer, Int64(time_ns()))
        return nothing
    end
    # An unarmed timer means the poller has stopped, so nothing would wake us.
    armed ? IOPoll.waittimer(timer) : wait(result)
    if isready(result)
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

Return middleware that answers with `status`, `body`, and `content_type` when a
request handler takes longer than `timeout_s` seconds. The handler runs with a
child [`RequestContext`](@ref) whose deadline is the earlier of the timeout and
the request's own deadline. At the timeout that context is canceled, but the
handler keeps running until it returns or checks the context. Only request
handlers are supported.
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

Return the cookies in the `Cookie` header of `req`.
"""
getcookies(req) = get(() -> Cookies.cookies(req), req.context, :cookies)

# `handlertimeout`, `logging_middleware` and `static_dispatch` are documented
# public API but not exported; mark them public on Julia versions that support
# the mechanism (the source stays parseable on 1.10).
@static if Base.VERSION >= v"1.11.0-DEV.469"
    Core.eval(@__MODULE__, Expr(:public, :handlertimeout, :logging_middleware, :static_dispatch))
end

end
