using Test, Sockets
using HTTP
using HTTP.WebSockets

@testset "WebSockets.open over a raw IO" begin
    port = 8234
    server = WebSockets.listen!("127.0.0.1", port) do ws
        # echo back, and surface the request target the client used
        WebSockets.send(ws, "target:" * ws.request.target)
        for msg in ws
            WebSockets.send(ws, "echo: " * msg)
        end
    end

    try
        @testset "echo round-trip over a connected TCPSocket" begin
            sock = Sockets.connect("127.0.0.1", port)
            got = String[]
            WebSockets.open(sock; host="127.0.0.1:$port") do ws
                push!(got, WebSockets.receive(ws))
                WebSockets.send(ws, "hello")
                push!(got, WebSockets.receive(ws))
                WebSockets.send(ws, "world")
                push!(got, WebSockets.receive(ws))
            end
            @test got == ["target:/", "echo: hello", "echo: world"]
            # open() must not close the caller-owned transport: the socket is
            # still locally open (only the caller may close it). If the idle
            # monitor were spawned it would have closed this on EOF.
            @test isopen(sock)
            close(sock)
        end

        @testset "custom target keyword is sent in the request line" begin
            sock = Sockets.connect("127.0.0.1", port)
            target = nothing
            WebSockets.open(sock; target="/ws/v1", host="127.0.0.1:$port") do ws
                target = WebSockets.receive(ws)
            end
            @test target == "target:/ws/v1"
        end

        @testset "works with a non-socket IO type" begin
            # any IO is accepted, not just sockets: drive it through a TCP pair
            sock = Sockets.connect("127.0.0.1", port)
            io = IOContext(sock) # wrap so it's not a TCPSocket itself
            got = String[]
            WebSockets.open(io; host="127.0.0.1:$port") do ws
                push!(got, WebSockets.receive(ws)) # target line
                WebSockets.send(ws, "hi")
                push!(got, WebSockets.receive(ws))
            end
            @test got == ["target:/", "echo: hi"]
        end
    finally
        close(server)
    end
end
