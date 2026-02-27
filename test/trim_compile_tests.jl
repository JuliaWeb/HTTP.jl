using Test

const _TRIM_SAFE_ERROR_BUDGET = @static if Sys.isapple()
    0
elseif Sys.iswindows()
    0
elseif Sys.islinux()
    0
else
    typemax(Int)
end

function _run_trim_compile(project_path::String, script_path::String, output_name::String)
    julia_exe = joinpath(Sys.BINDIR, Base.julia_exename())
    cmd = `$julia_exe --startup-file=no --history-file=no --code-coverage=none --project=$project_path -e "using JuliaC; JuliaC.main(ARGS)" -- --output-exe $output_name --project=$project_path --experimental --trim=safe $script_path`
    io = IOBuffer()
    proc = run(pipeline(ignorestatus(cmd), stdout=io, stderr=io))
    return proc.exitcode, String(take!(io))
end

function _parse_trim_verify_totals(output::String)
    m = match(r"Trim verify finished with\s+(\d+)\s+errors,\s+(\d+)\s+warnings\.", output)
    m === nothing && return nothing
    return parse(Int, m.captures[1]), parse(Int, m.captures[2])
end

@testset "Trim compile" begin
    project_path = normpath(joinpath(@__DIR__, ".."))
    script_path = joinpath(@__DIR__, "http_trim_safe.jl")
    @test isfile(script_path)

    mktempdir() do tmpdir
        cd(tmpdir) do
            output_name = "http_trim_safe"
            exit_code, output = _run_trim_compile(project_path, script_path, output_name)

            totals = _parse_trim_verify_totals(output)
            trim_errors, trim_warnings = if totals === nothing
                exit_code == 0 ? (0, 0) : error("failed to parse trim verifier summary:\n$output")
            else
                totals
            end

            if get(ENV, "HTTP_TRIM_PRINT_OUTPUT", "0") == "1" || trim_errors > 0
                println("---- trim compile output ----")
                println(output)
                println("---- end trim compile output ----")
            end

            @test trim_errors <= _TRIM_SAFE_ERROR_BUDGET
            @test trim_warnings >= 0

            output_path = Sys.iswindows() ? "$(output_name).exe" : output_name
            if trim_errors == 0
                @test exit_code == 0
                @test isfile(output_path)
            else
                @test exit_code != 0
            end
        end
    end
end
