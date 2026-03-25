include("trim_workload_common.jl")

function run_http_trim_client_server()::Nothing
    listener::Union{Nothing, Reseau.TCP.Listener} = nothing
    client::Union{Nothing, Reseau.TCP.Conn} = nothing
    server::Union{Nothing, Reseau.TCP.Conn} = nothing
    try
        listener = Reseau.TCP.listen(Reseau.TCP.loopback_addr(0); backlog = 16)
        addr = Reseau.TCP.addr(listener)
        port = Int((addr::Reseau.TCP.SocketAddrV4).port)
        client = Reseau.TCP.connect(Reseau.TCP.loopback_addr(port))
        request_bytes = Vector{UInt8}(codeunits(
            "GET /hello HTTP/1.1\r\n" *
            "Host: 127.0.0.1:$(port)\r\n" *
            "Connection: close\r\n" *
            "\r\n",
        ))
        write(client, request_bytes) == length(request_bytes) || error("expected full request write")
        closewrite(client)

        server = Reseau.TCP.accept(listener)
        request = HT.read_request(HT._ConnReader(server))
        try
            request.method == "GET" || error("expected GET request, got $(request.method)")
            request.target == "/hello" || error("expected /hello target, got $(request.target)")
            HT.write_response!(server, trim_text_response("hello"))
            closewrite(server)
        finally
            HT.body_close!(request.body)
        end
        response = String(read(client))
        startswith(response, "HTTP/1.1 200 OK\r\n") || error("expected 200 response, got $(repr(response))")
        occursin("\r\n\r\nhello", response) || error("unexpected response body: $(repr(response))")
    finally
        try
            server === nothing || close(server::Reseau.TCP.Conn)
        catch
        end
        try
            client === nothing || close(client::Reseau.TCP.Conn)
        catch
        end
        try
            listener === nothing || close(listener::Reseau.TCP.Listener)
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
