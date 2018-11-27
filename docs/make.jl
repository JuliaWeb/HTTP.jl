using Documenter, HTTP

makedocs(
    modules = [HTTP],
    sitename = "HTTP.jl",
    pages = [
             "Home" => "index.md",
             "public_interface.md",
             "internal_architecture.md",
             "internal_interface.md",
             ],
)

deploydocs(
    repo = "github.com/JuliaWeb/HTTP.jl.git",
)
