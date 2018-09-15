module Handlers

export handle, Handler, RequestHandler, StreamHandler,
       RequestHandlerFunction, StreamHandlerFunction, Router,
       @register, register!

using ..Messages, ..URIs, ..Streams, ..IOExtras

"""
handle(handler::Handler, request) => Response

Function used to dispatch to a Handler. Called from the core HTTP.serve method with the
initial Handler passed to `HTTP.serve(handler=handler)`.
"""
function handle end

"""
Abstract type representing an object that knows how to "handle" a server request.

Types of handlers include:
  * `HTTP.RequestHandlerFunction`: a julia function of the form `f(request::HTTP.Request)`
  * `HTTP.Router`: pattern matches request url paths to other specific `Handler` types
  * `HTTP.StreamHandlerFunction`: a julia function of the form `f(stream::HTTP.Stream)`
"""
abstract type Handler end
abstract type RequestHandler <: Handler end
abstract type StreamHandler <: Handler end

"""
RequestHandlerFunction(f::Function)

A Function-wrapper type that is a subtype of `Handler`. Takes a single Function as an argument.
The provided argument should be of the form `f(request) => Response`, i.e. it accepts a `Request` returns a `Response`.
"""
struct RequestHandlerFunction{F <: Function} <: RequestHandler
    func::F # func(req)
end

"A default 404 Handler"
const FourOhFour = RequestHandlerFunction(req -> Response(404))

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

struct StreamHandlerFunction{F <: Function} <: StreamHandler
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
Router(h::Handler)
Router(f::Function)
Router()

An `HTTP.Handler` type that supports mapping request url paths to other `HTTP.Handler` types.
Can accept a default `Handler` or `Function` that will be used in case no other handlers match; by
default, a 404 response handler is used.
Paths can be mapped to a handler via `HTTP.register!(r::Router, path, handler)`, see `?HTTP.register!` for more details.
"""
struct Router{sym} <: Handler
    default::Handler
    routes::Dict{Route, String}
    segments::Dict{String, Val}
    function Router(default::Union{Handler, Function, Nothing}=FourOhFour)
        sym = gensym()
        return new{sym}(default, Dict{Route, String}(), Dict{String, Val}())
    end
end

const SCHEMES = Dict{String, Val}("http" => Val{:http}(), "https" => Val{:https}())
const EMPTYVAL = Val{()}()

"""
HTTP.register!(r::Router, url, handler)
HTTP.register!(r::Router, m::String, url, handler)

Function to map request urls matching `url` and an optional method `m` to another `handler::HTTP.Handler`.
URLs are registered one at a time, and multiple urls can map to the same handler.
The URL can be passed as a String or `HTTP.URI` object directly. Requests can be routed based on: method, scheme,
hostname, or path.
The following examples show how various urls will direct how a request is routed by a server:

- `"http://*"`: match all HTTP requests, regardless of path
- `"https://*"`: match all HTTPS requests, regardless of path
- `"google"`: regardless of scheme, match requests to the hostname "google"
- `"google/gmail"`: match requests to hostname "google", and path starting with "gmail"
- `"/gmail"`: regardless of scheme or host, match any request with a path starting with "gmail"
- `"/gmail/userId/*/inbox`: match any request matching the path pattern, "*" is used as a wildcard that matches any value between the two "/"
"""
register!(r::Router, url, handler) = register!(r, "", url, handler)

function register!(r::Router, method::String, url, handler)
    m = isempty(method) ? Any : typeof(Val(Symbol(method)))
    # get scheme, host, split path into strings & vals
    uri = url isa String ? URI(url) : url
    s = uri.scheme
    sch = !isempty(s) ? typeof(get!(SCHEMES, s, Val(s))) : Any
    h = !isempty(uri.host) ? Val{Symbol(uri.host)} : Any
    hand = handler isa Function ? RequestHandlerFunction(handler) : handler
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
function newsplitsegments(segments)
    vals = Expr[]
    for s in segments
        if s == "*" #TODO: or variable, keep track of variable types and store in handler
            T = Any
        else
            v = Val(Symbol(s))
            T = typeof(v)
        end
        push!(vals, Expr(:(::), T))
    end
    return vals
end

function gethandler end
gethandler(r::Router, args...) = r.default

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

gh(s::String) = isempty(s) ? Any : typeof(Val(Symbol(s)))
gh(s::Symbol) = s

function generate_gethandler(router::Symbol, method,
    scheme, host, path, handler::Symbol)
    vals = :(HTTP.Handlers.newsplitsegments(map(String, split($path, '/'; keepempty=false)))...)
    q = esc(quote
        r.routes[HTTP.Handlers.Route($method, $scheme, $host, $path)] = $(string(handler))
        @eval function HTTP.Handlers.gethandler(r::$(Expr(:$, :(typeof($router)))),
            ::(HTTP.Handlers.gh($method)),
            ::(HTTP.Handlers.gh($scheme)),
            ::(HTTP.Handlers.gh($host)),
            $(Expr(:$, vals)),
            args...)
            return $(Expr(:$, handler))
        end
    end)
    # @show q
    return q
end

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

handle(r::Router, req::Request) = handle(gethandler(r, req), req)

end # module
