using Test
using HTTP
using HTTP.IOExtras, HTTP.Sockets

@testset "websockets.jl" begin
    p = 8085 # rand(8000:8999)
    socket_type = ["wss", "ws"]

    function listen_localhost()
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
    end

    @testset "External Host - $s" for s in socket_type
        HTTP.WebSockets.open("$s://echo.websocket.org") do io
            write(io, "Foo")
            @test !eof(io)
            @test String(readavailable(io)) == "Foo"

            write(io, "Hello")
            write(io, " There")
            write(io, " World", "!")
            closewrite(io)

            buf = IOBuffer()
            write(buf, io)
            @test String(take!(buf)) == "Hello There World!"
        end
    end

    @testset "Localhost" begin
       listen_localhost()

        HTTP.WebSockets.open("ws://127.0.0.1:$(p)") do ws
            write(ws, "Foo")
            @test String(readavailable(ws)) == "Foo"

            write(ws, "Bar")
            @test String(readavailable(ws)) == "Bar"
        end
    end
end