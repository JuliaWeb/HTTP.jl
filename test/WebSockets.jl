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
    end

end

p = UInt16(8000)
@async HTTP.listen("127.0.0.1",p) do http
    if HTTP.WebSockets.is_upgrade(http.message)
        HTTP.WebSockets.upgrade(http) do ws
            while !eof(ws)
                data = readavailable(ws)
                write(ws,data)
            end
        end
    end
end

sleep(2)

info("Testing local server...")
HTTP.WebSockets.open("ws://127.0.0.1:$(p)") do ws
    write(ws, "Foo")
    @test String(readavailable(ws)) == "Foo"

    write(ws, "Bar")
    @test String(readavailable(ws)) == "Bar"
end


end # testset
