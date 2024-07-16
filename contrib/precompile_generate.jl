function gen_single_tracefile(
        code::AbstractString,
        tracefile::AbstractString,
    )
    julia_binary = Base.julia_cmd().exec[1]
    cmd = `$(julia_binary)`
    push!(cmd.exec, "--compile=all")
    push!(cmd.exec, "--trace-compile=$(tracefile)")
    push!(cmd.exec, "-e $(code)")
    splitter = Sys.iswindows() ? ';' : ':'
    project = Base.active_project()
    env2 = copy(ENV)
    env2["JULIA_LOAD_PATH"] = "$(project)$(splitter)@stdlib"
    env2["JULIA_PROJECT"] = "$(project)"
    run(setenv(cmd, env2))
    return nothing
end

function gen_single_precompile(code::AbstractString)
    str = mktempdir() do dir
        tracefile = joinpath(dir, "tracefile")
        gen_single_tracefile(code, tracefile)
        return read(tracefile, String)::String
    end::String
    lines = convert(
        Vector{String},
        strip.(split(strip(str), '\n')),
    )::Vector{String}
    filter!(line -> !isempty(line), lines)
    return lines
end

function gen_all_precompile()
    codes = String[
        "import HTTP; HTTP.get(\"https://example.com/\")",
    ]
    all_lines = String[]
    for code in codes
        lines = gen_single_precompile(code)
        append!(all_lines, lines)
    end
    unique!(all_lines)
end

function write_all_precompile(io::IO, all_lines::Vector{String})
    preamble_lines = String[
        "import MbedTLS",
        "const MbedTLS_jll = MbedTLS.MbedTLS_jll"
    ]
    for line in preamble_lines
        println(io, line)
    end
    println(io)
    println(io, """
    function _precompile()
    """)
    println(io, """
        if ccall(:jl_generating_output, Cint, ()) != 1
            return nothing
        end
    """)
    println(io, """
        @static if Base.VERSION < v"1.9-"
            # We need https://github.com/JuliaLang/julia/pull/43990, otherwise this isn't worth doing.
            return nothing
        end
    """)
    for line in all_lines
        println(io, "    ", line)
    end
    println(io)
    println(io, """
        return nothing
    end
    """)
    return nothing
end

function write_all_precompile(
        output_file::AbstractString,
        all_lines::Vector{String},
    )
    open(output_file, "w") do io
        write_all_precompile(io, all_lines)
    end
    return nothing
end

function main()
    output_file = joinpath(dirname(@__DIR__), "src", "precompile.jl")
    all_lines = gen_all_precompile()
    write_all_precompile(output_file, all_lines)
    return nothing
end

main()
