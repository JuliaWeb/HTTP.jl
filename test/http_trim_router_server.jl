include("trim_workload_common.jl")

using Base.ScopedValues: ScopedValue

# An application server built the way larger HTTP.jl apps build theirs: route
# handlers are closures that capture state, every router wraps its handlers in
# middleware composed from several functions, one router forwards a path
# prefix to another, and responses carry String, byte-vector, empty and SSE
# bodies, and `servecontent` byte ranges. Each router uses `static_dispatch`,
# and the served handler states the response types it returns, since a
# router's own response type is unknown.

const TrimRouteResponse = Union{
    HT.Response{String},
    HT.Response{Vector{UInt8}},
    HT.Response{HT.EmptyBody},
    HT.Response{HT.SSEStream},
    HT.Response{HT.BytesBody{Vector{UInt8}}},
    HT.Response{HT.BytesBody{typeof(view(UInt8[], 1:0))}},
}

const TRIM_ROUTE_BLOB = collect(codeunits("0123456789"))

# Handlers capture this, as application handlers capture their request-scoped
# state. (Binding it with `@with` is left out: on Julia 1.13 that compiles a
# dynamic call inside Base.)
const TRIM_ROUTE_GREETING = ScopedValue("hello")

trim_compose(middlewares...) = handler -> foldr((middleware, inner) -> middleware(inner), middlewares; init = handler)

function trim_error_middleware(handler)
    return function (req::HT.Request)
        try
            return handler(req)::HT.Response
        catch err
            message = err isa ArgumentError && err.msg isa String ? err.msg::String : "internal error"
            return HT.Response(err isa ArgumentError ? 400 : 500, ["Content-Type" => "text/plain"], Vector{UInt8}(codeunits(message)))
        end
    end
end

function trim_user_middleware(handler)
    return function (req::HT.Request)
        name = HT.header(req, "X-User", "")
        isempty(name) && return HT.Response(401)
        req.context[:user] = String(name)
        return handler(req)
    end
end

# Registers through a helper, as an application with hundreds of routes does.
function trim_route!(router, method::String, path::String, handler)
    HT.register!(router, method, path, req -> handler(req))
    return nothing
end

function trim_build_router()
    authed = HT.Router(HT.Handlers.default404, HT.Handlers.default405,
        HT.Handlers.static_dispatch(trim_compose(trim_error_middleware, trim_user_middleware)))
    public = HT.Router(HT.Handlers.default404, HT.Handlers.default405,
        HT.Handlers.static_dispatch(trim_error_middleware))
    greeting = TRIM_ROUTE_GREETING
    trim_route!(public, "GET", "/v1/live", _ -> HT.Response(200, ["Content-Type" => "text/plain"], greeting[]))
    trim_route!(public, "GET", "/v1/bytes/{id}", req ->
        HT.Response(200, ["Content-Type" => "text/plain"], Vector{UInt8}(codeunits("id=" * HT.getparam(req, "id", "")))))
    trim_route!(public, "POST", "/v1/echo", req -> HT.Response(200, ["Content-Type" => "text/plain"], trim_body_string(req.body)))
    trim_route!(public, "DELETE", "/v1/thing/*", _ -> HT.Response(204))
    trim_route!(public, "GET", "/v1/blob", req -> HT.servecontent(req, TRIM_ROUTE_BLOB; content_type = "text/plain"))
    trim_route!(public, "GET", "/v1/bad", _ -> throw(ArgumentError("bad input")))
    trim_route!(public, "GET", "/v1/events", _ -> begin
        stream = HT.SSEStream()
        write(stream, HT.SSEEvent("ready"))
        close(stream)
        response = HT.Response(200, stream)
        HT.sse_stream(response)
        return response
    end)
    trim_route!(authed, "GET", "/v1/me", req -> HT.Response(200, ["Content-Type" => "text/plain"], "me=" * (req.context[:user]::String)))
    # Requests under /v1/ that no public route matched go to the authenticated router.
    HT.register!(public, "/v1/**", authed)
    # A router without middleware in front: a handler error crosses the
    # function-pointer call and reaches the server, which answers 500.
    outer = HT.Router(HT.Handlers.default404, HT.Handlers.default405, HT.Handlers.static_dispatch())
    HT.register!(outer, "GET", "/crash", _ -> error("crash"))
    HT.register!(outer, "/**", public)
    return outer
end

function trim_router_exchange(port::Integer, method::String, target::String; headers::String = "", body::String = "")::String
    request = "$(method) $(target) HTTP/1.1\r\nHost: 127.0.0.1:$(port)\r\nConnection: close\r\n" * headers *
        (isempty(body) ? "" : "Content-Length: $(ncodeunits(body))\r\n") * "\r\n" * body
    return trim_raw_http_exchange(port, request)
end

function trim_expect(response::String, status::String, body::String)::Nothing
    startswith(response, "HTTP/1.1 $(status)\r\n") || error("expected $(status), got $(repr(response))")
    endswith(response, "\r\n\r\n" * body) || error("expected body $(repr(body)), got $(repr(response))")
    return nothing
end

function run_http_trim_router_server()::Nothing
    server = nothing
    try
        router = trim_build_router()
        server = HT.serve!(req -> router(req)::TrimRouteResponse, "127.0.0.1", 0; listenany = true)
        port = HT.port(server)
        trim_expect(trim_router_exchange(port, "GET", "/v1/live"), "200 OK", "hello")
        startswith(trim_router_exchange(port, "GET", "/crash"), "HTTP/1.1 500 ") || error("expected 500 from a failing handler")
        trim_expect(trim_router_exchange(port, "GET", "/v1/bytes/42"), "200 OK", "id=42")
        trim_expect(trim_router_exchange(port, "POST", "/v1/echo"; body = "ping"), "200 OK", "ping")
        trim_expect(trim_router_exchange(port, "DELETE", "/v1/thing/x"), "204 No Content", "")
        trim_expect(trim_router_exchange(port, "GET", "/v1/blob"), "200 OK", "0123456789")
        trim_expect(trim_router_exchange(port, "GET", "/v1/blob"; headers = "Range: bytes=2-4\r\n"), "206 Partial Content", "234")
        trim_expect(trim_router_exchange(port, "GET", "/v1/bad"), "400 Bad Request", "bad input")
        occursin("data: ready", trim_router_exchange(port, "GET", "/v1/events")) || error("missing SSE event")
        trim_expect(trim_router_exchange(port, "GET", "/v1/me"), "401 Unauthorized", "")
        trim_expect(trim_router_exchange(port, "GET", "/v1/me"; headers = "X-User: ada\r\n"), "200 OK", "me=ada")
        trim_expect(trim_router_exchange(port, "GET", "/v1/missing"; headers = "X-User: ada\r\n"), "404 Not Found", "")
        trim_expect(trim_router_exchange(port, "POST", "/v1/me"; headers = "X-User: ada\r\n"), "405 Method Not Allowed", "")
    finally
        server === nothing || close(server::HT.Server)
        trim_shutdown_runtime()
    end
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_router_server()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
