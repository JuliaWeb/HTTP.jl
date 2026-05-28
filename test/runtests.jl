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

if _http_windows_ci()
    _run_test_file("windows_warmup.jl")
end

for test_file in test_files
    _run_test_file(test_file)
end

if get(ENV, "HTTP_RUN_WEBSOCKET_AUTOBAHN", "") == "1"
    _run_test_file("http_websocket_autobahn.jl")
end
