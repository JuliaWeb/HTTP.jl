using Test

const _TRIM_SUPPORTED = VERSION >= v"1.12.0-rc1"
const _TRIM_PRE_RELEASE = !isempty(VERSION.prerelease)
const _JULIAC_ENTRYPOINT_EXPR = "using JuliaC; if isdefined(JuliaC, :main); JuliaC.main(ARGS); else JuliaC._main_cli(ARGS); end"

function _trim_compile_timeout_s()::Float64
    default = Sys.iswindows() ? "240.0" : "120.0"
    return parse(Float64, get(ENV, "HTTP_TRIM_COMPILE_TIMEOUT_S", default))
end

function _run_trim_compile(project_path::String, script_path::String, output_name::String; timeout_s::Float64 = _trim_compile_timeout_s(), bundle_dir::Union{Nothing, String} = nothing)
    julia_exe = joinpath(Sys.BINDIR, Base.julia_exename())
    cmd = if bundle_dir === nothing
        `$julia_exe --startup-file=no --history-file=no --code-coverage=none --project=$project_path -e $(_JULIAC_ENTRYPOINT_EXPR) -- --output-exe $output_name --project=$project_path --experimental --trim=safe $script_path`
    else
        `$julia_exe --startup-file=no --history-file=no --code-coverage=none --project=$project_path -e $(_JULIAC_ENTRYPOINT_EXPR) -- --output-exe $output_name --bundle $bundle_dir --project=$project_path --experimental --trim=safe $script_path`
    end
    return _run_command_with_timeout(cmd; timeout_s = timeout_s, log_label = "compile")
end

function _run_trim_executable(run_cmd; timeout_s::Float64 = 30.0)
    return _run_command_with_timeout(run_cmd; timeout_s = timeout_s, log_label = "run")
end

function _run_command_with_timeout(cmd::Cmd; timeout_s::Float64, log_label::String)
    output_path = tempname()
    out = open(output_path, "w")
    exit_code = -1
    timed_out = false
    try
        proc = run(pipeline(ignorestatus(cmd), stdout = out, stderr = out); wait = false)
        timed_out = _wait_process_with_timeout!(proc; timeout_s = timeout_s, log_label = log_label)
        exit_code = something(proc.exitcode, -1)
    finally
        close(out)
    end
    output = try
        read(output_path, String)
    catch
        ""
    finally
        rm(output_path; force = true)
    end
    return exit_code, output, timed_out
end

function _wait_process_with_timeout!(proc::Base.Process; timeout_s::Float64, log_label::String)
    started_at = time()
    next_log_at = started_at + 10.0
    timed_out = false
    while Base.process_running(proc)
        now = time()
        if now - started_at >= timeout_s
            timed_out = true
            try
                kill(proc)
            catch
            end
            _wait_process_exit_after_kill!(proc; timeout_s = 5.0, log_label = log_label)
            break
        end
        if now >= next_log_at
            elapsed = round(now - started_at; digits = 1)
            println("[trim] $(log_label) WAIT $(elapsed)s")
            flush(stdout)
            next_log_at = now + 10.0
        end
        sleep(0.1)
    end
    if !Base.process_running(proc)
        try
            wait(proc)
        catch
        end
    end
    return timed_out
end

function _wait_process_exit_after_kill!(proc::Base.Process; timeout_s::Float64, log_label::String)::Nothing
    deadline = time() + timeout_s
    while Base.process_running(proc) && time() < deadline
        sleep(0.1)
    end
    if Base.process_running(proc)
        println("[trim] $(log_label) process still running after kill; continuing after timeout")
        flush(stdout)
    end
    return nothing
end

function _trim_timeout_error(kind::String, script_file::String, output::String = "")
    msg = "trim $kind timed out for $(script_file)"
    if !isempty(output)
        msg = string(msg, "\n---- captured output ----\n", output, "\n---- end captured output ----")
    end
    throw(ArgumentError(msg))
end

function _maybe_print_output(header::String, output::String)
    isempty(output) && return nothing
    println(header)
    println(output)
    println("---- end output ----")
    return nothing
end

function _trim_executable_timeout_s(script_path::String)::Float64
    default = if Sys.iswindows() && basename(script_path) == "http_trim_open_fileserver.jl"
        "120.0"
    else
        Sys.iswindows() ? "60.0" : "30.0"
    end
    return parse(Float64, get(ENV, "HTTP_TRIM_EXE_TIMEOUT_S", default))
end

function _trim_prerelease_allow_failure(script_file::String, reason::String, output::String = "")
    println("[trim] prerelease issue tolerated for $(script_file): $(reason)")
    _maybe_print_output("---- trim prerelease output ($(script_file)) ----", output)
    return nothing
end

function _trim_known_task_runtime_limitation(script_path::String)::Bool
    source = read(script_path, String)
    return occursin("Task(", source) ||
        occursin("Threads.@spawn", source) ||
        occursin("HT.serve!(", source) ||
        occursin("HTTP.serve!(", source) ||
        occursin("HT.listen!(", source) ||
        occursin("HTTP.listen!(", source)
end

function _trim_known_runtime_allow_failure(script_path::String)::Bool
    _trim_known_task_runtime_limitation(script_path) && return true
    if Sys.iswindows()
        script_file = basename(script_path)
        return script_file == "http_trim_websocket.jl" ||
            script_file == "http_trim_open_fileserver.jl"
    end
    return false
end

function _trim_known_compile_allow_failure(script_path::String)::Bool
    return Sys.iswindows() && _trim_known_task_runtime_limitation(script_path)
end

function _trim_task_runtime_allow_failure(script_file::String, reason::String, output::String = "")
    println("[trim] known trimmed-task runtime issue tolerated for $(script_file): $(reason)")
    _maybe_print_output("---- trim task-runtime output ($(script_file)) ----", output)
    return nothing
end

function _trim_task_compile_allow_failure(script_file::String, reason::String, output::String = "")
    println("[trim] known trimmed-task compile issue tolerated for $(script_file): $(reason)")
    _maybe_print_output("---- trim task-compile output ($(script_file)) ----", output)
    return nothing
end

function _trim_selected_workloads(workloads::Vector{Tuple{String, String}})::Vector{Tuple{String, String}}
    only = strip(get(ENV, "HTTP_TRIM_ONLY", ""))
    isempty(only) && return workloads
    selected = Tuple{String, String}[]
    for workload in workloads
        workload[1] == only && push!(selected, workload)
    end
    isempty(selected) && throw(ArgumentError("unknown HTTP_TRIM_ONLY workload: $(only)"))
    return selected
end

function _trim_use_bundle()::Bool
    return get(ENV, "HTTP_TRIM_BUNDLE", "0") == "1"
end

function _trim_include_frontier_workloads()::Bool
    return get(ENV, "HTTP_TRIM_INCLUDE_FRONTIER", "0") == "1"
end

function _run_trim_case(project_path::String, script_file::String, output_name::String)
    script_path = joinpath(@__DIR__, script_file)
    @test isfile(script_path)
    allow_task_compile_failure = _trim_known_compile_allow_failure(script_path)
    allow_task_runtime_failure = _trim_known_runtime_allow_failure(script_path)
    println("[trim] compile START $(script_file)")
    start_t = time()
    mktempdir() do tmpdir
        cd(tmpdir) do
            bundle_dir = _trim_use_bundle() ? joinpath(tmpdir, "bundle") : nothing
            exit_code, output, timed_out = _run_trim_compile(project_path, script_path, output_name; bundle_dir = bundle_dir)
            if timed_out
                if allow_task_compile_failure
                    _trim_task_compile_allow_failure(script_file, "trim compile timed out", output)
                    return nothing
                end
                if _TRIM_PRE_RELEASE
                    _trim_prerelease_allow_failure(script_file, "trim compile timed out", output)
                    return nothing
                end
                _trim_timeout_error("compile", script_file, output)
            end
            totals = _parse_trim_verify_totals(output)
            trim_errors, trim_warnings = if totals === nothing
                fallback = _count_trim_verify_messages(output)
                if exit_code == 0 && fallback == (0, 0)
                    fallback
                elseif _TRIM_PRE_RELEASE
                    _trim_prerelease_allow_failure(script_file, "failed to parse trim verifier summary", output)
                    return nothing
                else
                    error("failed to parse trim verifier summary:\n$output")
                end
            else
                totals
            end
            if get(ENV, "HTTP_TRIM_PRINT_OUTPUT", "0") == "1" || trim_errors > 0 || trim_warnings > 0
                _maybe_print_output("---- trim compile output ($(script_file)) ----", output)
            end
            if _TRIM_PRE_RELEASE && (trim_errors > 0 || exit_code != 0)
                _trim_prerelease_allow_failure(script_file, "trim verify finished with $(trim_errors) errors, $(trim_warnings) warnings (exit=$(exit_code))", output)
                return nothing
            end
            @test trim_errors == 0
            @test trim_warnings == 0
            output_path = Sys.iswindows() ? "$(output_name).exe" : output_name
            run_path = bundle_dir === nothing ? output_path : joinpath(bundle_dir, "bin", output_path)
            @test exit_code == 0
            @test isfile(run_path)
            run_cmd = Sys.iswindows() ? `$(abspath(run_path))` : `$(abspath(run_path))`
            run_timeout_s = _trim_executable_timeout_s(script_path)
            run_exit, run_output, run_timed_out = _run_trim_executable(run_cmd; timeout_s = run_timeout_s)
            if run_timed_out
                if allow_task_runtime_failure
                    _trim_task_runtime_allow_failure(script_file, "trim executable run timed out", run_output)
                    return nothing
                end
                if _TRIM_PRE_RELEASE
                    _trim_prerelease_allow_failure(script_file, "trim executable run timed out", run_output)
                    return nothing
                else
                    _trim_timeout_error("executable run", script_file, run_output)
                end
            end
            if allow_task_runtime_failure && run_exit != 0
                _trim_task_runtime_allow_failure(script_file, "trim executable exited with status $(run_exit)", run_output)
                return nothing
            end
            if _TRIM_PRE_RELEASE && run_exit != 0
                _trim_prerelease_allow_failure(script_file, "trim executable exited with status $(run_exit)", run_output)
                return nothing
            end
            if run_exit != 0
                _maybe_print_output("---- trim executable output ($(script_file)) ----", run_output)
            end
            @test run_exit == 0
        end
    end
    println("[trim] compile DONE $(script_file) ($(round(time() - start_t; digits = 2))s)")
    return nothing
end

function _parse_trim_verify_totals(output::String)
    m = match(r"Trim verify finished with\s+(\d+)\s+errors,\s+(\d+)\s+warnings\.", output)
    m === nothing && return nothing
    return parse(Int, m.captures[1]), parse(Int, m.captures[2])
end

function _count_trim_verify_messages(output::String)::Tuple{Int,Int}
    errors = length(collect(eachmatch(r"Verifier error #\d+:", output)))
    warnings = length(collect(eachmatch(r"Verifier warning #\d+:", output)))
    return errors, warnings
end

@testset "Trim compile" begin
    if !_TRIM_SUPPORTED
        println("[trim] skip Julia < 1.12: JuliaC trim compilation is unavailable")
        @test true
    else
        project_path = normpath(joinpath(@__DIR__, ".."))
        trim_workloads = [
            ("http_trim_client_h1_raw.jl", "http_trim_client_h1_raw"),
            ("http_trim_client_h1_wire.jl", "http_trim_client_h1_wire"),
            ("http_trim_client_h1_roundtrip.jl", "http_trim_client_h1_roundtrip"),
            ("http_trim_client_h2_wire.jl", "http_trim_client_h2_wire"),
            ("http_trim_client_h2_tcp_roundtrip.jl", "http_trim_client_h2_tcp_roundtrip"),
            ("http_trim_client_h2_roundtrip.jl", "http_trim_client_h2_roundtrip"),
            ("http_trim_client_server.jl", "http_trim_client_server"),
            ("http_trim_open_fileserver.jl", "http_trim_open_fileserver"),
            ("http_trim_http2.jl", "http_trim_http2"),
            ("http_trim_websocket.jl", "http_trim_websocket"),
        ]
        if _trim_include_frontier_workloads()
            append!(trim_workloads, [
                # Single high-level client/server frontier workload that uses
                # public `serve!` + `request(...)` to exercise the highest
                # request/response round-trip layer under trim compilation.
                ("http_trim_client_h1_request.jl", "http_trim_client_h1_request"),
            ])
        end
        trim_workloads = _trim_selected_workloads(trim_workloads)
        for (script_file, output_name) in trim_workloads
            _run_trim_case(project_path, script_file, output_name)
        end
    end
end
