using Test
using HTTP.WebSockets

function write_message(ws, msg)
    send(ws, msg)
end

function client_twin(ws)
    for count in 1:10
        @async write_message(ws, count)
    end
end

function serve(ch)
    WebSockets.listen!("127.0.0.1", 8081) do ws
        client_twin(ws)
        response = receive(ws)
        put!(ch, response)
    end
end

ch = Channel(1)
srvtask = @async serve(ch)

WebSockets.open("ws://127.0.0.1:8081") do ws
    try
        while true
            s = receive(ws)
            if s == "10"
                send(ws, "ok")
            end
        end
    catch e
        if e.message.status !== 1000
            @error "Ws client: $e"
            !ws.writeclosed && send(ws, "error")
        end
    end
end;

@testset "WebSocket multiple writes" begin
    @test take!(ch) == "ok"
end
