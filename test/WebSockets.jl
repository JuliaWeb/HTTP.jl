using HTTP
using HTTP.Test
using HTTP.IOExtras

@testset "WebSockets" begin

for s in ["ws", "wss"]

    HTTP.WebSockets.open("$s://echo.websocket.org") do io
        write(io, HTTP.bytes("Foo"))
        @test !eof(io)
        @test String(readavailable(io)) == "Foo"

        write(io, HTTP.bytes("Hello"))
        write(io, " There")
        write(io, " World", "!")
        closewrite(io)

        buf = IOBuffer()
        write(buf, io)
        @test String(take!(buf)) == "Hello There World!"

        close(io)
    end

end

end # testset
