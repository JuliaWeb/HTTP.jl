using HTTP
using HTTP.IOExtras

for s in ["ws", "wss"]

    HTTP.WebSockets.open("$s://echo.websocket.org") do io
        write(io, Vector{UInt8}("Foo"))
        @test !eof(io)
        @test String(readavailable(io)) == "Foo"

        write(io, Vector{UInt8}("Hello"))
        write(io, " There")
        write(io, " World", "!")
        closewrite(io)

        buf = IOBuffer()
        write(buf, io)
        @test String(take!(buf)) == "Hello There World!"

        close(io)
    end

end
