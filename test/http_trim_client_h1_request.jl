include("trim_workload_common.jl")

const _HTTP_TRIM_H1_REQUEST_LISTENER = Ref{Union{Nothing,Reseau.TCP.Listener}}(nothing)
const _HTTP_TRIM_H1_REQUEST_STARTED = Ref(false)
const _HTTP_TRIM_H1_REQUEST_DONE = Ref(false)

function _http_trim_h1_request_server_entry()::Nothing
    _HTTP_TRIM_H1_REQUEST_STARTED[] = true
    listener = _HTTP_TRIM_H1_REQUEST_LISTENER[]::Reseau.TCP.Listener
    conn = Reseau.TCP.accept(listener)
    try
        request = HT.read_request(HT._ConnReader(conn))
        try
            request.method == "GET" || error("expected GET request, got $(request.method)")
            request.target == "/request" || error("expected /request target, got $(request.target)")
            HT.write_response!(conn, trim_text_response("h1-request"))
            closewrite(conn)
        finally
            HT.body_close!(request.body)
        end
    finally
        _HTTP_TRIM_H1_REQUEST_DONE[] = true
        try
            close(conn)
        catch
        end
    end
    return nothing
end

Base.Experimental.entrypoint(_http_trim_h1_request_server_entry, ())

function run_http_trim_client_h1_request()::Nothing
    listener::Union{Nothing,Reseau.TCP.Listener} = nothing
    server_task::Union{Nothing,Task} = nothing
    try
        listener = Reseau.TCP.listen(Reseau.TCP.loopback_addr(0); backlog = 16)
        _HTTP_TRIM_H1_REQUEST_LISTENER[] = listener
        _HTTP_TRIM_H1_REQUEST_STARTED[] = false
        _HTTP_TRIM_H1_REQUEST_DONE[] = false

        server_task = errormonitor(Task(_http_trim_h1_request_server_entry))
        schedule(server_task)
        start_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_H1_REQUEST_STARTED[], 5.0; pollint = 0.001)
        start_status == :timed_out && error("timed out waiting for trim H1 request server task")

        addr = Reseau.TCP.addr(listener)::Reseau.TCP.SocketAddrV4
        port = Int(addr.port)
        url = "http://127.0.0.1:$(port)/request"

        response = HT.request("GET", url;
            proxy = HT.ProxyConfig(),
            protocol = :h1,
            retry = false,
            redirect = false,
            cookies = false,
            verbose = false,
        )
        response.status == 200 || error("expected 200 response, got $(response.status)")
        body = response.body
        body isa Vector{UInt8} || error("expected Vector{UInt8} response body")
        String(body::Vector{UInt8}) == "h1-request" || error("unexpected response body")
    finally
        _HTTP_TRIM_H1_REQUEST_LISTENER[] = nothing
        try
            listener === nothing || close(listener::Reseau.TCP.Listener)
        catch
        end
        try
            if server_task !== nothing
                done_status = Reseau.IOPoll.timedwait(() -> _HTTP_TRIM_H1_REQUEST_DONE[] || istaskdone(server_task::Task), 5.0; pollint = 0.001)
                done_status == :timed_out && error("timed out waiting for trim H1 request server task shutdown")
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
    run_http_trim_client_h1_request()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
