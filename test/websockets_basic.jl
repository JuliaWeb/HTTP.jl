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

@testset "WebSockets fragmentation and close" begin
    server = HTTP.WebSockets.serve!("127.0.0.1", 0; listenany=true) do ws
        msg = receive(ws)
        send(ws, msg)
        WebSockets.close(ws, WebSockets.CloseFrameBody(1000, "bye"))
    end
    port = HTTP.port(server)
    try
        WebSockets.open("ws://127.0.0.1:$port") do ws
            send(ws, ["hel", "lo"])
            @test receive(ws) == "hello"
            try
                receive(ws)
                @test false
            catch e
                @test e isa WebSockets.WebSocketError
                @test WebSockets.isok(e)
                @test e.message.code == 1000
            end
        end
    finally
        close(server)
    end
end
