"""
The `HTTP.Handlers` module provides a middleware framework in conjuction with the `HTTP.Servers` server module.

The core interface function is:
```julia
handle(handler::Handler, request) => HTTP.Response
```

An http server is started by calling `HTTP.listen(handler::Union{Function, Handler}, ...)` and when a http request
is received, it is "handled" by the handler by calling `HTTP.handle(handler, request)`.

The `Handlers` framework is built to be extensible. It's very easy to chain handlers together to form a 
"middleware stack" of handler layers, or even define a custom handler type that could be re-used by others.

See `?HTTP.Servers` for an extended example of a server + custom handler framework usage
"""
module Handlers

export handle, Handler, RequestHandler, StreamHandler,
       RequestHandlerFunction, StreamHandlerFunction, Router,
       @register, register!

using ..Messages, ..URIs, ..Streams, ..IOExtras

"""
handle(handler::Handler, request) => Response

Function used to dispatch to a Handler. Called from the core HTTP.listen method with the
initial Handler passed to `HTTP.listen(handler, ...)`.
"""
function handle end

"""
Abstract type representing an object that knows how to "handle" an http request and return an appropriate
http response.

Types of builtin handlers provided by the HTTP package include:
  * `HTTP.RequestHandlerFunction`: a julia function of the form `f(request::HTTP.Request)`
  * `HTTP.Router`: pattern matches request url paths to be handled by registered `Handler`s
  * `HTTP.StreamHandlerFunction`: a julia function of the form `f(stream::HTTP.Stream)`
"""
abstract type Handler end

"""
Abstract type representing objects that handle `HTTP.Request` and return `HTTP.Response` objects.

See `?HTTP.RequestHandlerFunction` for an example of a concrete implementation.
"""
abstract type RequestHandler <: Handler end
"""
Abstract type representing objects that handle `HTTP.Stream` objects directly.

See `?HTTP.StreamHandlerFunction` for an example of a concrete implementation.
"""
abstract type StreamHandler <: Handler end

Handler(h::Handler) = h
"Given an arbitrary function, return an appropriate RequestHandlerFunction or StreamHandlerFunction; for
functions with an untyped argument, the default is RequestHandlerFunction."
function Handler(f::Base.Callable)
    req = applicable(f, Request())
    strm = applicable(f, Stream(Request(), IOBuffer()))
    if strm && !req
        h = StreamHandlerFunction(f)
    elseif req
        h = RequestHandlerFunction(f)
    else
        throw(ArgumentError("$f function doesn't take an HTTP.Request or HTTP.Stream argument"))
    end
    return h
end

"""
RequestHandlerFunction(f::Function)

A Function-wrapper type that is a subtype of `RequestHandler`. Takes a single Function as an argument.
The provided argument should be of the form `f(request) => Response`, i.e. it accepts a `Request` returns a `Response`.
"""
struct RequestHandlerFunction{F <: Base.Callable} <: RequestHandler
    func::F # func(req)
end
RequestHandlerFunction(f::RequestHandlerFunction) = f

"A default 404 Handler"
const FourOhFour = RequestHandlerFunction(req -> Response(404))

"For request handlers, read a full request from a stream, pass to the handler, then write out the response"
@inline function handle(h::RequestHandler, stream::Stream)
    request::Request = stream.message
    request.body = read(stream)
    request.response::Response = handle(h, request)
    request.response.request = request
    startwrite(stream)
    write(stream, request.response.body)
    return
end

handle(h::RequestHandlerFunction, req::Request) = h.func(req)

"""
StreamHandlerFunction(f::Function)

A Function-wrapper type that is a subtype of `StreamHandler`. Takes a single Function as an argument.
The provided argument should be of the form `f(stream) => Nothing`, i.e. it accepts a raw `HTTP.Stream`,
handles the incoming request, writes a response back out to the stream directly, then returns.
"""
struct StreamHandlerFunction{F <: Base.Callable} <: StreamHandler
    func::F # func(stream)
end

handle(h::StreamHandlerFunction, stream::Stream) = h.func(stream)

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
    vals = :(HTTP.Handlers.newsplitsegments(map(String, split($path, '/'; keepempty=false)))...)
    q = esc(quote
        $(router).routes[HTTP.Handlers.Route(string($method), string($scheme), string($host), string($path))] = $handler
        @eval function HTTP.Handlers.gethandler(r::$(Expr(:$, :(typeof($router)))),
            ::(HTTP.Handlers.gh($method)),
            ::(HTTP.Handlers.gh($scheme)),
            ::(HTTP.Handlers.gh($host)),
            $(Expr(:$, vals)),
            args...)
            return HTTP.Handler($(Expr(:$, handler)))
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

handle(r::Router, stream::Stream, args...) = handle(gethandler(r, stream.message), stream, args...)
handle(r::Router, req::Request, args...) = handle(gethandler(r, req), req, args...)

# deprecated
register!(r::Router, url, handler) = register!(r, "", url, handler)
function register!(r::Router, method::String, url, handler)
    m = isempty(method) ? Any : Val{Symbol(method)}
    # get scheme, host, split path into strings & vals
    uri = url isa String ? URI(url) : url
    s = uri.scheme
    sch = !isempty(s) ? typeof(get!(SCHEMES, s, Val(s))) : Any
    h = !isempty(uri.host) ? Val{Symbol(uri.host)} : Any
    hand = Handler(handler)
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
