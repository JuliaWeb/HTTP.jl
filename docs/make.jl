using Documenter, HTTP

include("llms.jl")

DocMeta.setdocmeta!(HTTP, :DocTestSetup, :(using HTTP); recursive = true)

pages = [
    "Home" => "index.md",
    "Guides" => [
        "Client" => "guides/client.md",
        "Server" => "guides/server.md",
        "Protocols" => "guides/protocols.md",
        "Migration from 1.x" => "guides/migration-1x.md",
    ],
    "API Reference" => [
        "Overview" => "api/reference.md",
        "Core" => "api/core.md",
        "Client" => "api/client.md",
        "Server" => "api/server.md",
        "WebSockets" => "api/websockets.md",
    ],
]

makedocs(
    sitename = "HTTP.jl v$(pkgversion(HTTP))",
    format = Documenter.HTML(
        prettyurls = true,
        canonical = "https://juliaweb.github.io/HTTP.jl/stable",
        collapselevel = 2,
    ),
    modules = [HTTP, HTTP.WebSockets],
    pages = pages,
    pagesonly = true,
    clean = true,
    checkdocs = :exports,
)

# `llms.txt` and `llms-full.txt` (https://llmstxt.org/) are plain-markdown renderings
# of the same pages, with every `@docs` block expanded. They are written after
# `makedocs` (which cleans the build directory first) so that `deploydocs` publishes
# them next to the HTML output, e.g. at `/stable/llms.txt` and `/stable/llms-full.txt`.
write_llms_files(joinpath(@__DIR__, "build"), pages)
include("test_llms.jl")

if get(ENV, "CI", "false") == "true"
    deploydocs(
        repo = "github.com/JuliaWeb/HTTP.jl.git",
        devbranch = "master",
        push_preview = true,
    )
end
