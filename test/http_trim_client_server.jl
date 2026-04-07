include("trim_workload_common.jl")

function run_http_trim_client_server()::Nothing
    server = nothing
    try
        server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            request.method == "GET" || return trim_text_response("missing"; status = 404)
            request.target == "/hello" || return trim_text_response("missing"; status = 404)
            return trim_text_response("hello")
        end

        port = trim_wait_http_server_port(server)
        response = trim_raw_http_exchange(port,
            "GET /hello HTTP/1.1\r\n" *
            "Host: 127.0.0.1:$(port)\r\n" *
            "Connection: close\r\n" *
            "\r\n",
        )
        startswith(response, "HTTP/1.1 200 OK\r\n") || error("expected 200 response, got $(repr(response))")
        occursin("\r\n\r\nhello", response) || error("unexpected response body: $(repr(response))")
    finally
        server === nothing || trim_close_http_server(server::HT.Server)
        yield()
        GC.gc()
        try
            Reseau.IOPoll.shutdown!()
        catch
        end
    end
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_client_server()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
