using Test

function _log_test_progress(msg::AbstractString)
    println(msg)
    flush(stdout)
    return nothing
end

_log_test_progress("[runtests] loading HTTP + Reseau")
using HTTP
using Reseau
_log_test_progress("[runtests] loaded HTTP + Reseau")
_log_test_progress("[runtests] julia threads: $(Threads.nthreads())")

const ND = Reseau.HostResolvers
const NC = Reseau.TCP
const IP = Reseau.IOPoll

function _include_with_progress(path::AbstractString)
    _log_test_progress("[runtests] include START: $(path)")
    include(path)
    _log_test_progress("[runtests] include DONE: $(path)")
    return nothing
end

function _run_test_file(path::AbstractString)
    try
        _include_with_progress(path)
    finally
        _http_quiesce_windows_state!(path)
    end
    return nothing
end

@inline function _http_windows_ci()::Bool
    return Sys.iswindows() &&
           get(ENV, "GITHUB_ACTIONS", "false") == "true"
end

@inline function _http_windows_ci_warmup()::Bool
    return _http_windows_ci()
end

const _HTTP_WINDOWS_WARMED = Ref(false)

function _http_close_quiet!(x)
    x === nothing && return nothing
    try
        close(x)
    catch
    end
    return nothing
end

function _http_wait_task_done(task::Task; timeout_s::Float64 = 3.0)::Bool
    deadline = time() + timeout_s
    while time() < deadline
        istaskdone(task) && return true
        sleep(0.01)
    end
    return istaskdone(task)
end

function _http_write_all_tcp!(conn::NC.Conn, bytes::Vector{UInt8})::Nothing
    total = 0
    while total < length(bytes)
        n = write(conn, bytes[(total + 1):end])
        n > 0 || error("expected write progress")
        total += n
    end
    return nothing
end

function _http_send_warmup_response!(conn::NC.Conn, request::HTTP.Request)::Nothing
    payload = collect(codeunits("windows-warmup:" * request.target))
    response = HTTP.Response(
        200;
        body = HTTP.BytesBody(payload),
        content_length = length(payload),
        request = request,
    )
    io = IOBuffer()
    HTTP.write_response!(io, response)
    _http_write_all_tcp!(conn, take!(io))
    return nothing
end

function _http_ipv6_supported()::Bool
    listener = nothing
    try
        listener = NC.listen("tcp6", "[::1]:0"; backlog = 1)
        return true
    catch
        return false
    finally
        _http_close_quiet!(listener)
        IP.shutdown!()
    end
end

function _http_warm_windows_resolver_paths!()::Nothing
    _http_windows_ci_warmup() || return nothing
    _HTTP_WINDOWS_WARMED[] && return nothing
    _HTTP_WINDOWS_WARMED[] = true

    listener = nothing
    client = nothing
    server = nothing
    try
        listener = NC.listen("tcp", "127.0.0.1:0"; backlog = 4)
        port = Int((NC.addr(listener)::NC.SocketAddrV4).port)
        accept_task = errormonitor(Threads.@spawn NC.accept(listener))
        client = NC.connect("tcp", ND.join_host_port("127.0.0.1", port); timeout_ns = 3_000_000_000)
        _http_wait_task_done(accept_task) || error("HTTP Windows warmup accept timed out")
        server = fetch(accept_task)
    finally
        _http_close_quiet!(server)
        _http_close_quiet!(client)
        _http_close_quiet!(listener)
        IP.shutdown!()
    end

    _http_ipv6_supported() || return nothing

    listener = nothing
    client = nothing
    server = nothing
    try
        listener = NC.listen("tcp6", "[::1]:0"; backlog = 4)
        port = Int((NC.addr(listener)::NC.SocketAddrV6).port)
        resolver = ND.StaticResolver(hosts = Dict(
            "warmup.test" => NC.SocketEndpoint[
                NC.loopback_addr(port),
                NC.loopback_addr6(port),
            ],
        ))
        accept_task = errormonitor(Threads.@spawn NC.accept(listener))
        client = NC.connect(
            "tcp",
            "warmup.test:$port";
            resolver = resolver,
            local_addr = NC.loopback_addr6(0),
            fallback_delay_ns = 5_000_000_000,
        )
        _http_wait_task_done(accept_task) || error("HTTP Windows IPv6 warmup accept timed out")
        server = fetch(accept_task)
    finally
        _http_close_quiet!(server)
        _http_close_quiet!(client)
        _http_close_quiet!(listener)
        IP.shutdown!()
    end

    listener = nothing
    try
        listener = NC.listen("tcp4", "127.0.0.1:0"; backlog = 4)
        port = Int((NC.addr(listener)::NC.SocketAddrV4).port)
        close(listener)
        listener = nothing
        resolver = ND.StaticResolver(hosts = Dict(
            "warmup-fail.test" => NC.SocketEndpoint[
                NC.loopback_addr6(port),
                NC.loopback_addr(port),
            ],
        ))
        err = try
            NC.connect(
                "tcp",
                "warmup-fail.test:$port";
                resolver = resolver,
                timeout_ns = 1_500_000_000,
                fallback_delay_ns = 1_000_000,
            )
            nothing
        catch ex
            ex
        end
        err isa ND.OpError || error("expected Windows warmup fallback failure, got $(typeof(err))")
    finally
        _http_close_quiet!(listener)
        IP.shutdown!()
    end
    return nothing
end

function _http_warm_windows_client_paths!()::Nothing
    _http_windows_ci_warmup() || return nothing
    success = false
    last_err = nothing
    for _ in 1:6
        listener = nothing
        server_task = nothing
        try
            listener = NC.listen("tcp", "127.0.0.1:0"; backlog = 4)
            port = Int((NC.addr(listener)::NC.SocketAddrV4).port)
            address = ND.join_host_port("127.0.0.1", port)
            server_task = Threads.@spawn begin
                conn = NC.accept(listener)
                try
                    request = HTTP.read_request(HTTP._ConnReader(conn))
                    _http_send_warmup_response!(conn, request)
                finally
                    _http_close_quiet!(conn)
                end
                return nothing
            end
            response = HTTP.get(
                "http://$(address)/ok";
                proxy = HTTP.ProxyConfig(),
                connect_timeout = 0.25,
                readtimeout = 0.25,
            )
            String(response.body) == "windows-warmup:/ok" || error("unexpected HTTP Windows warmup response")
            _http_wait_task_done(server_task; timeout_s = 3.0) || error("HTTP Windows warmup server task timed out")
            fetch(server_task)
            success = true
            break
        catch err
            last_err = err
            sleep(0.05)
        finally
            _http_close_quiet!(listener)
            server_task !== nothing && _http_wait_task_done(server_task; timeout_s = 0.5)
            IP.shutdown!()
        end
    end
    success || throw(last_err === nothing ? ErrorException("HTTP Windows warmup failed without an error") : last_err)
    return nothing
end

function _http_reset_default_client!()::Nothing
    client = nothing
    lock(HTTP._DEFAULT_CLIENT_LOCK)
    try
        client = HTTP._DEFAULT_CLIENT[]
        HTTP._DEFAULT_CLIENT[] = nothing
    finally
        unlock(HTTP._DEFAULT_CLIENT_LOCK)
    end
    client === nothing || close(client)
    return nothing
end

function _http_quiesce_windows_state!(label::AbstractString)::Nothing
    _http_windows_ci() || return nothing
    _log_test_progress("[runtests] windows quiesce START: $(label)")
    _http_reset_default_client!()
    GC.gc()
    yield()
    IP.shutdown!()
    _log_test_progress("[runtests] windows quiesce DONE: $(label)")
    return nothing
end

test_files = [
    "http_core_tests.jl",
    "http1_wire_tests.jl",
    "http_cookie_tests.jl",
    "http_forms_tests.jl",
    "http_handlers_tests.jl",
    "http_websocket_codec_tests.jl",
    "http_websocket_client_tests.jl",
    "http_websocket_server_tests.jl",
    "http_websocket_integration_tests.jl",
    "http_retry_tests.jl",
    "http_client_transport_tests.jl",
    "http_client_proxy_tests.jl",
    "http_client_tests.jl",
    "http_server_http1_tests.jl",
    "hpack_tests.jl",
    "http2_frame_tests.jl",
    "http2_client_tests.jl",
    "http2_server_tests.jl",
    "http_integration_tests.jl",
    "http_parity_tests.jl",
    "trim_compile_tests.jl",
]

if _http_windows_ci_warmup()
    @testset "HTTP Windows resolver warmup" begin
        _http_warm_windows_resolver_paths!()
        _http_warm_windows_client_paths!()
        @test true
    end
end

for test_file in test_files
    _run_test_file(test_file)
end

if get(ENV, "HTTP_RUN_WEBSOCKET_AUTOBAHN", "") == "1"
    _run_test_file("http_websocket_autobahn.jl")
end
