using Test
using HTTP
using Reseau

const HT = HTTP
const ND = Reseau.HostResolvers
const NC = Reseau.TCP
const TL = Reseau.TLS

const _TLS_CERT_PATH = joinpath(@__DIR__, "resources", "unittests.crt")
const _TLS_KEY_PATH = joinpath(@__DIR__, "resources", "unittests.key")

function _write_all_h2_tcp!(conn::NC.Conn, bytes::Vector{UInt8})::Nothing
    total = 0
    while total < length(bytes)
        n = write(conn, bytes[(total + 1):end])
        n > 0 || error("expected write progress")
        total += n
    end
    return nothing
end

function _read_exact_h2_tcp!(conn::NC.Conn, n::Int)::Vector{UInt8}
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

function _write_frame_to_conn!(conn::NC.Conn, frame::HT.AbstractFrame)
    io = IOBuffer()
    framer = io
    HT.write_frame!(framer, frame)
    _write_all_h2_tcp!(conn, take!(io))
    return nothing
end

function _write_padded_data_frame_to_conn!(conn::NC.Conn, stream_id::UInt32, data::Vector{UInt8}; end_stream::Bool = false, padding::Int = 1)
    padding >= 0 || throw(ArgumentError("padding must be >= 0"))
    payload = UInt8[UInt8(padding)]
    append!(payload, data)
    append!(payload, zeros(UInt8, padding))
    length_bytes = UInt8[
        UInt8((length(payload) >> 16) & 0xff),
        UInt8((length(payload) >> 8) & 0xff),
        UInt8(length(payload) & 0xff),
    ]
    flags = HT.FLAG_PADDED
    end_stream && (flags |= HT.FLAG_END_STREAM)
    header = UInt8[
        length_bytes...,
        HT.FRAME_DATA,
        flags,
        UInt8((stream_id >> 24) & 0x7f),
        UInt8((stream_id >> 16) & 0xff),
        UInt8((stream_id >> 8) & 0xff),
        UInt8(stream_id & 0xff),
    ]
    _write_all_h2_tcp!(conn, vcat(header, payload))
    return nothing
end

function _wait_task_h2!(task::Task; timeout_s::Float64 = 5.0)
    status = timedwait(() -> istaskdone(task), timeout_s; pollint = 0.001)
    status == :timed_out && error("timed out waiting for h2 server task")
    fetch(task)
    return nothing
end

function _read_next_headers_frame!(reader::IO)::HT.HeadersFrame
    while true
        frame = HT.read_frame!(reader)
        frame isa HT.HeadersFrame && return frame::HT.HeadersFrame
        frame isa HT.WindowUpdateFrame && continue
        frame isa HT.SettingsFrame && continue
        frame isa HT.PingFrame && continue
        error("expected headers frame, got $(typeof(frame))")
    end
end

function _read_h2_header_block_frames!(reader::IO)
    first = HT.read_frame!(reader)
    first isa HT.HeadersFrame || error("expected headers frame, got $(typeof(first))")
    headers_frame = first::HT.HeadersFrame
    fragments = copy(headers_frame.header_block_fragment)
    frames = HT.AbstractFrame[headers_frame]
    end_headers = headers_frame.end_headers
    while !end_headers
        frame = HT.read_frame!(reader)
        frame isa HT.ContinuationFrame || error("expected continuation frame, got $(typeof(frame))")
        cont = frame::HT.ContinuationFrame
        cont.stream_id == headers_frame.stream_id || error("unexpected continuation stream")
        append!(fragments, cont.header_block_fragment)
        push!(frames, cont)
        end_headers = cont.end_headers
    end
    return headers_frame, fragments, frames
end

function _read_all_h2_body(body::HT.AbstractBody)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 64)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
end

@testset "HTTP/2 client request header filtering and authority selection" begin
    headers = HT.Headers()
    HT.setheader(headers, "Connection", "close")
    HT.setheader(headers, "Transfer-Encoding", "chunked")
    HT.setheader(headers, "Upgrade", "websocket")
    HT.setheader(headers, "Keep-Alive", "timeout=5")
    HT.setheader(headers, "Proxy-Connection", "keep-alive")
    HT.setheader(headers, "X-Test", "ok")
    HT.setheader(headers, "TE", "trailers")
    request = HT.Request("GET", "/filtered"; host = "example.com:8443", headers = headers, body = HT.EmptyBody(), content_length = 0)
    fields = HT._request_headers_for_h2("127.0.0.1:8443", request, true)
    @test any(field -> field.name == ":authority" && field.value == "example.com:8443", fields)
    @test any(field -> field.name == ":scheme" && field.value == "https", fields)
    @test any(field -> field.name == ":path" && field.value == "/filtered", fields)
    @test any(field -> field.name == "x-test" && field.value == "ok", fields)
    @test any(field -> field.name == "te" && field.value == "trailers", fields)
    @test !any(field -> field.name == "connection", fields)
    @test !any(field -> field.name == "transfer-encoding", fields)
    @test !any(field -> field.name == "upgrade", fields)
    @test !any(field -> field.name == "keep-alive", fields)
    @test !any(field -> field.name == "proxy-connection", fields)

    no_override = HT.Request("GET", "/port"; body = HT.EmptyBody(), content_length = 0)
    port_fields = HT._request_headers_for_h2("example.com:8443", no_override, false)
    @test any(field -> field.name == ":authority" && field.value == "example.com:8443", port_fields)

    invalid_te_headers = HT.Headers()
    HT.setheader(invalid_te_headers, "TE", "gzip")
    invalid_te_request = HT.Request("GET", "/te"; headers = invalid_te_headers, body = HT.EmptyBody(), content_length = 0)
    invalid_te_fields = HT._request_headers_for_h2("example.com:443", invalid_te_request, true)
    @test !any(field -> field.name == "te", invalid_te_fields)

    cookie_headers = HT.Headers()
    HT.setheader(cookie_headers, "Cookie", "a=1; b=2")
    cookie_request = HT.Request("GET", "/cookie"; headers = cookie_headers, body = HT.EmptyBody(), content_length = 0)
    cookie_fields = HT._request_headers_for_h2("example.com:443", cookie_request, true)
    @test [field.value for field in cookie_fields if field.name == "cookie"] == ["a=1", "b=2"]

    bad_value_headers = HT.Headers()
    HT.setheader(bad_value_headers, "X-Bad", "ok\r\nInjected: yes")
    bad_value_request = HT.Request("GET", "/bad-value"; headers = bad_value_headers, body = HT.EmptyBody(), content_length = 0)
    @test_throws HT.ProtocolError HT._request_headers_for_h2("example.com:443", bad_value_request, true)

    bad_name_headers = HT.Headers()
    HT.setheader(bad_name_headers, "Bad Name", "ok")
    bad_name_request = HT.Request("GET", "/bad-name"; headers = bad_name_headers, body = HT.EmptyBody(), content_length = 0)
    @test_throws HT.ProtocolError HT._request_headers_for_h2("example.com:443", bad_name_request, true)

    bad_path_request = HT.Request("GET", "/bad\r\npath"; body = HT.EmptyBody(), content_length = 0)
    @test_throws HT.ProtocolError HT._request_headers_for_h2("example.com:443", bad_path_request, true)
end

@testset "HTTP/2 client validates response pseudo-headers" begin
    @test_throws HT.ProtocolError HT._decode_response_headers(HT.HeaderField[])
    @test_throws HT.ProtocolError HT._decode_response_headers(HT.HeaderField[
        HT.HeaderField(":status", "200", false),
        HT.HeaderField(":status", "204", false),
    ])
    @test_throws HT.ProtocolError HT._decode_response_headers(HT.HeaderField[
        HT.HeaderField(":status", "200", false),
        HT.HeaderField("connection", "close", false),
    ])
    @test_throws HT.ProtocolError HT._decode_response_headers(HT.HeaderField[
        HT.HeaderField("x-test", "ok", false),
        HT.HeaderField(":status", "200", false),
    ])
    @test_throws HT.ProtocolError HT._decode_response_headers(HT.HeaderField[
        HT.HeaderField(":status", "200", false),
        HT.HeaderField("x-test", "ok\r\nInjected: yes", false),
    ])
end

@testset "HTTP/2 client rejects response without status pseudo-header" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            hf = headers_frame::HT.HeadersFrame
            _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField("x-test", "ok", false)])
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, true, true, encoded))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        request = HT.Request("GET", "/missing-status"; host = address, body = HT.EmptyBody(), content_length = 0)
        @test_throws HT.ProtocolError HT.h2_roundtrip!(h2_conn, request)
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client preserves and enforces response Content-Length" begin
    for (declared, payload, should_error) in ((2, "ok", false), (2, "oops", true), (5, "abc", true))
        listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
        laddr = NC.addr(listener)::NC.SocketAddrV4
        address = ND.join_host_port("127.0.0.1", Int(laddr.port))
        server_task = errormonitor(Threads.@spawn begin
            accepted_conn = NC.accept(listener)
            reader = HT._ConnReader(accepted_conn)
            server_encoder = HT.Encoder()
            server_decoder = HT.Decoder()
            try
                _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
                _ = HT.read_frame!(reader)
                _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
                _ = HT.read_frame!(reader)
                headers_frame = _read_next_headers_frame!(reader)
                hf = headers_frame::HT.HeadersFrame
                _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
                encoded = HT.encode_header_block(server_encoder, HT.HeaderField[
                    HT.HeaderField(":status", "200", false),
                    HT.HeaderField("content-length", string(declared), false),
                ])
                _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, false, true, encoded))
                _write_frame_to_conn!(accepted_conn, HT.DataFrame(hf.stream_id, true, collect(codeunits(payload))))
            finally
                try
                    NC.close(accepted_conn)
                catch
                end
            end
            return nothing
        end)
        h2_conn = HT.connect_h2!(address; secure = false)
        try
            request = HT.Request("GET", "/content-length"; host = address, body = HT.EmptyBody(), content_length = 0)
            response = HT.h2_roundtrip!(h2_conn, request)
            @test response.content_length == declared
            if should_error
                @test_throws HT.ProtocolError _read_all_h2_body(response.body)
            else
                @test String(_read_all_h2_body(response.body)) == payload
            end
            _wait_task_h2!(server_task)
        finally
            close(h2_conn)
            try
                NC.close(listener)
            catch
            end
        end
    end
end

@testset "HTTP/2 client requires initial SETTINGS before other frames" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.PingFrame(false, ntuple(_ -> UInt8(0), 8)))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    try
        @test_throws HT.ProtocolError HT.connect_h2!(address; secure = false)
        _wait_task_h2!(server_task)
    finally
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 connect_h2! respects connect deadline" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        try
            sleep(0.20)
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    try
        @test_throws Reseau.IOPoll.DeadlineExceededError HT.connect_h2!(address; secure = false, connect_deadline_ns = Int64(time_ns() + 50_000_000))
        _wait_task_h2!(server_task)
    finally
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client rejects server ENABLE_PUSH settings" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[UInt16(0x2) => UInt32(1)]))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    try
        @test_throws HT.ProtocolError HT.connect_h2!(address; secure = false)
        _wait_task_h2!(server_task)
    finally
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client response_header_timeout bounds header wait" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            hf = headers_frame::HT.HeadersFrame
            _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            sleep(0.20)
            encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, true, true, encoded))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        request = HT.Request("GET", "/slow-headers"; host = address, body = HT.EmptyBody(), content_length = 0)
        request_timeout_ns, timeout_config = HT._resolve_request_timeout_settings(0, 0, 0.05)
        HT._apply_request_timeout_settings!(HT.get_request_context(request), request_timeout_ns, timeout_config)
        @test_throws Reseau.IOPoll.DeadlineExceededError HT.h2_roundtrip!(h2_conn, request)
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client read_idle_timeout bounds body waits" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            hf = headers_frame::HT.HeadersFrame
            _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, false, true, encoded))
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(hf.stream_id, false, UInt8[UInt8('a')]))
            sleep(0.20)
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    response = nothing
    try
        request = HT.Request("GET", "/slow-body"; host = address, body = HT.EmptyBody(), content_length = 0)
        request_timeout_ns, timeout_config = HT._resolve_request_timeout_settings(0, 0, 0, 0.05)
        HT._apply_request_timeout_settings!(HT.get_request_context(request), request_timeout_ns, timeout_config)
        response = HT.h2_roundtrip!(h2_conn, request)
        buf = Vector{UInt8}(undef, 8)
        @test HT.body_read!(response.body, buf) == 1
        @test buf[1] == UInt8('a')
        @test_throws Reseau.IOPoll.DeadlineExceededError HT.body_read!(response.body, buf)
        _wait_task_h2!(server_task)
    finally
        response === nothing || try
            HT.body_close!(response.body)
        catch
        end
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client write_idle_timeout bounds flow-control stalls" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[UInt16(0x4) => UInt32(1)]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            hf = headers_frame::HT.HeadersFrame
            _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            try
                _ = HT.read_frame!(reader)
            catch err
                (err isa ParseError || err isa EOFError) || rethrow(err)
            end
            sleep(0.20)
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        body = HT.BytesBody(collect(codeunits("abcd")))
        request = HT.Request("POST", "/slow-upload"; host = address, body = body, content_length = 4)
        request_timeout_ns, timeout_config = HT._resolve_request_timeout_settings(0, 0, 0, 0, 0.05)
        HT._apply_request_timeout_settings!(HT.get_request_context(request), request_timeout_ns, timeout_config)
        @test_throws Reseau.IOPoll.DeadlineExceededError HT.h2_roundtrip!(h2_conn, request)
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client honors peer header table size settings" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[UInt16(0x1) => UInt32(0)]))
            _ = HT.read_frame!(reader)
            for _ in 1:2
                headers_frame = _read_next_headers_frame!(reader)
                decoded = HT.decode_header_block(server_decoder, (headers_frame::HT.HeadersFrame).header_block_fragment)
                @test any(field -> field.name == "x-dyn" && field.value == "same", decoded)
                @test isempty(server_decoder.table.entries)
                encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
                _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(headers_frame.stream_id, true, true, encoded))
            end
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        headers = HT.Headers()
        HT.setheader(headers, "X-Dyn", "same")
        req1 = HT.Request("GET", "/one"; host = address, headers = headers, body = HT.EmptyBody(), content_length = 0)
        req2 = HT.Request("GET", "/two"; host = address, headers = headers, body = HT.EmptyBody(), content_length = 0)
        @test HT.h2_roundtrip!(h2_conn, req1).status == 200
        @test HT.h2_roundtrip!(h2_conn, req2).status == 200
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client rejects request headers above peer max header list size" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[UInt16(0x6) => UInt32(96)]))
            _ = HT.read_frame!(reader)
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        headers = HT.Headers()
        HT.setheader(headers, "X-A", repeat("a", 20))
        HT.setheader(headers, "X-B", repeat("b", 20))
        request = HT.Request("GET", "/too-many-request-headers"; host = address, headers = headers, body = HT.EmptyBody(), content_length = 0)
        @test_throws HT.ProtocolError HT.h2_roundtrip!(h2_conn, request)
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client fragments large request headers" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    large_value = repeat("x", 20_000)
    continuation_count = Ref(0)
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            headers_frame, fragments, frames = _read_h2_header_block_frames!(reader)
            continuation_count[] = count(frame -> frame isa HT.ContinuationFrame, frames)
            @test continuation_count[] > 0
            decoded = HT.decode_header_block(server_decoder, fragments)
            @test any(field -> field.name == "x-big" && field.value == large_value, decoded)
            encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(headers_frame.stream_id, false, true, encoded))
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(headers_frame.stream_id, true, collect(codeunits("ok"))))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        headers = HT.Headers()
        HT.setheader(headers, "X-Big", large_value)
        request = HT.Request("GET", "/fragmented"; host = address, headers = headers, body = HT.EmptyBody(), content_length = 0)
        response = HT.h2_roundtrip!(h2_conn, request)
        @test response.status == 200
        @test String(_read_all_h2_body(response.body)) == "ok"
        _wait_task_h2!(server_task)
        @test continuation_count[] > 0
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client rejects oversized accumulated response header blocks" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    large_value = String(UInt8[UInt8(0x21 + ((i - 1) % 90)) for i in 1:512])
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            _ = HT.decode_header_block(server_decoder, (headers_frame::HT.HeadersFrame).header_block_fragment)
            response_headers = HT.HeaderField[
                HT.HeaderField(":status", "200", false),
                HT.HeaderField("x-huge", large_value, false),
            ]
            encoded = HT.encode_header_block(server_encoder, response_headers)
            @test length(encoded) > 64
            split_idx = max(1, length(encoded) ÷ 2)
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(headers_frame.stream_id, false, false, encoded[1:split_idx]))
            _write_frame_to_conn!(accepted_conn, HT.ContinuationFrame(headers_frame.stream_id, true, encoded[(split_idx + 1):end]))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        h2_conn.max_header_block_bytes = 64
        request = HT.Request("GET", "/too-large-headers"; host = address, body = HT.EmptyBody(), content_length = 0)
        @test_throws HT.ProtocolError HT.h2_roundtrip!(h2_conn, request)
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client rejects oversized decoded response header lists" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            _ = HT.decode_header_block(server_decoder, (headers_frame::HT.HeadersFrame).header_block_fragment)
            response_headers = HT.HeaderField[
                HT.HeaderField(":status", "200", false),
                HT.HeaderField("x-a", repeat("a", 20), false),
                HT.HeaderField("x-b", repeat("b", 20), false),
            ]
            encoded = HT.encode_header_block(server_encoder, response_headers)
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(headers_frame.stream_id, true, true, encoded))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        HT.set_max_header_list_size!(h2_conn.decoder, 96)
        HT.set_max_string_length!(h2_conn.decoder, 96)
        request = HT.Request("GET", "/too-many-headers"; host = address, body = HT.EmptyBody(), content_length = 0)
        err = try
            HT.h2_roundtrip!(h2_conn, request)
            nothing
        catch caught
            caught
        end
        @test err isa HT.ProtocolError
        @test (err::HT.ProtocolError).err isa HT.ParseError
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client roundtrip" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen_paths = String[]
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            preface = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            preface == HT._H2_PREFACE || error("invalid h2 preface")
            client_settings = HT.read_frame!(reader)
            client_settings isa HT.SettingsFrame || error("expected client settings frame")
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            client_ack = HT.read_frame!(reader)
            client_ack isa HT.SettingsFrame || error("expected client settings ack")
            (client_ack::HT.SettingsFrame).ack || error("expected settings ack flag")
            headers_frame = _read_next_headers_frame!(reader)
            headers_frame isa HT.HeadersFrame || error("expected headers frame")
            hf = headers_frame::HT.HeadersFrame
            decoded_headers = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            for header in decoded_headers
                header.name == ":path" && push!(seen_paths, header.value)
            end
            response_headers = HT.HeaderField[HT.HeaderField(":status", "200", false)]
            encoded = HT.encode_header_block(server_encoder, response_headers)
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, false, true, encoded))
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(hf.stream_id, true, collect(codeunits("ok"))))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        request = HT.Request("GET", "/h2"; host = address, body = HT.EmptyBody(), content_length = 0)
        response = HT.h2_roundtrip!(h2_conn, request)
        @test response.status == 200
        @test String(_read_all_h2_body(response.body)) == "ok"
        _wait_task_h2!(server_task)
        @test seen_paths == ["/h2"]
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client exposes response trailers after body EOF" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            hf = headers_frame::HT.HeadersFrame
            _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, false, true, encoded))
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(hf.stream_id, false, collect(codeunits("ok"))))
            trailer_fields = HT.HeaderField[HT.HeaderField("x-trailer", "done", false)]
            trailer_block = HT.encode_header_block(server_encoder, trailer_fields)
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, true, true, trailer_block))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        request = HT.Request("GET", "/trailers"; host = address, body = HT.EmptyBody(), content_length = 0)
        response = HT.h2_roundtrip!(h2_conn, request)
        @test response.status == 200
        @test isempty(response.trailers)
        @test String(_read_all_h2_body(response.body)) == "ok"
        @test HT.header(response.trailers, "X-Trailer") == "done"
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client rejects invalid response trailer pseudo-headers" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            hf = headers_frame::HT.HeadersFrame
            _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, false, true, encoded))
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(hf.stream_id, false, collect(codeunits("ok"))))
            bad_trailers = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "204", false)])
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, true, true, bad_trailers))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        request = HT.Request("GET", "/bad-trailer"; host = address, body = HT.EmptyBody(), content_length = 0)
        result = try
            HT.h2_roundtrip!(h2_conn, request)
        catch err
            err
        end
        if result isa Exception
            @test result isa HT.ProtocolError
        else
            response = result::HT.Response
            @test response.status == 200
            buf = Vector{UInt8}(undef, 8)
            first_result = try
                HT.body_read!(response.body, buf)
            catch err
                err
            end
            if first_result isa Exception
                @test first_result isa HT.ProtocolError
            else
                nread = first_result::Int
                @test nread == 2
                @test String(buf[1:nread]) == "ok"
                @test_throws HT.ProtocolError HT.body_read!(response.body, buf)
            end
        end
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client strips padded DATA payload bytes" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            preface = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            preface == HT._H2_PREFACE || error("invalid h2 preface")
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            hf = headers_frame::HT.HeadersFrame
            _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            response_headers = HT.HeaderField[HT.HeaderField(":status", "200", false)]
            encoded = HT.encode_header_block(server_encoder, response_headers)
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, false, true, encoded))
            _write_padded_data_frame_to_conn!(accepted_conn, hf.stream_id, collect(codeunits("ok")); end_stream = true, padding = 3)
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        request = HT.Request("GET", "/padded"; host = address, body = HT.EmptyBody(), content_length = 0)
        response = HT.h2_roundtrip!(h2_conn, request)
        @test response.status == 200
        @test String(_read_all_h2_body(response.body)) == "ok"
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client sequential streams" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen_streams = UInt32[]
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            for _ in 1:2
                headers_frame = _read_next_headers_frame!(reader)
                hf = headers_frame::HT.HeadersFrame
                push!(seen_streams, hf.stream_id)
                _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
                encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
                _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, false, true, encoded))
                _write_frame_to_conn!(accepted_conn, HT.DataFrame(hf.stream_id, true, collect(codeunits("s" * string(hf.stream_id)))))
            end
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        req1 = HT.Request("GET", "/a"; host = address, body = HT.EmptyBody(), content_length = 0)
        req2 = HT.Request("GET", "/b"; host = address, body = HT.EmptyBody(), content_length = 0)
        res1 = HT.h2_roundtrip!(h2_conn, req1)
        res2 = HT.h2_roundtrip!(h2_conn, req2)
        @test res1.status == 200
        @test res2.status == 200
        @test String(_read_all_h2_body(res1.body)) == "s1"
        @test String(_read_all_h2_body(res2.body)) == "s3"
        _wait_task_h2!(server_task)
        @test seen_streams == UInt32[1, 3]
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client splits large DATA request body" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    frame_sizes = Int[]
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            hf = headers_frame::HT.HeadersFrame
            _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            @test !hf.end_stream
            done = false
            while !done
                frame = HT.read_frame!(reader)
                if frame isa HT.DataFrame
                    df = frame::HT.DataFrame
                    df.stream_id == hf.stream_id || continue
                    push!(frame_sizes, length(df.data))
                    _write_frame_to_conn!(accepted_conn, HT.WindowUpdateFrame(UInt32(0), UInt32(length(df.data))))
                    _write_frame_to_conn!(accepted_conn, HT.WindowUpdateFrame(hf.stream_id, UInt32(length(df.data))))
                    done = df.end_stream
                end
            end
            encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, false, true, encoded))
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(hf.stream_id, true, collect(codeunits("ok"))))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        payload = fill(UInt8('x'), 70_000)
        request = HT.Request("POST", "/upload"; host = address, body = HT.BytesBody(payload), content_length = length(payload))
        response = HT.h2_roundtrip!(h2_conn, request)
        @test response.status == 200
        @test String(_read_all_h2_body(response.body)) == "ok"
        _wait_task_h2!(server_task)
        @test length(frame_sizes) > 1
        @test all(n -> n <= 16_384, frame_sizes)
        @test sum(frame_sizes) == 70_000
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 high-level request supports iterable bodies" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    received = IOBuffer()
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            hf = headers_frame::HT.HeadersFrame
            decoded = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            @test any(field -> field.name == ":path" && field.value == "/iter", decoded)
            done = hf.end_stream
            while !done
                frame = HT.read_frame!(reader)
                frame isa HT.DataFrame || continue
                df = frame::HT.DataFrame
                df.stream_id == hf.stream_id || continue
                write(received, df.data)
                done = df.end_stream
            end
            encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, false, true, encoded))
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(hf.stream_id, true, collect(codeunits("ok"))))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    try
        response = HT.post("http://$(address)/iter"; body = ["hey", " there ", "sailor"], protocol = :h2)
        @test response.status == 200
        @test String(response.body) == "ok"
        _wait_task_h2!(server_task)
        @test String(take!(received)) == "hey there sailor"
    finally
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client honors stream-level flow control" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    chunk_sizes = Int[]
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[UInt16(0x4) => UInt32(32)]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            hf = headers_frame::HT.HeadersFrame
            _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            done = false
            while !done
                frame = HT.read_frame!(reader)
                frame isa HT.DataFrame || continue
                df = frame::HT.DataFrame
                df.stream_id == hf.stream_id || continue
                push!(chunk_sizes, length(df.data))
                if length(chunk_sizes) == 1
                    _write_frame_to_conn!(accepted_conn, HT.WindowUpdateFrame(hf.stream_id, UInt32(96)))
                end
                done = df.end_stream
            end
            encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, false, true, encoded))
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(hf.stream_id, true, collect(codeunits("ok"))))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        payload = fill(UInt8('x'), 128)
        request = HT.Request("POST", "/fc-stream"; host = address, body = HT.BytesBody(payload), content_length = length(payload))
        response = HT.h2_roundtrip!(h2_conn, request)
        @test response.status == 200
        @test String(_read_all_h2_body(response.body)) == "ok"
        _wait_task_h2!(server_task)
        @test !isempty(chunk_sizes)
        @test chunk_sizes[1] == 32
        @test sum(chunk_sizes) == 128
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client honors connection-level flow control" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    chunk_sizes = Int[]
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            hf = headers_frame::HT.HeadersFrame
            _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            done = false
            while !done
                frame = HT.read_frame!(reader)
                frame isa HT.DataFrame || continue
                df = frame::HT.DataFrame
                df.stream_id == hf.stream_id || continue
                push!(chunk_sizes, length(df.data))
                if length(chunk_sizes) == 1
                    _write_frame_to_conn!(accepted_conn, HT.WindowUpdateFrame(UInt32(0), UInt32(112)))
                end
                done = df.end_stream
            end
            encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, false, true, encoded))
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(hf.stream_id, true, collect(codeunits("ok"))))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        lock(h2_conn.state_lock)
        try
            h2_conn.conn_send_window = 16
        finally
            unlock(h2_conn.state_lock)
        end
        payload = fill(UInt8('x'), 128)
        request = HT.Request("POST", "/fc-conn"; host = address, body = HT.BytesBody(payload), content_length = length(payload))
        response = HT.h2_roundtrip!(h2_conn, request)
        @test response.status == 200
        @test String(_read_all_h2_body(response.body)) == "ok"
        _wait_task_h2!(server_task)
        @test !isempty(chunk_sizes)
        @test chunk_sizes[1] == 16
        @test sum(chunk_sizes) == 128
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client shared connection concurrent calls are safe" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen_streams = UInt32[]
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            for _ in 1:4
                headers_frame = _read_next_headers_frame!(reader)
                hf = headers_frame::HT.HeadersFrame
                push!(seen_streams, hf.stream_id)
                _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
                encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
                _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, false, true, encoded))
                _write_frame_to_conn!(accepted_conn, HT.DataFrame(hf.stream_id, true, collect(codeunits("ok"))))
            end
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        tasks = Task[]
        for i in 1:4
            push!(tasks, errormonitor(Threads.@spawn begin
                req = HT.Request("GET", "/$(i)"; host = address, body = HT.EmptyBody(), content_length = 0)
                return HT.h2_roundtrip!(h2_conn, req)
            end))
        end
        results = [fetch(task) for task in tasks]
        @test all(res -> res.status == 200, results)
        @test all(res -> String(_read_all_h2_body(res.body)) == "ok", results)
        _wait_task_h2!(server_task)
        @test sort(seen_streams) == UInt32[1, 3, 5, 7]
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client multiplexes concurrent streams" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            requests = Pair{UInt32, String}[]
            for _ in 1:2
                headers_frame = _read_next_headers_frame!(reader)
                headers_frame isa HT.HeadersFrame || error("expected headers frame")
                hf = headers_frame::HT.HeadersFrame
                decoded = HT.decode_header_block(server_decoder, hf.header_block_fragment)
                path = ""
                for h in decoded
                    h.name == ":path" && (path = h.value)
                end
                push!(requests, hf.stream_id => path)
            end
            encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
            second = requests[2]
            first = requests[1]
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(second.first, false, true, encoded))
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(second.first, true, collect(codeunits("resp:" * second.second))))
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(first.first, false, true, encoded))
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(first.first, true, collect(codeunits("resp:" * first.second))))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        t1 = errormonitor(Threads.@spawn begin
            req = HT.Request("GET", "/one"; host = address, body = HT.EmptyBody(), content_length = 0)
            return HT.h2_roundtrip!(h2_conn, req)
        end)
        t2 = errormonitor(Threads.@spawn begin
            req = HT.Request("GET", "/two"; host = address, body = HT.EmptyBody(), content_length = 0)
            return HT.h2_roundtrip!(h2_conn, req)
        end)
        @test timedwait(() -> istaskdone(t1), 3.0; pollint = 0.001) != :timed_out
        @test timedwait(() -> istaskdone(t2), 3.0; pollint = 0.001) != :timed_out
        r1 = fetch(t1)
        r2 = fetch(t2)
        @test r1.status == 200
        @test r2.status == 200
        @test String(_read_all_h2_body(r1.body)) == "resp:/one"
        @test String(_read_all_h2_body(r2.body)) == "resp:/two"
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client rejects PUSH_PROMISE frames" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[UInt16(0x2) => UInt32(0)]))
            _ = HT.read_frame!(reader)
            headers_frame = _read_next_headers_frame!(reader)
            hf = headers_frame::HT.HeadersFrame
            _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            promised = HT.HeaderField[
                HT.HeaderField(":method", "GET", false),
                HT.HeaderField(":scheme", "http", false),
                HT.HeaderField(":authority", address, false),
                HT.HeaderField(":path", "/pushed", false),
            ]
            push_block = HT.encode_header_block(server_encoder, promised)
            _write_frame_to_conn!(accepted_conn, HT.PushPromiseFrame(hf.stream_id, UInt32(2), true, push_block))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        request = HT.Request("GET", "/reject-push"; host = address, body = HT.EmptyBody(), content_length = 0)
        @test_throws HT.ProtocolError HT.h2_roundtrip!(h2_conn, request)
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 client marks streams above GOAWAY last_stream_id explicitly" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _ = HT.read_frame!(reader)
            first = _read_next_headers_frame!(reader)
            second = _read_next_headers_frame!(reader)
            _ = HT.decode_header_block(server_decoder, (first::HT.HeadersFrame).header_block_fragment)
            _ = HT.decode_header_block(server_decoder, (second::HT.HeadersFrame).header_block_fragment)
            _write_frame_to_conn!(accepted_conn, HT.GoAwayFrame(UInt32(1), UInt32(0), UInt8[]))
            encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(UInt32(1), false, true, encoded))
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(UInt32(1), true, collect(codeunits("ok"))))
        finally
            try
                NC.close(accepted_conn)
            catch
            end
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        t1 = Threads.@spawn begin
            req = HT.Request("GET", "/one"; host = address, body = HT.EmptyBody(), content_length = 0)
            return HT.h2_roundtrip!(h2_conn, req)
        end
        t2 = Threads.@spawn begin
            req = HT.Request("GET", "/two"; host = address, body = HT.EmptyBody(), content_length = 0)
            return HT.h2_roundtrip!(h2_conn, req)
        end
        @test timedwait(() -> istaskdone(t1), 3.0; pollint = 0.001) != :timed_out
        @test timedwait(() -> istaskdone(t2), 3.0; pollint = 0.001) != :timed_out
        outcomes = Any[]
        for task in (t1, t2)
            push!(outcomes, try
                fetch(task)
            catch err
                err
            end)
        end
        responses = [outcome for outcome in outcomes if outcome isa HT.Response]
        failures = [outcome for outcome in outcomes if outcome isa TaskFailedException]
        @test length(responses) == 1
        @test length(failures) == 1
        response = only(responses)::HT.Response
        @test response.status == 200
        @test String(_read_all_h2_body(response.body)) == "ok"
        failure = only(failures)::TaskFailedException
        @test failure.task.exception isa HT.H2GoAwayError
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP/2 secure connect rejects non-h2 ALPN" begin
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
    server_task = errormonitor(Threads.@spawn begin
        conn = nothing
        try
            conn = TL.accept(listener)
            try
                TL.handshake!(conn)
                sleep(0.05)
            catch err
                # The client intentionally aborts once ALPN negotiation fails.
                # Server-side TLS failures are expected in this test path.
                ex = err::Exception
                if !(ex isa TL.TLSError || ex isa EOFError || ex isa SystemError)
                    rethrow(ex)
                end
            end
        finally
            conn === nothing || try
                TL.close(conn::TL.Conn)
            catch
            end
        end
        return nothing
    end)
    @test_throws HT.H2NegotiationError HT.connect_h2!(
        address;
        secure = true,
        tls_config = TL.Config(
            verify_peer = false,
            server_name = "localhost",
            alpn_protocols = ["h2", "http/1.1"],
        ),
    )
    _wait_task_h2!(server_task)
    TL.close(listener)
end
