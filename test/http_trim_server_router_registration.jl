include("trim_workload_common.jl")

# Exercises Router construction, every register! form (specialized handler/middleware
# arguments, the typed segments container, Leaf/Node insertion), AND serving through
# the router: matched-handler invocation is a ccall through HandlerFn (the Reseau
# TaskFn pattern — per-callable @generated @cfunction), so the handler table is
# runtime-mutable yet every request dispatch is statically resolvable under
# `juliac --trim`.

middleware_wrap(handler) = request -> handler(request)

function trim_expect_router(port::Integer, method::String, target::String, expected_status::String, expected_body::String)::Nothing
    response = trim_raw_http_exchange(port,
        "$(method) $(target) HTTP/1.1\r\n" *
        "Host: 127.0.0.1:$(port)\r\n" *
        "Connection: close\r\n" *
        "\r\n",
    )
    startswith(response, expected_status) || error("unexpected status for $(method) $(target): $(repr(response))")
    if !isempty(expected_body)
        occursin("\r\n\r\n" * expected_body, response) || error("unexpected body for $(method) $(target): $(repr(response))")
    end
    return nothing
end

function run_http_trim_server_router_registration()::Nothing
    router = HT.Router(HT.Handlers.default404, HT.Handlers.default405, middleware_wrap)
    HT.register!(router, "GET", "/users/{id}", request -> trim_text_response("user-" * HT.Handlers.getparam(request, "id", "")))
    HT.register!(router, "/status", request -> trim_text_response("ok"))
    HT.register!(router, "POST", "/orgs/{org}/events/**", request -> trim_text_response("event"))
    HT.register!(router, "GET", "/health") do request
        return trim_text_response("healthy")
    end
    # a second router without middleware exercises the Nothing-middleware constructor arm
    bare = HT.Router()
    HT.register!(bare, "GET", "/ping", request -> trim_text_response("pong"))

    server = nothing
    try
        server = HT.serve!(router, "127.0.0.1", 0; listenany = true)
        port = HT.port(server)
        trim_expect_router(port, "GET", "/users/u42", "HTTP/1.1 200 OK\r\n", "user-u42")
        trim_expect_router(port, "GET", "/status", "HTTP/1.1 200 OK\r\n", "ok")
        trim_expect_router(port, "POST", "/orgs/o1/events/e2/whatever", "HTTP/1.1 200 OK\r\n", "event")
        trim_expect_router(port, "GET", "/health", "HTTP/1.1 200 OK\r\n", "healthy")
        trim_expect_router(port, "GET", "/missing", "HTTP/1.1 404", "")
        trim_expect_router(port, "PUT", "/health", "HTTP/1.1 405", "")
    finally
        server === nothing || trim_close_http_server(server::HT.Server)
        yield()
        GC.gc()
        HTTP.@try_ignore Reseau.IOPoll.shutdown!()
    end
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_server_router_registration()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
