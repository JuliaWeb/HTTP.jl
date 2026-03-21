using Documenter, HTTP

DocMeta.setdocmeta!(HTTP, :DocTestSetup, :(using HTTP); recursive = true)

makedocs(
    sitename = "HTTP.jl v$(HTTP.VERSION)",
    format = Documenter.HTML(
        prettyurls = true,
        canonical = "https://juliaweb.github.io/HTTP.jl/stable",
        collapselevel = 2,
    ),
    modules = [HTTP, HTTP.WebSockets],
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
    ],
    pagesonly = true,
    clean = true,
    checkdocs = :exports,
)

if get(ENV, "CI", "false") == "true"
    deploydocs(
        repo = "github.com/JuliaWeb/HTTP.jl.git",
        devbranch = "master",
        push_preview = true,
    )
end
