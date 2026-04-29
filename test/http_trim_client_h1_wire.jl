include("trim_workload_common.jl")

const _HTTP_TRIM_H1_WIRE_LISTENER = Ref{Union{Nothing,Reseau.TCP.Listener}}(nothing)
const _HTTP_TRIM_H1_WIRE_STARTED = Ref(false)
const _HTTP_TRIM_H1_WIRE_DONE = Ref(false)

function _http_trim_h1_wire_server_entry()::Nothing
    _HTTP_TRIM_H1_WIRE_STARTED[] = true
    listener = _HTTP_TRIM_H1_WIRE_LISTENER[]::Reseau.TCP.Listener
    conn = Reseau.TCP.accept(listener)
    try
        request = HT.read_request(HT._ConnReader(conn))
        try
            request.method == "GET" || error("expected GET request, got $(request.method)")
            request.target == "/wire" || error("expected /wire target, got $(request.target)")
            HT.write_response!(conn, trim_text_response("h1-wire"))
            closewrite(conn)
        finally
            HT.body_close!(request.body)
        end
    finally
        _HTTP_TRIM_H1_WIRE_DONE[] = true
        HTTP.@try_ignore close(conn)
    end
    return nothing
end

function run_http_trim_client_h1_wire()::Nothing
    listener::Union{Nothing,Reseau.TCP.Listener} = nothing
    client::Union{Nothing,Reseau.TCP.Conn} = nothing
    server_task::Union{Nothing,Task} = nothing
    try
        listener = Reseau.TCP.listen(Reseau.TCP.loopback_addr(0); backlog = 16)
        _HTTP_TRIM_H1_WIRE_LISTENER[] = listener
        _HTTP_TRIM_H1_WIRE_STARTED[] = false
        _HTTP_TRIM_H1_WIRE_DONE[] = false

        server_task = Task(_http_trim_h1_wire_server_entry)
        schedule(server_task)
        start_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_H1_WIRE_STARTED[], 5.0; pollint = 0.001)
        start_status == :timed_out && error("timed out waiting for trim H1 wire server task")

        addr = Reseau.TCP.addr(listener)::Reseau.TCP.SocketAddrV4
        address = "127.0.0.1:$(Int(addr.port))"
        client = Reseau.TCP.connect(Reseau.TCP.loopback_addr(Int(addr.port)))

        request = HT.Request("GET", "/wire"; host = address, body = HT.EmptyBody(), content_length = 0)
        HT.write_request!(client, request)
        closewrite(client)

        response = HT._read_response(HT._ConnReader(client), request)
        response.status == 200 || error("expected 200 response, got $(response.status)")
        body = response.body
        body isa HT.FixedLengthBody || error("expected FixedLengthBody response body")
        HT.header(response.headers, "Content-Length") == "7" || error("unexpected Content-Length header")
        HT.body_close!(body)
    finally
        _HTTP_TRIM_H1_WIRE_LISTENER[] = nothing
        HTTP.@try_ignore client === nothing || close(client::Reseau.TCP.Conn)
        HTTP.@try_ignore listener === nothing || close(listener::Reseau.TCP.Listener)
        if server_task !== nothing
            HTTP.@try_ignore begin
                done_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_H1_WIRE_DONE[] || istaskdone(server_task::Task), 5.0; pollint = 0.001)
                done_status == :timed_out && error("timed out waiting for trim H1 wire server task shutdown")
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
    run_http_trim_client_h1_wire()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
