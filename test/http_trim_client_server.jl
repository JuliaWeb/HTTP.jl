include("trim_workload_common.jl")

function run_http_trim_client_server()::Nothing
    server = nothing
    try
        # Three response body types, as a framework's handler returns: with
        # the server's own 500 response, the HTTP/1 and HTTP/2 writes must
        # stay statically dispatched for each of them.
        server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            request.method == "GET" || return trim_text_response("missing"; status = 404)
            request.target == "/string" && return HT.Response(200, "hello")
            request.target == "/bytes" && return HT.Response(200, collect(codeunits("hello")))
            request.target == "/hello" || return trim_text_response("missing"; status = 404)
            return trim_text_response("hello")
        end

        port = HT.port(server)
        response = trim_raw_http_exchange(port,
            "GET /hello HTTP/1.1\r\n" *
            "Host: 127.0.0.1:$(port)\r\n" *
            "Connection: close\r\n" *
            "\r\n",
        )
        startswith(response, "HTTP/1.1 200 OK\r\n") || error("expected 200 response, got $(repr(response))")
        occursin("\r\n\r\nhello", response) || error("unexpected response body: $(repr(response))")
        for target in ("/string", "/bytes")
            response = trim_raw_http_exchange(port,
                "GET $(target) HTTP/1.1\r\n" *
                "Host: 127.0.0.1:$(port)\r\n" *
                "Connection: close\r\n" *
                "\r\n",
            )
            endswith(response, "\r\n\r\nhello") || error("unexpected $(target) response: $(repr(response))")
        end
    finally
        # graceful close: also notifies open HTTP/2 connections to shut down
        server === nothing || close(server::HT.Server)
        yield()
        GC.gc()
        HTTP.@try_ignore Reseau.IOPoll.shutdown!()
    end
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_client_server()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
