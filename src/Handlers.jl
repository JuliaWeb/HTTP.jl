module Handlers

export handle, gethandler, Handler, HandlerFunction, Router, register!

import ..Nothing, ..Cvoid, ..Val

using HTTP

"""
handle(handler::Handler, request) => Response

Function used to dispatch to a Handler. Called from the core HTTP.serve method with the
initial Handler passed to `HTTP.serve(handler=handler)`.
"""
function handle end
handle(handler, req, vals...) = handle(handler, req)

"""
Abstract type representing an object that knows how to "handle" a server request.

Types of handlers include `HandlerFunction` (a julia function of the form `f(request)` and
`Router` (which pattern matches request url paths to other specific `Handler` types).
"""
abstract type Handler end

"""
HandlerFunction(f::Function)

A Function-wrapper type that is a subtype of `Handler`. Takes a single Function as an argument.
The provided argument should be of the form `f(request) => Response`, i.e. it accepts a `Request` returns a `Response`.
"""
struct HandlerFunction{F <: Function} <: Handler
    func::F # func(req)
end

handle(h::HandlerFunction, req) = h.func(req)

"A default 404 Handler"
const FourOhFour = HandlerFunction(req -> HTTP.Response(404))

"""
Router(h::Handler)
Router(f::Function)
Router()

An `HTTP.Handler` type that supports mapping request url paths to other `HTTP.Handler` types.
Can accept a default `Handler` or `Function` that will be used in case no other handlers match; by
default, a 404 response handler is used.
Paths can be mapped to a handler via `HTTP.register!(r::Router, path, handler)`, see `?HTTP.register!` for more details.
"""
struct Router <: Handler
    segments::Dict{String, Val}
    sym::Symbol
    func::Function
    function Router(ff::Union{Handler, Function, Nothing}=nothing)
        sym = gensym()
        if ff == nothing
            f = @eval $sym(args...) = FourOhFour
        else
            f = ff isa Function ? HandlerFunction(ff) : ff
        end
        r = new(Dict{String, Val}(), sym, f)
        return r
    end
end

const SCHEMES = Dict{String, Val}("http" => Val(:http), "https" => Val(:https))
const EMPTYVAL = Val(())

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
    uri = url isa String ? HTTP.URI(url) : url
    s = uri.scheme
    sch = !isempty(s) ? typeof(get!(SCHEMES, s, Val(s))) : Any
    h = !isempty(uri.host) ? Val{Symbol(uri.host)} : Any
    hand = handler isa Function ? HandlerFunction(handler) : handler
    register!(r, m, sch, h, uri.path, hand)
end

function splitsegments(r::Router, h::Handler, segments)
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

function register!(r::Router, method::DataType, scheme, host, path, handler)
    # save string => Val mappings in r.segments
    segments = map(String, split(path, '/'; keep=false))
    vals = splitsegments(r, handler, segments)
    # return a method to get dispatched to
    #TODO: detect whether defining this method will create ambiguity?
    @eval $(r.sym)(::$method, ::$scheme, ::$host, $(vals...), args...) = $handler
    return
end

function gethandler(r::Router, req)
    # get the url/path of the request
    m = Val(Symbol(req.method))
    # get scheme, host, split path into strings and get Vals
    uri = HTTP.URI(req.target)
    s = get(SCHEMES, uri.scheme, EMPTYVAL)
    h = Val(Symbol(uri.host))
    p = uri.path
    segments = split(p, '/'; keep=false)
    # dispatch to the most specific handler, given the path
    vals = (get(r.segments, s, EMPTYVAL) for s in segments)
    return r.func(m, s, h, vals...).func
end

function handle(r::Router, req)
    handler = gethandler(r,req)
    # pass the request to the handler and return
    return handle(handler, req, vals...)
end

end # module
