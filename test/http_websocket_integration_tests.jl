using Test
using HTTP
using Reseau

const HT = HTTP
const W = HTTP.WebSockets
const NC = Reseau.TCP
const ND = Reseau.HostResolvers

function _close_ws_quiet!(x)
    x === nothing && return nothing
    HTTP.@try_ignore begin
        if x isa HT.WebSockets.Server
            close(x)
        elseif x isa NC.Listener
            NC.close(x)
        elseif x isa NC.Conn
            NC.close(x)
        elseif x isa Task
            wait(x)
        end
    end
    return nothing
end

@testset "HTTP.WebSockets multiple concurrent writers" begin
    server = W.listen!("127.0.0.1", 0) do ws
        send_tasks = Task[]
        for i in 1:10
            push!(send_tasks, errormonitor(Threads.@spawn W.send(ws, string(i))))
        end
        for task in send_tasks
            wait(task)
        end
        @test W.receive(ws) == "ok"
    end
    try
        address = W.server_addr(server)
        ws = W.open("ws://$address/writers")
        try
            received = Set{String}()
            for _ in 1:10
                push!(received, W.receive(ws))
            end
            @test received == Set(string(i) for i in 1:10)
            W.send(ws, "ok")
        finally
            close(ws)
        end
    finally
        close(server)
    end
end

@testset "HTTP.WebSockets iterate drains buffered messages on close race" begin
    # Regression test for race in Base.iterate(ws::WebSocket): when the server
    # pushes N messages then closes, the client iterating with `for msg in ws`
    # must see all N messages even though isclosed(ws) becomes true while
    # messages are still buffered in ws.readchannel. Repeat 10 times because
    # the underlying race is intermittent.
    N = 50
    for trial in 1:10
        server = W.listen!("127.0.0.1", 0) do ws
            for i in 1:N
                W.send(ws, "msg_$i")
            end
            # Handler returns; auto-close path runs concurrently with client
            # read task; this is the race that must not drop buffered messages.
        end
        try
            address = W.server_addr(server)
            received = String[]
            W.open("ws://$address/iterdrain") do ws
                for msg in ws
                    push!(received, msg isa String ? msg : String(msg))
                end
            end
            @test length(received) == N
            if length(received) == N
                @test received == ["msg_$i" for i in 1:N]
            end
        finally
            close(server)
        end
    end
end

@testset "HTTP.WebSockets handler return after internal close preserves real close code" begin
    # Regression test for the auto-close override: when an internal frame
    # error queues a non-1000 close (e.g. 1009 frame too large) and the
    # user-supplied handler returns normally (catching the WebSocketError
    # and breaking), the server-side auto-close should send the queued
    # close code, not 1000.
    server = W.listen!("127.0.0.1", 0; maxframesize = 4) do ws
        try
            for msg in ws
                # consume — the oversized frame triggers a 1009 internally
            end
        catch err
            err isa W.WebSocketError || rethrow(err)
            # Swallow: handler returns normally so the auto-close path runs.
        end
    end
    try
        address = W.server_addr(server)
        client_err = nothing
        W.open("ws://$address/oversized") do ws
            # 5 bytes > maxframesize=4 → server queues 1009 internally
            W.send(ws, "toolong")
            try
                W.receive(ws)
            catch err
                client_err = err
            end
        end
        @test client_err isa W.WebSocketError
        @test client_err !== nothing && (client_err::W.WebSocketError).message.code == 1009
    finally
        close(server)
    end
end

@testset "HTTP.WebSockets client uses forward proxy absolute-form and proxy auth" begin
    listener = nothing
    task = nothing
    ws = nothing
    try
        listener = NC.listen("tcp", "127.0.0.1:0")
        laddr = NC.addr(listener)::NC.SocketAddrV4
        proxy_address = ND.join_host_port("127.0.0.1", Int(laddr.port))
        task = errormonitor(Threads.@spawn begin
            conn = NC.accept(listener)
            try
                request = HT.read_request(HT._ConnReader(conn))
                @test request.target == "http://example.com:80/proxied"
                @test HT.header(request.headers, "Proxy-Authorization") == "Basic dXNlcjpwYXNz"
                headers = HT.Headers()
                HT.setheader(headers, "Upgrade", "websocket")
                HT.setheader(headers, "Connection", "Upgrade")
                key = HT.WebSockets.ws_get_request_sec_websocket_key(request)
                key === nothing && error("missing websocket key")
                HT.setheader(headers, "Sec-WebSocket-Accept", HT.WebSockets.ws_compute_accept_key(key))
                io = IOBuffer()
                HT.write_response!(io, HT.Response(101, HT.EmptyBody(); headers = headers, content_length = 0))
                write(conn, take!(io))
                frame = HT.WebSockets.WsFrame(opcode = UInt8(HT.WebSockets.WsOpcode.TEXT), payload = Vector{UInt8}("proxied"), fin = true)
                encoded = HT.WebSockets.ws_encode_frame(frame)
                write(conn, encoded, length(encoded))
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end)
        ws = W.open("ws://example.com/proxied"; proxy = "http://user:pass@$proxy_address")
        @test W.receive(ws) == "proxied"
    finally
        ws === nothing || HTTP.@try_ignore close(ws)
        _close_ws_quiet!(listener)
        _close_ws_quiet!(task)
    end
end
