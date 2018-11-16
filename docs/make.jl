using Documenter, HTTP

makedocs(
    modules = [HTTP],
    sitename = "HTTP.jl",
    pages = ["Home" => "index.md"]
)

deploydocs(
    repo = "github.com/JuliaWeb/HTTP.jl.git",
)
