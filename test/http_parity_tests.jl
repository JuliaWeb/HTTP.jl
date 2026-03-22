using Test
using HTTP
using Reseau

const HT = HTTP
const ND = Reseau.HostResolvers
const NC = Reseau.TCP

function _read_all_parity(body::HT.AbstractBody)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 64)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
end

function _wait_task_parity!(task::Task; timeout_s::Float64 = 5.0)
    status = timedwait(() -> istaskdone(task), timeout_s; pollint = 0.001)
    status == :timed_out && error("timed out waiting for task")
    fetch(task)
    return nothing
end

@testset "HTTP parity framing guards" begin
    raw_204 = "HTTP/1.1 204 No Content\r\nContent-Length: 10\r\n\r\nignored"
    response_204 = HT._read_response(IOBuffer(codeunits(raw_204)))
    @test response_204.status == 204
    @test _read_all_parity(response_204.body) == UInt8[]
    bad_cl = "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nhi"
    @test_throws HT.ProtocolError HT._read_response(IOBuffer(codeunits(bad_cl)))
end

@testset "HTTP parity redirect semantics" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen_methods = String[]
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            push!(seen_methods, req1.method)
            headers = HT.Headers()
            HT.setheader(headers, "Location", "/next")
            HT.setheader(headers, "Connection", "close")
            resp1 = HT.Response(307; reason = "Temporary Redirect", headers = headers, body = HT.EmptyBody(), content_length = 0, close = true, request = req1)
            io1 = IOBuffer()
            HT.write_response!(io1, resp1)
            bytes1 = take!(io1)
            write(conn1, bytes1)
        finally
            try
                NC.close(conn1)
            catch
            end
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            push!(seen_methods, req2.method)
            resp2 = HT.Response(200; body = HT.BytesBody(UInt8[0x6f, 0x6b]), content_length = 2, request = req2)
            io2 = IOBuffer()
            HT.write_response!(io2, resp2)
            bytes2 = take!(io2)
            write(conn2, bytes2)
        finally
            try
                NC.close(conn2)
            catch
            end
        end
        return nothing
    end)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4))
    try
        request = HT.Request("POST", "/start"; host = address, body = HT.BytesBody(UInt8[0x61]), content_length = 1)
        response = HT.do!(client, address, request)
        @test response.status == 200
        @test String(_read_all_parity(response.body)) == "ok"
        _wait_task_parity!(server_task)
        @test seen_methods == ["POST", "POST"]
    finally
        close(client)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP parity 307 non-replayable body behavior" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            req = HT.read_request(HT._ConnReader(conn))
            _ = _read_all_parity(req.body)
            headers = HT.Headers()
            HT.setheader(headers, "Location", "/next")
            HT.setheader(headers, "Connection", "close")
            resp = HT.Response(307; reason = "Temporary Redirect", headers = headers, body = HT.BytesBody(UInt8[0x72]), content_length = 1, close = true, request = req)
            io = IOBuffer()
            HT.write_response!(io, resp)
            write(conn, take!(io))
        finally
            try
                NC.close(conn)
            catch
            end
        end
        return nothing
    end)
    callback_body = HT.CallbackBody(
        dst -> begin
            isempty(dst) && return 0
            dst[1] = UInt8('z')
            return 1
        end,
        () -> nothing,
    )
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4))
    try
        request = HT.Request("POST", "/start"; host = address, body = callback_body, content_length = 1)
        response = HT.do!(client, address, request)
        @test response.status == 307
        @test String(_read_all_parity(response.body)) == "r"
        _wait_task_parity!(server_task)
    finally
        close(client)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP parity h2 frame validation" begin
    io = IOBuffer(UInt8[
        0x00, 0x00, 0x04,
        HT.FRAME_WINDOW_UPDATE,
        0x00,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00,
    ])
    framer = HT.Framer(io)
    @test_throws HT.ProtocolError HT.read_frame!(framer)

    bad_ping = IOBuffer(UInt8[
        0x00, 0x00, 0x08,
        HT.FRAME_PING,
        0x00,
        0x00, 0x00, 0x00, 0x01,
        0, 0, 0, 0, 0, 0, 0, 0,
    ])
    @test_throws HT.ProtocolError HT.read_frame!(HT.Framer(bad_ping))
end

@testset "HTTP parity high-level replayable form body redirect" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen_bodies = String[]
    seen_content_types = Union{Nothing, String}[]
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            push!(seen_bodies, String(_read_all_parity(req1.body)))
            push!(seen_content_types, HT.header(req1.headers, "Content-Type"))
            headers = HT.Headers()
            HT.setheader(headers, "Location", "/next")
            HT.setheader(headers, "Connection", "close")
            resp1 = HT.Response(307; reason = "Temporary Redirect", headers = headers, body = HT.EmptyBody(), content_length = 0, close = true, request = req1)
            io1 = IOBuffer()
            HT.write_response!(io1, resp1)
            write(conn1, take!(io1))
        finally
            try
                NC.close(conn1)
            catch
            end
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            push!(seen_bodies, String(_read_all_parity(req2.body)))
            push!(seen_content_types, HT.header(req2.headers, "Content-Type"))
            resp2 = HT.Response(200; body = HT.BytesBody(UInt8[0x6f, 0x6b]), content_length = 2, request = req2)
            io2 = IOBuffer()
            HT.write_response!(io2, resp2)
            write(conn2, take!(io2))
        finally
            try
                NC.close(conn2)
            catch
            end
        end
        return nothing
    end)
    try
        response = HT.post("http://$(address)/start"; body = Dict("name" => "value"))
        @test response.status == 200
        @test String(response.body) == "ok"
        _wait_task_parity!(server_task)
        @test seen_bodies == ["name=value", "name=value"]
        @test seen_content_types == ["application/x-www-form-urlencoded", "application/x-www-form-urlencoded"]
    finally
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP parity high-level non-replayable iterable redirect" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            req = HT.read_request(HT._ConnReader(conn))
            @test String(_read_all_parity(req.body)) == "ab"
            headers = HT.Headers()
            HT.setheader(headers, "Location", "/next")
            HT.setheader(headers, "Connection", "close")
            resp = HT.Response(307; reason = "Temporary Redirect", headers = headers, body = HT.BytesBody(UInt8[0x72]), content_length = 1, close = true, request = req)
            io = IOBuffer()
            HT.write_response!(io, resp)
            write(conn, take!(io))
        finally
            try
                NC.close(conn)
            catch
            end
        end
        return nothing
    end)
    try
        response = HT.post("http://$(address)/start"; body = ["a", "b"], status_exception = false)
        @test response.status == 307
        @test String(response.body) == "r"
        _wait_task_parity!(server_task)
    finally
        try
            NC.close(listener)
        catch
        end
    end
end
