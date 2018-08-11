using Base64, Sockets, Dates
using HTTP
using HTTP.IOExtras, HTTP.Sockets

@testset "WebSockets" begin

for s in ["wss", "ws"]

    HTTP.WebSockets.open("$s://echo.websocket.org") do io
        println("writing")
        write(io, "Foo")
        println("testing")
        @test !eof(io)
        @test String(readavailable(io)) == "Foo"

        println("writing again")
        write(io, "Hello")
        write(io, " There")
        write(io, " World", "!")
        println("closewrite")
        closewrite(io)

        println("reading response")
        buf = IOBuffer()
        write(buf, io)
        @test String(take!(buf)) == "Hello There World!"
    end

end

p = 8085 # rand(8000:8999)
@async HTTP.listen(Sockets.localhost, p) do http
    if HTTP.WebSockets.is_upgrade(http.message)
        HTTP.WebSockets.upgrade(http) do ws
            while !eof(ws)
                data = readavailable(ws)
                write(ws, data)
            end
        end
    end
end

sleep(2)

println("Testing local server...")
HTTP.WebSockets.open("ws://127.0.0.1:$(p)") do ws
    write(ws, "Foo")
    @test String(readavailable(ws)) == "Foo"

    write(ws, "Bar")
    @test String(readavailable(ws)) == "Bar"
end


end # testset
