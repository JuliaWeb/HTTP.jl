include("trim_workload_common.jl")

# Exercises Router construction and every register! form (specialized handler/middleware
# arguments, the typed segments container, parametric Leaf/Node insertion) — the
# registration-time machinery must stay trim-clean. NOTE: serving THROUGH the router is
# deliberately not covered yet: the matched-handler invocation is runtime dispatch over
# the handler table (the one known trim frontier in the server; see the router-dispatch
# design discussion). Add a serving workload when that design lands.

middleware_wrap(handler) = request -> handler(request)

function run_http_trim_server_router_registration()::Nothing
    router = HT.Router(HT.Handlers.default404, HT.Handlers.default405, middleware_wrap)
    HT.register!(router, "GET", "/users/{id}", request -> trim_text_response("user"))
    HT.register!(router, "/status", request -> trim_text_response("ok"))
    HT.register!(router, "POST", "/orgs/{org}/events/**", request -> trim_text_response("event"))
    HT.register!(router, "GET", "/health") do request
        return trim_text_response("healthy")
    end
    # a second router without middleware exercises the Nothing-middleware constructor arm
    bare = HT.Router()
    HT.register!(bare, "GET", "/ping", request -> trim_text_response("pong"))
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_server_router_registration()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
