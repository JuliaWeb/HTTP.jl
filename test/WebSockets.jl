using HTTP
using HTTP.Test
using HTTP.IOExtras

@testset "WebSockets" begin

for s in ["ws", "wss"]
    info("Testing $(s)...")
    HTTP.WebSockets.open("$s://echo.websocket.org") do ws
        write(ws, HTTP.bytes("Foo"))
        @test !eof(ws)
        @test String(readavailable(ws)) == "Foo"

        close(ws)
    end
end


p = 8000
@async HTTP.listen(ip"127.0.0.1",p) do http
    if HTTP.WebSockets.is_websocket_upgrade(http.message)
        HTTP.WebSockets.upgrade(http) do ws
            data = ""
            while !eof(ws);
                data = String(readavailable(ws))
                write(ws,data)
            end
        end
    end
end

sleep(2)

info("Testing local server...")
HTTP.WebSockets.open("ws://127.0.0.1:$(p)") do ws
    write(ws, HTTP.bytes("Foo"))
    @test !eof(ws)
    @test String(readavailable(ws)) == "Foo"

    close(ws)
end

end # testset
