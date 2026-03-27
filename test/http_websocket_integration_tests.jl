using Test
using HTTP
using Reseau

const HT = HTTP
const W = HTTP.WebSockets
const NC = Reseau.TCP
const ND = Reseau.HostResolvers

function _wait_ws_server_addr(server; timeout_s::Float64 = 5.0)
    _ = timeout_s
    return W.server_addr(server)
end

function _close_ws_quiet!(x)
    x === nothing && return nothing
    try
        if x isa HT.WebSockets.Server
            close(x)
        elseif x isa NC.Listener
            NC.close(x)
        elseif x isa NC.Conn
            NC.close(x)
        elseif x isa Task
            wait(x)
        end
    catch
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
        address = _wait_ws_server_addr(server)
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
                key = HT.ws_get_request_sec_websocket_key(request)
                key === nothing && error("missing websocket key")
                HT.setheader(headers, "Sec-WebSocket-Accept", HT.ws_compute_accept_key(key))
                io = IOBuffer()
                HT.write_response!(io, HT.Response(101; headers = headers, body = HT.EmptyBody(), content_length = 0))
                write(conn, take!(io))
                frame = HT.WsFrame(opcode = UInt8(HT.WsOpcode.TEXT), payload = Vector{UInt8}("proxied"), fin = true)
                encoded = HT.ws_encode_frame(frame)
                write(conn, encoded, length(encoded))
            finally
                try
                    NC.close(conn)
                catch
                end
            end
        end)
        ws = W.open("ws://example.com/proxied"; proxy = "http://user:pass@$proxy_address")
        @test W.receive(ws) == "proxied"
    finally
        ws === nothing || try close(ws) catch end
        _close_ws_quiet!(listener)
        _close_ws_quiet!(task)
    end
end
