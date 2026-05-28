include("trim_workload_common.jl")

const _HTTP_TRIM_H1_ROUNDTRIP_LISTENER = Ref{Union{Nothing,Reseau.TCP.Listener}}(nothing)
const _HTTP_TRIM_H1_ROUNDTRIP_STARTED = Ref(false)
const _HTTP_TRIM_H1_ROUNDTRIP_DONE = Ref(false)

function _http_trim_h1_roundtrip_server_entry()::Nothing
    _HTTP_TRIM_H1_ROUNDTRIP_STARTED[] = true
    listener = _HTTP_TRIM_H1_ROUNDTRIP_LISTENER[]::Reseau.TCP.Listener
    conn = Reseau.TCP.accept(listener)
    try
        request = HT.read_request(HT._ConnReader(conn))
        try
            request.method == "GET" || error("expected GET request, got $(request.method)")
            request.target == "/roundtrip" || error("expected /roundtrip target, got $(request.target)")
            HT.write_response!(conn, trim_text_response("h1-roundtrip"))
            closewrite(conn)
        finally
            HT.body_close!(request.body)
        end
    finally
        _HTTP_TRIM_H1_ROUNDTRIP_DONE[] = true
        HTTP.@try_ignore close(conn)
    end
    return nothing
end

function run_http_trim_client_h1_roundtrip()::Nothing
    listener::Union{Nothing,Reseau.TCP.Listener} = nothing
    server_task::Union{Nothing,Task} = nothing
    transport::Union{Nothing,HT.Transport} = nothing
    try
        listener = Reseau.TCP.listen(Reseau.TCP.loopback_addr(0); backlog = 16)
        _HTTP_TRIM_H1_ROUNDTRIP_LISTENER[] = listener
        _HTTP_TRIM_H1_ROUNDTRIP_STARTED[] = false
        _HTTP_TRIM_H1_ROUNDTRIP_DONE[] = false

        server_task = Task(_http_trim_h1_roundtrip_server_entry)
        schedule(server_task)
        start_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_H1_ROUNDTRIP_STARTED[], 5.0; pollint = 0.001)
        start_status == :timed_out && error("timed out waiting for trim H1 roundtrip server task")

        addr = Reseau.TCP.addr(listener)::Reseau.TCP.SocketAddrV4
        address = "127.0.0.1:$(Int(addr.port))"
        transport = HT.Transport(proxy = HT.ProxyConfig(), max_idle_per_host = 1, max_idle_total = 1)

        request = HT.Request("GET", "/roundtrip"; host = address, body = HT.EmptyBody(), content_length = 0)
        response = HT.roundtrip!(transport, address, request)
        response.status == 200 || error("expected 200 response, got $(response.status)")
        body = response.body
        body isa HT.H1Body || error("expected H1Body response body")
        trim_body_string(body::HT.H1Body) == "h1-roundtrip" || error("unexpected response body")
    finally
        HTTP.@try_ignore transport === nothing || close(transport::HT.Transport)
        _HTTP_TRIM_H1_ROUNDTRIP_LISTENER[] = nothing
        HTTP.@try_ignore listener === nothing || close(listener::Reseau.TCP.Listener)
        if server_task !== nothing
            HTTP.@try_ignore begin
                done_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_H1_ROUNDTRIP_DONE[] || istaskdone(server_task::Task), 5.0; pollint = 0.001)
                done_status == :timed_out && error("timed out waiting for trim H1 roundtrip server task shutdown")
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
    run_http_trim_client_h1_roundtrip()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
