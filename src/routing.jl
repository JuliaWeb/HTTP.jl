module Routing

using HTTP
include("route.jl")

export Handler, Router, handle, register!, setdefaulthandler, Vars

abstract type Handler end

handle(h, req, res) = h.func(req, resp)

const FourOhFour = ((req, resp) -> Response(404))

mutable struct Router
    routes::Array{Route}
    defaulthandler # TODO: restrict its interface to Handler type
    function Router()
        r = new([], FourOhFour)
        return r
    end
end

function handle(rr::Router, req, res)
    #find a match for the request
    handler = match_handler(rr, req)
    return handler(req, res)
end

function register!(rr::Router, handler, path::String, methods=nothing)
    route = Route(handler, path, methods)
    push!(rr.routes, route)
end

function match_handler(rr::Router, req)
    # match against all the registered paths
    for route in rr.routes
        if matchroute(route, req)
            global Vars = setvarnames(route, req)
            return route.handler
        end
    end
    return rr.defaulthandler
end

function setdefaulthandler(rr::Router, handler)
    rr.defaulthandler = handler
end

# to access the variable values from the path and host of the matched route
Vars = Dict{String, Any}()

end
