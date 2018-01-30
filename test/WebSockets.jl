using HTTP
using HTTP.Test
using HTTP.IOExtras

@testset "WebSockets" begin

for s in ["ws", "wss"]

    HTTP.WebSockets.open("$s://echo.websocket.org") do ws
        write(ws, HTTP.bytes("Foo"))
        @test !eof(ws)
        @test String(readavailable(ws)) == "Foo"

        write(ws, HTTP.bytes("Hello"))
        write(ws, " There")
        write(ws, " World", "!")
        closewrite(ws)

        io = IOBuffer()
        write(io, ws)
        @test String(take!(io)) == "Hello There World!"

        close(ws)
    end

end

end # testset
