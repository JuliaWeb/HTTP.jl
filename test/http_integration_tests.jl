using Test
using HTTP
using Reseau

const HT = HTTP
const TL = Reseau.TLS
const NC = Reseau.TCP
const ND = Reseau.HostResolvers

const _TLS_CERT_PATH = joinpath(@__DIR__, "resources", "unittests.crt")
const _TLS_KEY_PATH = joinpath(@__DIR__, "resources", "unittests.key")

function _read_all_integration(body::HT.AbstractBody)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 32)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
end

function _write_all_h2_integration!(conn::NC.Conn, bytes::Vector{UInt8})::Nothing
    total = 0
    while total < length(bytes)
        n = write(conn, bytes[(total + 1):end])
        n > 0 || error("expected write progress")
        total += n
    end
    return nothing
end

function _read_exact_h2_integration!(conn::NC.Conn, n::Int)::Vector{UInt8}
    out = Vector{UInt8}(undef, n)
    offset = 0
    while offset < n
        chunk = Vector{UInt8}(undef, n - offset)
        nr = readbytes!(conn, chunk)
        nr > 0 || error("unexpected EOF")
        copyto!(out, offset + 1, chunk, 1, nr)
        offset += nr
    end
    return out
end

function _write_frame_h2_integration!(conn::NC.Conn, frame::HT.AbstractFrame)
    io = IOBuffer()
    framer = HT.Framer(io)
    HT.write_frame!(framer, frame)
    _write_all_h2_integration!(conn, take!(io))
    return nothing
end

function _read_next_headers_h2_integration!(reader::HT.Framer)::HT.HeadersFrame
    while true
        frame = HT.read_frame!(reader)
        frame isa HT.HeadersFrame && return frame::HT.HeadersFrame
        frame isa HT.SettingsFrame && continue
        frame isa HT.PingFrame && continue
        frame isa HT.WindowUpdateFrame && continue
        error("expected headers frame, got $(typeof(frame))")
    end
end

@testset "HTTP integration TLS auto falls back to h1 on ALPN mismatch" begin
    listener = TL.listen(
        "tcp",
        "127.0.0.1:0",
        TL.Config(
            verify_peer = false,
            cert_file = _TLS_CERT_PATH,
            key_file = _TLS_KEY_PATH,
            alpn_protocols = ["http/1.1"],
        );
        backlog = 8,
    )
    laddr = TL.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server = HT.serve!(listener) do request
        payload = collect(codeunits("tls-h1:" * request.target))
        return HT.Response(200; body = HT.BytesBody(payload), content_length = length(payload))
    end
    client = HT.Client(
        transport = HT.Transport(
            tls_config = TL.Config(
                verify_peer = false,
                server_name = "localhost",
                alpn_protocols = ["h2", "http/1.1"],
            ),
            max_idle_per_host = 4,
            max_idle_total = 4,
        ),
        prefer_http2 = true,
    )
    try
        response = HT.get!(client, address, "/auto-tls"; secure = true, protocol = :auto)
        @test response.status == 200
        @test String(_read_all_integration(response.body)) == "tls-h1:/auto-tls"
    finally
        close(client)
        HT.forceclose(server)
        wait(server)
    end
end

@testset "HTTP integration TLS selects h2 via ALPN" begin
    listener = TL.listen(
        "tcp",
        "127.0.0.1:0",
        TL.Config(
            verify_peer = false,
            cert_file = _TLS_CERT_PATH,
            key_file = _TLS_KEY_PATH,
            alpn_protocols = ["h2"],
        );
        backlog = 8,
    )
    laddr = TL.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server = HT.serve!(listener) do request
        payload = collect(codeunits("tls-h2:" * request.target))
        return HT.Response(200; body = HT.BytesBody(payload), content_length = length(payload), proto_major = 2, proto_minor = 0)
    end
    client = HT.Client(
        transport = HT.Transport(
            tls_config = TL.Config(
                verify_peer = false,
                server_name = "localhost",
                alpn_protocols = ["h2"],
            ),
            max_idle_per_host = 4,
            max_idle_total = 4,
        ),
        prefer_http2 = true,
    )
    try
        response = HT.get!(client, address, "/secure-h2"; secure = true, protocol = :h2)
        @test response.status == 200
        @test String(_read_all_integration(response.body)) == "tls-h2:/secure-h2"
    finally
        close(client)
        HT.forceclose(server)
        wait(server)
    end
end

function _wait_http_addr(server::HT.Server; timeout_s::Float64 = 5.0)
    deadline = time() + timeout_s
    while time() < deadline
        try
            return HT.server_addr(server)
        catch
            sleep(0.01)
        end
    end
    error("timed out waiting for HTTP/1 server addr")
end

@testset "HTTP integration protocol selection" begin
    h1_server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            payload = collect(codeunits("h1:" * request.target))
            return HT.Response(200; body = HT.BytesBody(payload), content_length = length(payload))
        end
    h1_address = _wait_http_addr(h1_server)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4), prefer_http2 = true)
    try
        h1_response = HT.get!(client, h1_address, "/auto-h1"; secure = false, protocol = :auto)
        @test h1_response.status == 200
        @test String(_read_all_integration(h1_response.body)) == "h1:/auto-h1"
    finally
        close(client)
        HT.forceclose(h1_server)
        wait(h1_server)
    end

    h2_server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            payload = collect(codeunits("h2:" * request.target))
            return HT.Response(200; body = HT.BytesBody(payload), content_length = length(payload), proto_major = 2, proto_minor = 0)
        end
    h2_address = _wait_http_addr(h2_server)
    client2 = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4), prefer_http2 = true)
    try
        h2_response = HT.get!(client2, h2_address, "/explicit-h2"; secure = false, protocol = :h2)
        @test h2_response.status == 200
        @test String(_read_all_integration(h2_response.body)) == "h2:/explicit-h2"
        @test_throws ArgumentError HT.get!(client2, h2_address, "/bad"; protocol = :bad)
    finally
        close(client2)
        HT.forceclose(h2_server)
        wait(h2_server)
    end
end

@testset "HTTP integration verbose best-effort h2 dumps" begin
    h2_server = HT.serve!("127.0.0.1", 0; listenany = true) do request
        payload = collect(codeunits("h2-verbose:" * request.target))
        return HT.Response(200; body = HT.BytesBody(payload), content_length = length(payload), proto_major = 2, proto_minor = 0)
    end
    h2_address = _wait_http_addr(h2_server)
    verbose_io = IOBuffer()
    try
        response = HT.get(
            "http://$(h2_address)/verbose-h2";
            protocol = :h2,
            verbose = 2,
            verbose_io = verbose_io,
        )
        @test response.status == 200
        @test String(response.body) == "h2-verbose:/verbose-h2"
        log_text = String(take!(verbose_io))
        @test occursin("[http] request dump (h2, attempt 1)", log_text)
        @test occursin("GET /verbose-h2 HTTP/2\r\n", log_text)
        @test occursin("Host: $(h2_address)\r\n", log_text)
        @test occursin("[http] response dump (h2, attempt 1)", log_text)
        @test occursin("HTTP/2 200\r\n", log_text)
        @test occursin("h2-verbose:/verbose-h2", log_text)
    finally
        HT.forceclose(h2_server)
        wait(h2_server)
    end
end

@testset "HTTP integration opens additional h2 connections under peer concurrency caps" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    accepted = Channel{Nothing}(8)
    server_task = errormonitor(Threads.@spawn begin
        workers = Task[]
        try
            while true
                conn = NC.accept(listener)
                put!(accepted, nothing)
                push!(workers, errormonitor(Threads.@spawn begin
                    reader = HT.Framer(HT._ConnReader(conn))
                    encoder = HT.Encoder()
                    decoder = HT.Decoder()
                    try
                        _ = _read_exact_h2_integration!(conn, length(HT._H2_PREFACE))
                        _ = HT.read_frame!(reader)
                        _write_frame_h2_integration!(conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[UInt16(0x3) => UInt32(1)]))
                        _ = HT.read_frame!(reader)
                        headers_frame = _read_next_headers_h2_integration!(reader)
                        decoded = HT.decode_header_block(decoder, (headers_frame::HT.HeadersFrame).header_block_fragment)
                        path = ""
                        for header in decoded
                            header.name == ":path" && (path = header.value)
                        end
                        sleep(1.0)
                        encoded = HT.encode_header_block(encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
                        _write_frame_h2_integration!(conn, HT.HeadersFrame(headers_frame.stream_id, false, true, encoded))
                        _write_frame_h2_integration!(conn, HT.DataFrame(headers_frame.stream_id, true, collect(codeunits("resp:" * path))))
                    finally
                        try
                            NC.close(conn)
                        catch
                        end
                    end
                    return nothing
                end))
            end
        catch err
            err isa EOFError || err isa Reseau.IOPoll.NetClosingError || rethrow(err)
        finally
            for worker in workers
                fetch(worker)
            end
        end
        return nothing
    end)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4), prefer_http2 = true)
    started = time()
    try
        t1 = errormonitor(Threads.@spawn HT.get!(client, address, "/one"; protocol = :h2))
        t2 = errormonitor(Threads.@spawn HT.get!(client, address, "/two"; protocol = :h2))
        @test timedwait(() -> istaskdone(t1) && istaskdone(t2), 4.0; pollint = 0.001) != :timed_out
        r1 = fetch(t1)
        r2 = fetch(t2)
        elapsed = time() - started
        @test r1.status == 200
        @test r2.status == 200
        @test String(_read_all_integration(r1.body)) == "resp:/one"
        @test String(_read_all_integration(r2.body)) == "resp:/two"
        @test elapsed < 1.8
    finally
        close(client)
        try
            NC.close(listener)
        catch
        end
        fetch(server_task)
    end
    accepted_count = 0
    while isready(accepted)
        take!(accepted)
        accepted_count += 1
    end
    @test accepted_count >= 2
end
