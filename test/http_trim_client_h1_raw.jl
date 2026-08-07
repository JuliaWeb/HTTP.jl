include("trim_workload_common.jl")

const _HTTP_TRIM_H1_RAW_LISTENER = Ref{Union{Nothing,Reseau.TCP.Listener}}(nothing)

function _http_trim_h1_raw_server_entry()::Nothing
    listener = _HTTP_TRIM_H1_RAW_LISTENER[]::Reseau.TCP.Listener
    conn = Reseau.TCP.accept(listener)
    try
        request = HT.read_request(HT._ConnReader(conn))
        try
            request.method == "GET" || error("expected GET request, got $(request.method)")
            request.target == "/raw" || error("expected /raw target, got $(request.target)")
            HT.write_response!(conn, trim_text_response("h1-raw"))
            closewrite(conn)
        finally
            HT.body_close!(request.body)
        end
    finally
        HTTP.@try_ignore close(conn)
    end
    return nothing
end

function run_http_trim_client_h1_raw()::Nothing
    listener::Union{Nothing,Reseau.TCP.Listener} = nothing
    client::Union{Nothing,Reseau.TCP.Conn} = nothing
    server_task::Union{Nothing,Task} = nothing
    try
        listener = Reseau.TCP.listen(Reseau.TCP.loopback_addr(0); backlog = 16)
        _HTTP_TRIM_H1_RAW_LISTENER[] = listener

        server_task = Task(_http_trim_h1_raw_server_entry)
        schedule(server_task)

        addr = Reseau.TCP.addr(listener)::Reseau.TCP.SocketAddrV4
        address = "127.0.0.1:$(Int(addr.port))"
        client = Reseau.TCP.connect(Reseau.TCP.loopback_addr(Int(addr.port)))

        request = HT.Request("GET", "/raw"; host = address, body = HT.EmptyBody(), content_length = 0)
        HT.write_request!(client, request)
        closewrite(client)

        response = String(read(client))
        startswith(response, "HTTP/1.1 200 OK\r\n") || error("expected 200 response, got $(repr(response))")
        occursin("\r\n\r\nh1-raw", response) || error("unexpected raw response body")
    finally
        _HTTP_TRIM_H1_RAW_LISTENER[] = nothing
        HTTP.@try_ignore client === nothing || close(client::Reseau.TCP.Conn)
        HTTP.@try_ignore listener === nothing || close(listener::Reseau.TCP.Listener)
        if server_task !== nothing
            HTTP.@try_ignore begin
                wait(server_task)
            end
        end
        yield()
        GC.gc()
        HTTP.@try_ignore Reseau.IOPoll.shutdown!()
    end
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_client_h1_raw()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
