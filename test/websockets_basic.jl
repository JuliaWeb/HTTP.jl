using Test
using HTTP
using HTTP.WebSockets

@testset "WebSockets ping/pong" begin
    server = HTTP.WebSockets.serve!("127.0.0.1", 0; listenany=true) do ws
        msg = receive(ws)
        send(ws, msg)
    end
    port = HTTP.port(server)
    try
        WebSockets.open("ws://127.0.0.1:$port") do ws
            @test_nowarn WebSockets.ping(ws)
            @test_nowarn WebSockets.pong(ws)
            send(ws, "ok")
            @test receive(ws) == "ok"
        end
    finally
        close(server)
    end
end
