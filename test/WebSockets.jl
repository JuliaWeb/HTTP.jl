using HTTP
using HTTP.WebSockets
using HTTP.IOExtras
using Base.Test

import HTTP.WebSockets: CONNECTED, CLOSING, CLOSED

@testset "WebSockets" begin

info("Testing ws...")
WebSockets.open("ws://echo.websocket.org") do ws
    write(ws, "Foo")
    @test String(read(ws)) == "Foo"

    close(ws)
end
sleep(1)

info("Testing wss...")
WebSockets.open("wss://echo.websocket.org") do ws
    write(ws, "Foo")
    @test String(read(ws)) == "Foo"

    close(ws)
end
sleep(1)

p = UInt16(8000)
@async HTTP.listen("127.0.0.1",p) do http
    if WebSockets.is_upgrade(http.message)
        WebSockets.upgrade(http) do ws
            while ws.state == CONNECTED
                data = String(read(ws))
                write(ws,data)
            end
        end
    end
end

sleep(2)

info("Testing local server...")
WebSockets.open("ws://127.0.0.1:$(p)") do ws
    write(ws, "Foo")
    @test String(read(ws)) == "Foo"

    write(ws, "Bar")
    @test String(read(ws)) == "Bar"

    close(ws)
end

end # testset
