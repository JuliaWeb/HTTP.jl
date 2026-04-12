using Test

const EXAMPLES_DIR = normpath(joinpath(@__DIR__, "..", "docs", "examples"))

@testset "examples — no deprecated JSON3" begin
    @test isdir(EXAMPLES_DIR)

    example_files = String[]
    for (root, _dirs, files) in walkdir(EXAMPLES_DIR)
        for f in files
            if endswith(f, ".jl")
                push!(example_files, joinpath(root, f))
            end
        end
    end

    @test !isempty(example_files)

    for path in example_files
        contents = read(path, String)
        @testset "$(relpath(path, EXAMPLES_DIR))" begin
            @test !occursin("JSON3", contents)
            @test !occursin("StructTypes", contents)
        end
    end
end
