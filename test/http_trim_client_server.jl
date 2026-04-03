include("trim_workload_common.jl")

const _HTTP_TRIM_CLIENT_SERVER_LISTENER = Ref{Union{Nothing,Reseau.TCP.Listener}}(nothing)
const _HTTP_TRIM_CLIENT_SERVER_STARTED = Ref(false)
const _HTTP_TRIM_CLIENT_SERVER_DONE = Ref(false)

function _http_trim_client_server_entry()::Nothing
    _HTTP_TRIM_CLIENT_SERVER_STARTED[] = true
    listener = _HTTP_TRIM_CLIENT_SERVER_LISTENER[]::Reseau.TCP.Listener
    conn = Reseau.TCP.accept(listener)
    try
        request = HT.read_request(HT._ConnReader(conn))
        try
            request.method == "GET" || error("expected GET request, got $(request.method)")
            request.target == "/hello" || error("expected /hello target, got $(request.target)")
            HT.write_response!(conn, trim_text_response("hello"))
            closewrite(conn)
        finally
            HT.body_close!(request.body)
        end
    finally
        _HTTP_TRIM_CLIENT_SERVER_DONE[] = true
        try
            close(conn)
        catch
        end
    end
    return nothing
end

function run_http_trim_client_server()::Nothing
    listener::Union{Nothing,Reseau.TCP.Listener} = nothing
    client::Union{Nothing,Reseau.TCP.Conn} = nothing
    server_task::Union{Nothing,Task} = nothing
    try
        listener = Reseau.TCP.listen(Reseau.TCP.loopback_addr(0); backlog = 16)
        _HTTP_TRIM_CLIENT_SERVER_LISTENER[] = listener
        _HTTP_TRIM_CLIENT_SERVER_STARTED[] = false
        _HTTP_TRIM_CLIENT_SERVER_DONE[] = false

        # Desired future coverage once the current public-client trim blocker is fixed:
        #
        # hello = HT.get("http://127.0.0.1:$(port)/hello";
        #     proxy = HT.ProxyConfig(),
        #     protocol = :h1,
        #     connect_timeout = 1.0,
        #     request_timeout = 5.0,
        #     response_header_timeout = 5.0,
        #     read_idle_timeout = 5.0,
        #     retry = false,
        # )
        # uri_response = HT.get(HT.URI("http://127.0.0.1:$(port)/uri"); client = client, protocol = :h1, ...)
        # buffered = HT.request("GET", "http://127.0.0.1:$(port)/buffer", Pair{String,String}[], nothing;
        #     client = client,
        #     response_body = IOBuffer(),
        #     protocol = :h1,
        #     ...,
        # )
        # streamed = HT.open(:POST, "http://127.0.0.1:$(port)/stream"; client = client, protocol = :h1, ...) do stream
        #     write(stream, "payload")
        #     response = HT.startread(stream)
        #     read(stream, String)
        # end
        #
        # Current trim blocker when climbing to this layer:
        # `HT.get(...)` reaches `HTTP.request`'s kw wrapper in `src/http_client.jl`
        # and currently fails trim verification before runtime.

        # Desired future coverage once package-local background Tasks are trim-safe:
        #
        # http_server = HT.serve!(listener) do request
        #     request.method == "GET" || return trim_text_response("missing"; status = 404)
        #     request.target == "/hello" || return trim_text_response("missing"; status = 404)
        #     return trim_text_response("hello")
        # end

        server_task = Task(_http_trim_client_server_entry)
        schedule(server_task)
        start_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_CLIENT_SERVER_STARTED[], 5.0; pollint = 0.001)
        start_status == :timed_out && error("timed out waiting for trim HTTP server task")

        addr = Reseau.TCP.addr(listener)
        port = Int((addr::Reseau.TCP.SocketAddrV4).port)
        request_bytes = Vector{UInt8}(codeunits(
            "GET /hello HTTP/1.1\r\n" *
            "Host: 127.0.0.1:$(port)\r\n" *
            "Connection: close\r\n" *
            "\r\n",
        ))
        client = Reseau.TCP.connect(Reseau.TCP.loopback_addr(port))
        write(client, request_bytes) == length(request_bytes) || error("expected full request write")
        closewrite(client)
        response = String(read(client))
        startswith(response, "HTTP/1.1 200 OK\r\n") || error("expected 200 response, got $(repr(response))")
        occursin("\r\n\r\nhello", response) || error("unexpected response body: $(repr(response))")
    finally
        _HTTP_TRIM_CLIENT_SERVER_LISTENER[] = nothing
        try
            client === nothing || close(client::Reseau.TCP.Conn)
        catch
        end
        try
            listener === nothing || close(listener::Reseau.TCP.Listener)
        catch
        end
        try
            if server_task !== nothing
                done_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_CLIENT_SERVER_DONE[] || istaskdone(server_task::Task), 5.0; pollint = 0.001)
                done_status == :timed_out && error("timed out waiting for trim HTTP server task shutdown")
                wait(server_task)
            end
        catch
        end
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
