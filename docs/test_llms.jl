using Test

@testset "LLM documentation" begin
    # Aliases and macros must use the same docstrings as Documenter.
    for entry in ("HTTP.WebSockets", "HTTP.@client", "HTTP.Request", "HTTP.request")
        @test !isempty(llms_docstrings(llms_binding(entry, Main)))
    end
    full = read(joinpath(@__DIR__, "build", "llms-full.txt"), String)
    @test occursin("### `HTTP.request`", full)
    @test occursin("### `HTTP.WebSockets`", full)
    @test !occursin(r"```@(docs|meta|contents)", full)
    @test !occursin(r"\]\(@ref", full)
    @test_throws ErrorException llms_emit_docstrings!(String[], "HTTP.missing_llms_binding", Main, "fixture.md")
    @test llms_render_prose_line("[Client](guides/client.md)", "index.md", LLMS_SITE_ROOT) ==
        "[Client](" * LLMS_SITE_ROOT * "guides/client/)"
end
