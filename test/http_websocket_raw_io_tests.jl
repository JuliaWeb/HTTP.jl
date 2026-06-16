using Test
using HTTP
using Reseau
using Sockets

const W = HTTP.WebSockets

@testset "HTTP.WebSockets.open over a raw IO" begin
    # Echo server that also surfaces the request target the client handshook with.
    server = W.listen!("127.0.0.1", 0) do ws
        W.send(ws, "target:" * ws.handshake_request.target)
        for msg in ws
            W.send(ws, "echo: " * (msg isa String ? msg : String(msg)))
        end
    end

    try
        host, port = Reseau.HostResolvers.split_host_port(W.server_addr(server))
        port = parse(Int, port)

        @testset "echo round-trip over a connected TCPSocket" begin
            sock = Sockets.connect(host, port)
            got = String[]
            W.open(sock; host="$host:$port") do ws
                push!(got, W.receive(ws))
                W.send(ws, "hello")
                push!(got, W.receive(ws))
                W.send(ws, "world")
                push!(got, W.receive(ws))
            end
            @test got == ["target:/", "echo: hello", "echo: world"]
            # open() must not close the caller-owned transport: only the caller
            # may close `sock`, so it is still locally open here.
            @test isopen(sock)
            close(sock)
        end

        @testset "custom target keyword is sent in the request line" begin
            sock = Sockets.connect(host, port)
            target = nothing
            W.open(sock; target="/ws/v1", host="$host:$port") do ws
                target = W.receive(ws)
            end
            @test target == "target:/ws/v1"
            close(sock)
        end

        @testset "non-function form returns a usable WebSocket" begin
            sock = Sockets.connect(host, port)
            ws = W.open(sock; host="$host:$port")
            try
                @test W.receive(ws) == "target:/"
                W.send(ws, "hi")
                @test W.receive(ws) == "echo: hi"
            finally
                close(ws)
            end
            @test isopen(sock)
            close(sock)
        end

        @testset "round-trip over a Base.Pipe forwarded to the server" begin
            # `open` runs the handshake over a duplex `Base.PipeEndpoint` (a
            # non-socket `Base.IO` whose `all=false` reads return 0 before data
            # arrives) rather than over the TCP socket directly. A pair of tasks
            # forwards bytes between the pipe's far end and a normal TCP
            # connection to the echo server above, so the whole exchange is
            # driven over a pipe.
            # A named pipe gives us a full-duplex `Base.PipeEndpoint`. The
            # address format differs by platform: Windows uses a `\\.\pipe\...`
            # name (not a filesystem path), other platforms a Unix-domain socket.
            pipename = "http_jl_ws_pipe_$(getpid())"
            sockpath = Sys.iswindows() ? "\\\\.\\pipe\\$pipename" : joinpath(mktempdir(), "$pipename.sock")
            relay = Sockets.listen(sockpath)
            client_pipe = Sockets.connect(sockpath)   # handed to open()
            bridge = Sockets.accept(relay)            # forwarded to the server
            close(relay)
            tcp = Sockets.connect(host, port)

            fwd_up = Threads.@spawn try
                while !eof(bridge)
                    write(tcp, readavailable(bridge))
                end
            finally
                close(tcp)
            end
            fwd_down = Threads.@spawn try
                while !eof(tcp)
                    write(bridge, readavailable(tcp))
                end
            finally
                close(bridge)
            end

            try
                @test client_pipe isa Base.PipeEndpoint
                got = String[]
                W.open(client_pipe) do ws
                    push!(got, W.receive(ws))
                    W.send(ws, "hello")
                    push!(got, W.receive(ws))
                end

                @test got == ["target:/", "echo: hello"]
            finally
                close(client_pipe)
                wait(fwd_up)
                wait(fwd_down)
            end
        end
    finally
        close(server)
    end
end
