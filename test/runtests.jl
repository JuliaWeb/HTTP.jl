using Distributed
addprocs(5)

using Test
using HTTP

@testset "HTTP" begin
    for f in [
            "ascii.jl",
            "issue_288.jl",
            "utils.jl",
            "sniff.jl",
            "uri.jl",
            "url.jl",
            "cookies.jl",
            "parser.jl",
            "loopback.jl",
            "WebSockets.jl",
            "messages.jl",
            "handlers.jl",
            "server.jl",
            "async.jl",
            "aws4.jl",
            "multipart.jl",
            "parsemultipart.jl"
        ]

        @info("Running $f tests...")
        include(f)
    end
end
