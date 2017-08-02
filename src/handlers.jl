module Handlers

export handle, Handler, HandlerFunction, Router, register!

using HTTP

function handle end
handle(handler, req, resp, vals...) = handle(handler, req, resp)

abstract type Handler end

struct HandlerFunction{F <: Function} <: Handler
    func::F # func(req, resp)
end

handle(h::HandlerFunction, req, resp) = h.func(req, resp)

const FourOhFour = HandlerFunction((req, resp) -> Response(404))

"""

A Router maps urls/paths to Handlers.

/     f(m, s, h, args...)                              # default mapping, matches all requests, returns 404
/api  f(::Val{:api}, args...)
/api/social  f(::Val{:api}, ::Val{:social}, args...)
/api/social/v4
/api/social/v4/alerts
/api/social/v4/alerts/*  f(::Val{:api}, ::Val{:social}, ::Val{:v4}, ::Val{:alerts}, ::Any)
/api/social/v4/alerts/1/evaluate

/test  f(::Val{:test})
/test/{var::String}  f(::Val{:test}, ::Any)  
/test/sarv/ghotra    f(::Val{:test}, ::Val{:sarv}, ::Val{:ghotra})

scheme, subdomain, host, method, path

"""
struct Router <: Handler
    segments::Dict{String, Val}
    sym::Symbol
    func::Function
    function Router(ff::Union{Handler, Function, Void}=nothing)
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
const METHODS = Dict{String, Val}()
for m in instances(HTTP.Method)
    METHODS[string(m)] = Val(Symbol(m))
end
const EMPTYVAL = Val(())

register!(r::Router, url, handler) = register!(r, "", url, handler)
register!(r::Router, m::Method, url, handler) = register!(r, string(m), url, handler)

function register!(r::Router, method::String, url, handler)
    m = isempty(method) ? Any : typeof(METHODS[method])
    # get scheme, host, split path into strings & vals
    uri = url isa String ? HTTP.URI(url) : url
    s = HTTP.scheme(uri)
    sch = HTTP.hasscheme(uri) ? typeof(get!(SCHEMES, s, Val(s))) : Any
    h = HTTP.hashostname(uri) ? Val{Symbol(HTTP.hostname(uri))} : Any
    hand = handler isa Function ? HandleFunction(handler) : handler
    register!(r, m, sch, h, HTTP.path(uri), hand)
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

function handle(r::Router, req, resp)
    # get the url/path of the request
    m = Val(HTTP.method(req))
    uri = HTTP.uri(req)
    # get scheme, host, split path into strings and get Vals
    s = get(SCHEMES, HTTP.scheme(uri), EMPTYVAL)
    h = Val(Symbol(HTTP.hostname(uri)))
    p = HTTP.path(uri)
    segments = split(p, '/'; keep=false)
    # dispatch to the most specific handler, given the path
    vals = (get(r.segments, s, EMPTYVAL) for s in segments)
    handler = r.func(m, s, h, vals...)
    # pass the request & response to the handler and return
    return handle(handler, req, resp, vals...)
end

end # module