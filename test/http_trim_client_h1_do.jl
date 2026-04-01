include("trim_workload_common.jl")

const _HTTP_TRIM_H1_DO_LISTENER = Ref{Union{Nothing,Reseau.TCP.Listener}}(nothing)
const _HTTP_TRIM_H1_DO_STARTED = Ref(false)
const _HTTP_TRIM_H1_DO_DONE = Ref(false)

function _http_trim_h1_do_server_entry()::Nothing
    _HTTP_TRIM_H1_DO_STARTED[] = true
    listener = _HTTP_TRIM_H1_DO_LISTENER[]::Reseau.TCP.Listener
    conn = Reseau.TCP.accept(listener)
    try
        request = HT.read_request(HT._ConnReader(conn))
        try
            request.method == "GET" || error("expected GET request, got $(request.method)")
            request.target == "/do" || error("expected /do target, got $(request.target)")
            HT.write_response!(conn, trim_text_response("h1-do"))
            closewrite(conn)
        finally
            HT.body_close!(request.body)
        end
    finally
        _HTTP_TRIM_H1_DO_DONE[] = true
        try
            close(conn)
        catch
        end
    end
    return nothing
end

Base.Experimental.entrypoint(_http_trim_h1_do_server_entry, ())

function run_http_trim_client_h1_do()::Nothing
    listener::Union{Nothing,Reseau.TCP.Listener} = nothing
    server_task::Union{Nothing,Task} = nothing
    client::Union{Nothing,HT.Client} = nothing
    try
        listener = Reseau.TCP.listen(Reseau.TCP.loopback_addr(0); backlog = 16)
        _HTTP_TRIM_H1_DO_LISTENER[] = listener
        _HTTP_TRIM_H1_DO_STARTED[] = false
        _HTTP_TRIM_H1_DO_DONE[] = false

        server_task = errormonitor(Task(_http_trim_h1_do_server_entry))
        schedule(server_task)
        start_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_H1_DO_STARTED[], 5.0; pollint = 0.001)
        start_status == :timed_out && error("timed out waiting for trim H1 do! server task")

        addr = Reseau.TCP.addr(listener)::Reseau.TCP.SocketAddrV4
        address = "127.0.0.1:$(Int(addr.port))"
        client = HT.Client(transport = HT.Transport(proxy = HT.ProxyConfig(), max_idle_per_host = 1, max_idle_total = 1), cookiejar = nothing)

        request = HT.Request("GET", "/do"; host = address, body = HT.EmptyBody(), content_length = 0)
        response = HT.do!(client, address, request; protocol = :h1, proxy = HT.ProxyConfig(), cookies = false, verbose = false)
        response.status == 200 || error("expected 200 response, got $(response.status)")
        body = response.body
        body isa HT.H1Body || error("expected H1Body response body")
        trim_body_string(body::HT.H1Body) == "h1-do" || error("unexpected response body")
    finally
        try
            client === nothing || close(client::HT.Client)
        catch
        end
        _HTTP_TRIM_H1_DO_LISTENER[] = nothing
        try
            listener === nothing || close(listener::Reseau.TCP.Listener)
        catch
        end
        try
            if server_task !== nothing
                done_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_H1_DO_DONE[] || istaskdone(server_task::Task), 5.0; pollint = 0.001)
                done_status == :timed_out && error("timed out waiting for trim H1 do! server task shutdown")
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
    run_http_trim_client_h1_do()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
