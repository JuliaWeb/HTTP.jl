using Test
using HTTP
using HTTP.IOExtras, HTTP.Sockets, HTTP.WebSockets
using Sockets

@testset "WebSockets" begin
    p = 8085 # rand(8000:8999)
    socket_type = ["wss", "ws"]

    function listen_localhost()
        @async HTTP.listen(Sockets.localhost, p) do http
            if WebSockets.is_upgrade(http.message)
                WebSockets.upgrade(http) do ws
                    while !eof(ws)
                        data = readavailable(ws)
                        write(ws, data)
                    end
                end
            end
        end
    end

    if !isempty(get(ENV, "PIE_SOCKET_API_KEY", "")) && get(ENV, "JULIA_VERSION", "") == "1"
        println("found pie socket api key, running External Host websocket tests")
        pie_socket_api_key = ENV["PIE_SOCKET_API_KEY"]
        @testset "External Host - $s" for s in socket_type
            WebSockets.open("$s://free3.piesocket.com/v3/http_test_channel?api_key=$pie_socket_api_key&notify_self") do ws
                write(ws, "Foo")
                @test !eof(ws)
                @test String(readavailable(ws)) == "Foo"

                write(ws, "Foo"," Bar")
                @test !eof(ws)
                @test String(readavailable(ws)) == "Foo Bar"

                # send fragmented message manually with ping in between frames
                WebSockets.wswrite(ws, ws.frame_type, "Hello ")
                WebSockets.wswrite(ws, WebSockets.WS_FINAL | WebSockets.WS_PING, "things")
                WebSockets.wswrite(ws, WebSockets.WS_FINAL, "again!")
                @test String(readavailable(ws)) == "Hello again!"

                write(ws, "Hello")
                write(ws, " There")
                write(ws, " World", "!")
                IOExtras.closewrite(ws)

                buf = IOBuffer()
                # write(buf, ws)
                @test_skip String(take!(buf)) == "Hello There World!"
            end
        end
    end

    @testset "Localhost" begin
        listen_localhost()

        WebSockets.open("ws://127.0.0.1:$(p)") do ws
            write(ws, "Foo")
            @test String(readavailable(ws)) == "Foo"

            write(ws, "Bar")
            @test String(readavailable(ws)) == "Bar"

            write(ws, "This", " is", " a", " fragmented", " message.")
            @test String(readavailable(ws)) == "This is a fragmented message."

            # send fragmented message manually with ping in between frames
            WebSockets.wswrite(ws, ws.frame_type, "Ping ")
            WebSockets.wswrite(ws, WebSockets.WS_FINAL | WebSockets.WS_PING, "stuff")
            WebSockets.wswrite(ws, WebSockets.WS_FINAL, "pong!")
            @test String(readavailable(ws)) == "Ping pong!"
        end
    end

    @testset "Extended feature support for listen" begin
        port=UInt16(8086)
        tcpserver = listen(port)
        target = "/query?k1=v1&k2=v2"

        servertask =  @async WebSockets.listen("127.0.0.1", port; server=tcpserver) do ws
            @test ws.request isa HTTP.Request
            write(ws, ws.request.target)
            while !eof(ws)
                write(ws, readavailable(ws))
            end
            close(ws)
        end

        WebSockets.open("ws://127.0.0.1:$(port)$(target)") do ws
            @test String(readavailable(ws)) == target
            @test write(ws, "Bye!") == 4
            @test String(readavailable(ws)) == "Bye!"
            close(ws)
        end

        close(tcpserver)
        @test timedwait(()->servertask.state === :failed, 5.0) === :ok
        @test_throws Exception wait(servertask)
    end
end
