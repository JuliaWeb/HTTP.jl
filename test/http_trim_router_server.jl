include("trim_workload_common.jl")

function _trim_router_middleware(handler::F) where {F}
    return function (request::HT.Request)
        response = handler(request)
        HT.setheader(response, "X-Routed", "yes")
        return response
    end
end

function run_http_trim_router_server()::Nothing
    router = HT.Router(HT.Handlers.default404, HT.Handlers.default405, _trim_router_middleware)
    greeting = "hello:"
    HT.register!(router, "GET", "/hello/{name:[a-z]+}", request -> HT.Response(200; body=greeting * HT.getparam(request, "name")))
    HT.register!(router, "POST", "/echo/*", request -> trim_text_response(String(request.body)))
    HT.register!(router, "GET", "/bytes/**", _ -> HT.Response(200; body=UInt8[0x6f, 0x6b]))
    HT.register!(router, "GET", "/empty", _ -> HT.Response(204))
    GC.gc()
    server = HT.serve!(router, "127.0.0.1", 0; listenany=true)
    try
        port = HT.port(server)
        for (method, path, payload, status, expected) in (
            ("GET", "/hello/world", "", 200, "hello:world"),
            ("POST", "/echo/value", "echo", 200, "echo"),
            ("GET", "/bytes/a/b", "", 200, "ok"),
            ("GET", "/empty", "", 204, ""),
            ("GET", "/missing", "", 404, ""),
            ("POST", "/empty", "", 405, ""),
        )
            wire = "$method $path HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Length: $(ncodeunits(payload))\r\n\r\n$payload"
            response = trim_raw_http_exchange(port, wire)
            startswith(response, "HTTP/1.1 $status ") || error("unexpected response: $response")
            endswith(response, "\r\n\r\n$expected") || error("unexpected body: $response")
            status == 200 && !occursin("X-Routed: yes", response) && error("middleware did not run")
        end
    finally
        close(server)
        trim_close_http_server(server)
        trim_shutdown_runtime()
    end
    return nothing
end

function @main(args::Vector{String})::Cint
    run_http_trim_router_server()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
