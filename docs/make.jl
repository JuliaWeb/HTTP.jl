# docs/make.jl
using Documenter, HTTP

makedocs(
    sitename = "HTTP.jl v$(HTTP.VERSION)",
    format = Documenter.HTML(),
    modules = [HTTP],
    pages = [
        "Home" => "index.md",
        "Manual" => [
            "Client Guide" => "manual/client.md",
            "Server Guide" => "manual/server.md",
            "Middleware Guide" => "manual/middleware.md",
            "WebSockets" => "manual/websockets.md",
            "Authentication" => "manual/authentication.md",
        ],
        "API Reference" => "api/reference.md"
    ],
    clean = true,
    strict = true,
)

if get(ENV, "DEPLOY_DOCS", "false") == "true"
    deploydocs(
        repo = "github.com/JuliaWeb/HTTP.jl.git",
        push_preview = true,
    )
end