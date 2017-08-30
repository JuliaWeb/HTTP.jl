using Documenter, HTTP

makedocs(
    modules = [HTTP],
    format = :html,
    sitename = "HTTP.jl",
    pages = ["Home" => "index.md"]
)

deploydocs(
    repo = "github.com/JuliaWeb/HTTP.jl.git",
    target = "build",
    deps = nothing,
    make = nothing,
    julia = "nightly",
    osname = "linux"
)
