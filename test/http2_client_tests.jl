using Test
using HTTP
using Reseau
using Random

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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
                HTTP.@try_ignore NC.close(accepted_conn)
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
            HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
        end
        return nothing
    end)
    try
        @test_throws HT.ProtocolError HT.connect_h2!(address; secure = false)
        _wait_task_h2!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
        end
        return nothing
    end)
    try
        @test_throws Reseau.IOPoll.DeadlineExceededError HT.connect_h2!(address; secure = false, connect_deadline_ns = Int64(time_ns() + 50_000_000))
        _wait_task_h2!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
        end
        return nothing
    end)
    try
        @test_throws HT.ProtocolError HT.connect_h2!(address; secure = false)
        _wait_task_h2!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        response === nothing || HTTP.@try_ignore HT.body_close!(response.body)
        close(h2_conn)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP/2 client read_idle_timeout allows delayed first body frame" begin
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
            sleep(0.05)
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(hf.stream_id, true, UInt8[UInt8('o'), UInt8('k')]))
        finally
            HTTP.@try_ignore NC.close(accepted_conn)
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    response = nothing
    try
        request = HT.Request("GET", "/delayed-body"; host = address, body = HT.EmptyBody(), content_length = 0)
        request_timeout_ns, timeout_config = HT._resolve_request_timeout_settings(0, 0, 0, 0.5)
        HT._apply_request_timeout_settings!(HT.get_request_context(request), request_timeout_ns, timeout_config)
        response = HT.h2_roundtrip!(h2_conn, request)
        @test String(_read_all_h2_body(response.body)) == "ok"
        _wait_task_h2!(server_task)
    finally
        response === nothing || HTTP.@try_ignore HT.body_close!(response.body)
        close(h2_conn)
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false)
    try
        request = HT.Request("GET", "/trailers"; host = address, body = HT.EmptyBody(), content_length = 0)
        response = HT.h2_roundtrip!(h2_conn, request)
        @test response.status == 200
        @test String(_read_all_h2_body(response.body)) == "ok"
        @test HT.header(response.trailers, "X-Trailer") == "done"
        _wait_task_h2!(server_task)
    finally
        close(h2_conn)
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP/2 request context cancellation resets in-flight stream" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    stream_ids = Channel{UInt32}(1)
    reset_codes = Channel{UInt32}(1)
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            headers_frame = _read_next_headers_frame!(reader)
            stream_id = (headers_frame::HT.HeadersFrame).stream_id
            put!(stream_ids, stream_id)
            while true
                frame = HT.read_frame!(reader)
                if frame isa HT.RSTStreamFrame && (frame::HT.RSTStreamFrame).stream_id == stream_id
                    put!(reset_codes, (frame::HT.RSTStreamFrame).error_code)
                    break
                end
            end
        finally
            HTTP.@try_ignore NC.close(accepted_conn)
        end
        return nothing
    end)
    client = HT.Client()
    ctx = HT.RequestContext()
    url = "http://$(address)/cancel"
    request_task = Threads.@spawn HT.get($url; protocol = :h2, context = $ctx, client = $client, retry = false)
    try
        @test timedwait(() -> isready(stream_ids), 5.0; pollint = 0.001) != :timed_out
        isready(stream_ids) && take!(stream_ids)
        HT.cancel!(ctx; message = "user canceled h2")
        result = try
            fetch(request_task)
            (:ok, nothing)
        catch e
            inner = e isa Base.TaskFailedException ? e.task.exception : e
            (:err, inner)
        end
        @test result[1] == :err
        @test result[2] isa HT.CanceledError
        @test (result[2]::HT.CanceledError).message == "user canceled h2"
        @test isempty(ctx.cancel_callbacks)
        @test timedwait(() -> isready(reset_codes), 5.0; pollint = 0.001) != :timed_out
        isready(reset_codes) && @test take!(reset_codes) == UInt32(0x8)
        _wait_task_h2!(server_task)
    finally
        close(client)
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP/2 client connection window stays non-negative under a raised stream window" begin
    # A raised SETTINGS_INITIAL_WINDOW_SIZE only enlarges the per-stream send
    # window; the connection-level window is separate and stays at the protocol
    # default until a stream-0 WINDOW_UPDATE arrives. With a 1 MiB stream window
    # but a default connection window, the client must still cap connection-level
    # output at 65535 bytes and stall, never letting the connection window go
    # negative, even though the stream window alone would permit the whole body.
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    bytes_before_grant = Ref(0)
    total_received = Ref(0)
    payload_len = 200 * 1024
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        server_encoder = HT.Encoder()
        server_decoder = HT.Decoder()
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            _ = HT.read_frame!(reader)
            # Advertise a 1 MiB per-stream window but leave the connection window at
            # the default (no stream-0 WINDOW_UPDATE), so the connection is the bind.
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[UInt16(0x4) => UInt32(1 << 20)]))
            _ = HT.read_frame!(reader)
            hf = (_read_next_headers_frame!(reader))::HT.HeadersFrame
            _ = HT.decode_header_block(server_decoder, hf.header_block_fragment)
            # Drain everything the client sends without ever granting connection
            # credit, until it stops emitting DATA. A compliant client exhausts the
            # default 65535-byte connection window and then stalls, which we observe
            # as a read deadline rather than more bytes. A client that wrongly leaned
            # on its 1 MiB stream window would keep sending and reach END_STREAM here,
            # so the drained byte count is what proves the connection-level cap.
            got_end = false
            NC.set_deadline!(accepted_conn, Int64(time_ns() + 1_000_000_000))
            try
                while !got_end
                    frame = HT.read_frame!(reader)
                    frame isa HT.DataFrame || continue
                    df = frame::HT.DataFrame
                    df.stream_id == hf.stream_id || continue
                    bytes_before_grant[] += length(df.data)
                    got_end = df.end_stream
                end
            catch err
                err isa Reseau.IOPoll.DeadlineExceededError || rethrow(err)
            finally
                NC.set_deadline!(accepted_conn, Int64(0))
            end
            total_received[] = bytes_before_grant[]
            # A compliant client stalled mid-body; release the rest of the connection
            # window and finish reading. If it already hit END_STREAM (the overshoot
            # case), skip this so a regression fails the assertion rather than hanging.
            if !got_end
                _write_frame_to_conn!(accepted_conn, HT.WindowUpdateFrame(UInt32(0), UInt32(payload_len - HT._H2_DEFAULT_WINDOW_SIZE)))
                NC.set_deadline!(accepted_conn, Int64(time_ns() + 2_000_000_000))
                try
                    while !got_end
                        frame = HT.read_frame!(reader)
                        frame isa HT.DataFrame || continue
                        df = frame::HT.DataFrame
                        df.stream_id == hf.stream_id || continue
                        total_received[] += length(df.data)
                        got_end = df.end_stream
                    end
                finally
                    NC.set_deadline!(accepted_conn, Int64(0))
                end
            end
            encoded = HT.encode_header_block(server_encoder, HT.HeaderField[HT.HeaderField(":status", "200", false)])
            _write_frame_to_conn!(accepted_conn, HT.HeadersFrame(hf.stream_id, false, true, encoded))
            _write_frame_to_conn!(accepted_conn, HT.DataFrame(hf.stream_id, true, collect(codeunits("ok"))))
        finally
            HTTP.@try_ignore NC.close(accepted_conn)
        end
        return nothing
    end)
    h2_conn = HT.connect_h2!(address; secure = false, http2_settings = HT.HTTP2Settings(initial_window_size = 1 << 20))
    try
        payload = fill(UInt8('x'), payload_len)
        request = HT.Request("POST", "/fc-conn-window"; host = address, body = HT.BytesBody(payload), content_length = payload_len)
        response = HT.h2_roundtrip!(h2_conn, request)
        @test response.status == 200
        @test String(_read_all_h2_body(response.body)) == "ok"
        _wait_task_h2!(server_task)
        # Exactly the default connection window reached the server before any
        # stream-0 WINDOW_UPDATE: the connection window never went negative.
        @test bytes_before_grant[] == HT._H2_DEFAULT_WINDOW_SIZE
        @test total_received[] == payload_len
    finally
        close(h2_conn)
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(accepted_conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            conn === nothing || HTTP.@try_ignore TL.close(conn::TL.Conn)
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

# Regression: concurrent h2_roundtrip! must allocate stream ids in increasing
# wire order. Without write-locked id allocation, two tasks could pick A < B
# and then race to ship HEADERS, sending B before A and triggering peer GOAWAY.
@testset "HTTP/2 client multiplexes concurrent roundtrips on one connection" begin
    server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
        return HTTP.Response(200; body = "hello")
    end
    addr = "127.0.0.1:$(HTTP.port(server))"
    conn = HT.connect_h2!(addr; secure = false)
    try
        N = 32
        tasks = [
            Threads.@spawn HT.h2_roundtrip!(
                conn,
                HT.Request("GET", "/r$i"; host = addr, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0),
            )
            for i in 1:N
        ]
        results = [fetch(t) for t in tasks]
        @test all(r.status == 200 for r in results)
    finally
        close(conn)
        HTTP.forceclose(server)
    end
end

# Regression: trailers reach the response even when the user inspects them
# before draining the body. Required for gRPC-style consumers that only check
# `response.trailers["grpc-status"]`.
@testset "HTTP/2 client surfaces trailers without forcing body drain" begin
    server = HTTP.listen!("127.0.0.1", 0; listenany = true) do stream
        _ = HTTP.startread(stream)
        HTTP.setstatus(stream, 200)
        HTTP.setheader(stream, "Trailer", "grpc-status")
        HTTP.startwrite(stream)
        write(stream, "hello")
        HTTP.addtrailer(stream, "grpc-status" => "0")
        HTTP.closeread(stream)
        HTTP.closewrite(stream)
    end
    addr = "127.0.0.1:$(HTTP.port(server))"
    conn = HT.connect_h2!(addr; secure = false)
    try
        request = HT.Request("GET", "/"; host = addr, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        response = HT.h2_roundtrip!(conn, request)
        # Allow the trailing HEADERS frame to land. The fix surfaces it
        # whether it arrives before or after the response head is built.
        sleep(0.1)
        @test response.status == 200
        @test HT.header(response.trailers, "grpc-status") == "0"
    finally
        close(conn)
        HTTP.forceclose(server)
    end
end

# Regression: a transport with `alpn_protocols=["http/1.1"]` must not
# negotiate h2 even when `prefer_http2=true`. Skipping the h2 attempt here
# avoids a wasted TLS handshake and matches user expectations of an h1-pin.
@testset "HTTP/2 client honors restricted ALPN list on auto protocol" begin
    listener = TL.listen(
        "tcp",
        "127.0.0.1:0",
        TL.Config(
            verify_peer = false,
            cert_file = _TLS_CERT_PATH,
            key_file = _TLS_KEY_PATH,
            alpn_protocols = ["h2", "http/1.1"],
        );
        backlog = 8,
    )
    laddr = TL.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server = HTTP.serve!(listener) do req
        return HTTP.Response(200; body = "proto=$(req.proto_major).$(req.proto_minor)")
    end
    tls = TL.Config(verify_peer = false, server_name = "localhost", alpn_protocols = ["http/1.1"])
    transport = HT.Transport(tls_config = tls)
    client = HT.Client(transport = transport, prefer_http2 = true)
    try
        # `_use_h2` should refuse h2 because the ALPN list excludes it.
        @test !HT._use_h2(client, true, :auto)
        # Verify end-to-end that protocol=:auto picks h1.
        response = HT.get!(client, address, "/"; secure = true, protocol = :auto)
        @test response.status == 200
        @test response.proto_major == UInt8(1)
    finally
        close(client)
        HTTP.forceclose(server)
    end
end

@testset "HTTP/2 client advertises configured flow-control windows" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    captured = Channel{Vector{HT.AbstractFrame}}(1)
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            client_settings = HT.read_frame!(reader)
            window_update = HT.read_frame!(reader)
            put!(captured, HT.AbstractFrame[client_settings, window_update])
            # Send our SETTINGS so the client's connect handshake completes.
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
        catch
            isready(captured) || put!(captured, HT.AbstractFrame[])
        end
        return accepted_conn
    end)
    conn = nothing
    try
        conn = HT.connect_h2!(
            address;
            secure = false,
            http2_settings = HT.HTTP2Settings(
                initial_window_size = 1_048_576,
                connection_window_size = 2_097_152,
            ),
        )
        frames = take!(captured)
        @test length(frames) == 2
        settings = frames[1]
        @test settings isa HT.SettingsFrame
        @test !(settings::HT.SettingsFrame).ack
        @test (settings::HT.SettingsFrame).settings ==
            Pair{UInt16, UInt32}[UInt16(0x4) => UInt32(1_048_576)]
        wu = frames[2]
        @test wu isa HT.WindowUpdateFrame
        @test (wu::HT.WindowUpdateFrame).stream_id == UInt32(0)
        @test (wu::HT.WindowUpdateFrame).window_size_increment == UInt32(2_097_152 - 65_535)
        # The per-stream receive buffer cap is derived from the window: it grows to
        # the initial window when that exceeds the default cap.
        @test conn.max_buffered_bytes == 1_048_576
    finally
        conn === nothing || HTTP.@try_ignore close(conn)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP/2 client keeps default flow-control windows byte-for-byte" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    captured = Channel{Vector{HT.AbstractFrame}}(1)
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            client_settings = HT.read_frame!(reader)
            # Send our SETTINGS so the client completes its handshake and sends its
            # SETTINGS ACK. With raised windows a WINDOW_UPDATE would have been written
            # right after the client SETTINGS, ahead of the ACK; TCP preserves that
            # order, so reading one more frame here surfaces a stray WINDOW_UPDATE.
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            second = HT.read_frame!(reader)
            put!(captured, HT.AbstractFrame[client_settings, second])
        catch
            isready(captured) || put!(captured, HT.AbstractFrame[])
        end
        return accepted_conn
    end)
    conn = nothing
    try
        conn = HT.connect_h2!(address; secure = false)
        frames = take!(captured)
        @test length(frames) == 2
        settings = frames[1]
        @test settings isa HT.SettingsFrame
        # With default windows the client advertises an empty SETTINGS payload and
        # sends no connection-level WINDOW_UPDATE: the frame after SETTINGS is the
        # client's SETTINGS ACK, never a WindowUpdateFrame.
        @test isempty((settings::HT.SettingsFrame).settings)
        @test !(frames[2] isa HT.WindowUpdateFrame)
        @test conn.max_buffered_bytes == HT._H2_DEFAULT_MAX_BUFFERED_BYTES
    finally
        conn === nothing || HTTP.@try_ignore close(conn)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP/2 client advertises a sub-default stream window" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    captured = Channel{Union{HT.AbstractFrame, Nothing}}(1)
    server_task = errormonitor(Threads.@spawn begin
        accepted_conn = NC.accept(listener)
        reader = HT._ConnReader(accepted_conn)
        try
            _ = _read_exact_h2_tcp!(accepted_conn, length(HT._H2_PREFACE))
            put!(captured, HT.read_frame!(reader))
            # Reply with our SETTINGS so the client's handshake completes and
            # connect_h2! returns.
            _write_frame_to_conn!(accepted_conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
        catch
            isready(captured) || put!(captured, nothing)
        end
        return accepted_conn
    end)
    conn = nothing
    try
        conn = HT.connect_h2!(
            address;
            secure = false,
            http2_settings = HT.HTTP2Settings(initial_window_size = 16_384),
        )
        settings = take!(captured)
        @test settings isa HT.SettingsFrame
        # A sub-default stream window is still advertised: the SETTINGS_INITIAL_WINDOW_SIZE
        # entry is emitted whenever it differs from the protocol default, not only when
        # it exceeds it.
        @test (settings::HT.SettingsFrame).settings ==
            Pair{UInt16, UInt32}[UInt16(0x4) => UInt32(16_384)]
        # A window below the default cap keeps the default per-stream buffer cap.
        @test conn.max_buffered_bytes == HT._H2_DEFAULT_MAX_BUFFERED_BYTES
    finally
        conn === nothing || HTTP.@try_ignore close(conn)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP/2 large body round-trips intact across a real client and server" begin
    # End-to-end integrity check: a real client and server move a multi-MiB body in
    # each direction and the echoed bytes must match exactly. The body is several
    # times the per-stream window, so the single stream crosses the window boundary
    # repeatedly and exercises ongoing WINDOW_UPDATE replenishment and reassembly in
    # both directions. Raised windows are used so that replenishment happens in MiB
    # steps; they are not what this test verifies (it would also pass at the default
    # windows). That the configured windows reach the wire and are honored on the
    # send side is covered by the "advertises configured flow-control windows" and
    # "connection window stays non-negative under a raised stream window" tests.
    settings = HT.HTTP2Settings(initial_window_size = 1 << 20, connection_window_size = 1 << 21)
    server = HT.serve!("127.0.0.1", 0; listenany = true, http2_settings = settings) do request
            buf = Vector{UInt8}(undef, 64 * 1024)
            body = UInt8[]
            while true
                n = HT.body_read!(request.body, buf)
                n == 0 && break
                append!(body, @view(buf[1:n]))
            end
            return HT.Response(200, HT.BytesBody(body); content_length = length(body), proto_major = 2, proto_minor = 0)
        end
    address = HT.server_addr(server)
    conn = nothing
    try
        conn = HT.connect_h2!(address; secure = false, http2_settings = settings)
        payload = rand(MersenneTwister(0x1264), UInt8, 3 << 20)
        req = HT.Request("POST", "/echo"; host = address, body = HT.BytesBody(copy(payload)), content_length = length(payload), proto_major = 2, proto_minor = 0)
        res = HT.h2_roundtrip!(conn, req)
        @test res.status == 200
        @test _read_all_h2_body(res.body) == payload
    finally
        conn === nothing || close(conn)
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

# Build a bare H2Connection over a loopback TCP pair so internal frame handlers
# can be driven directly (offline, no read loop). Only the decoder/streams state
# is exercised here; the sockets exist solely to satisfy the struct.
function _build_bare_h2_connection()
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 1)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    accept_task = Threads.@spawn NC.accept(listener)
    client_tcp = NC.connect("tcp", address; timeout_ns = 3_000_000_000)
    server_tcp = fetch(accept_task)
    state_lock = ReentrantLock()
    conn = HT.H2Connection(
        address,
        false,
        client_tcp,
        nothing,
        HT._ConnReader(client_tcp),
        16_384,
        HT.Encoder(),
        HT.Decoder(
            max_string_length = HT._H2_DEFAULT_MAX_HEADER_LIST_SIZE,
            max_header_list_size = HT._H2_DEFAULT_MAX_HEADER_LIST_SIZE,
        ),
        UInt32(1),
        state_lock,
        ReentrantLock(),
        Dict{UInt32,HT.H2StreamState}(),
        Threads.Condition(state_lock),
        nothing,
        Threads.Condition(state_lock),
        nothing,
        Threads.Condition(state_lock),
        Int64(65_535),
        Int64(65_535),
        Dict{UInt32,Int64}(),
        typemax(Int),
        0,
        typemax(UInt32),
        true,
        HT._H2_DEFAULT_MAX_HEADER_BLOCK_BYTES,
        HT._H2_DEFAULT_MAX_BUFFERED_BYTES,
        UInt32(0),
        nothing,
        UInt8[],
        0,
        false,
    )
    cleanup = () -> begin
        close(client_tcp)
        close(server_tcp)
        close(listener)
    end
    return conn, cleanup
end

# Regression for the HPACK desync when a HEADERS/CONTINUATION block arrives for
# an unknown/closed stream (ANT-2026-SCEWC4G3 / RFC 7541 §4). The client must
# still pass every header block through `conn.decoder` so the connection-scoped
# dynamic table stays in lockstep with the peer's encoder; otherwise indexed
# references on *later* streams resolve to wrong values.
@testset "HTTP/2 client decodes header blocks for unknown streams (HPACK sync)" begin
    conn, cleanup = _build_bare_h2_connection()
    try
        # A single peer encoder produces three blocks; blocks 2 and 3 rely on the
        # dynamic-table entries added by earlier blocks. The encoder mutates its
        # dynamic table as a connection-scoped side effect, exactly like a real
        # server, so the client decoder must mirror every block to stay in sync.
        server_encoder = HT.Encoder()

        # Block 1 -> live stream 1. Adds "x-custom: alpha" to the dynamic table.
        live_state = HT._try_register_stream_locked!(conn)::HT.H2StreamState
        @test live_state.stream_id == UInt32(1)
        block1 = HT.encode_header_block(server_encoder, HT.HeaderField[
            HT.HeaderField(":status", "200", false),
            HT.HeaderField("x-custom", "alpha", false),
        ])
        HT._process_incoming_frame!(conn, HT.HeadersFrame(UInt32(1), true, true, block1))
        @test live_state.headers_complete
        @test any(f -> f.name == "x-custom" && f.value == "alpha", live_state.decoded_headers)

        # Close stream 1 (mirrors trailers racing `_unregister_stream!`), then
        # deliver block 2 to it. The stream is now unknown, but the block adds
        # "x-trailer: omega" to the dynamic table. The pre-fix code dropped this
        # block undecoded, desynchronizing the dynamic table for the connection.
        HT._unregister_stream!(conn, UInt32(1))
        @test HT._stream_state(conn, UInt32(1)) === nothing
        block2 = HT.encode_header_block(server_encoder, HT.HeaderField[
            HT.HeaderField(":status", "204", false),
            HT.HeaderField("x-trailer", "omega", false),
        ])
        HT._process_incoming_frame!(conn, HT.HeadersFrame(UInt32(1), true, true, block2))

        # Block 3 -> a freshly registered live stream (next client id is 3),
        # referencing the entries added by blocks 1 and 2 via indexed HPACK
        # references. If block 2 was decoded (post-fix), these resolve correctly;
        # otherwise they resolve to stale/wrong table entries (or throw).
        live_state2 = HT._try_register_stream_locked!(conn)::HT.H2StreamState
        @test live_state2.stream_id == UInt32(3)
        block3 = HT.encode_header_block(server_encoder, HT.HeaderField[
            HT.HeaderField(":status", "200", false),
            HT.HeaderField("x-custom", "alpha", false),
            HT.HeaderField("x-trailer", "omega", false),
        ])
        HT._process_incoming_frame!(conn, HT.HeadersFrame(UInt32(3), true, true, block3))
        @test live_state2.headers_complete
        decoded = live_state2.decoded_headers::Vector{HT.HeaderField}
        @test any(f -> f.name == "x-custom" && f.value == "alpha", decoded)
        @test any(f -> f.name == "x-trailer" && f.value == "omega", decoded)
        @test any(f -> f.name == ":status" && f.value == "200", decoded)
    finally
        cleanup()
    end
end

# CONTINUATION sequencing must be enforced on the client just as on the server
# (RFC 7540 §6.10): a HEADERS without END_HEADERS may only be followed by a
# CONTINUATION on the same stream; anything else is a connection error.
@testset "HTTP/2 client enforces CONTINUATION sequencing" begin
    conn, cleanup = _build_bare_h2_connection()
    try
        server_encoder = HT.Encoder()
        block = HT.encode_header_block(server_encoder, HT.HeaderField[
            HT.HeaderField(":status", "200", false),
        ])
        # Open a header block on stream 1 (END_HEADERS unset) ...
        live_state = HT._try_register_stream_locked!(conn)::HT.H2StreamState
        HT._process_incoming_frame!(conn, HT.HeadersFrame(UInt32(1), false, false, block))
        @test conn.continuation_stream == UInt32(1)
        # ... then send a DATA frame instead of the required CONTINUATION.
        @test_throws HT.ProtocolError HT._process_incoming_frame!(conn, HT.DataFrame(UInt32(1), false, UInt8[0x00]))
    finally
        cleanup()
    end

    conn2, cleanup2 = _build_bare_h2_connection()
    try
        server_encoder = HT.Encoder()
        block = HT.encode_header_block(server_encoder, HT.HeaderField[
            HT.HeaderField(":status", "200", false),
        ])
        # A CONTINUATION with no open header block is a connection error.
        @test_throws HT.ProtocolError HT._process_incoming_frame!(conn2, HT.ContinuationFrame(UInt32(1), true, block))
    finally
        cleanup2()
    end

    # A multi-frame block for an UNKNOWN stream must still decode across frames
    # and keep the dynamic table in sync, while honoring CONTINUATION sequencing.
    conn3, cleanup3 = _build_bare_h2_connection()
    try
        server_encoder = HT.Encoder()
        # Adds "x-multi: split" to the encoder dynamic table, then split the
        # encoded block across HEADERS + CONTINUATION on unknown stream 3.
        full = HT.encode_header_block(server_encoder, HT.HeaderField[
            HT.HeaderField(":status", "200", false),
            HT.HeaderField("x-multi", "split", false),
        ])
        @test length(full) >= 2
        mid = cld(length(full), 2)
        part1 = full[1:mid]
        part2 = full[(mid + 1):end]
        # Use a stream id the client never allocated, so the lookup misses.
        @test HT._stream_state(conn3, UInt32(7)) === nothing
        HT._process_incoming_frame!(conn3, HT.HeadersFrame(UInt32(7), false, false, part1))
        @test conn3.continuation_stream == UInt32(7)
        HT._process_incoming_frame!(conn3, HT.ContinuationFrame(UInt32(7), true, part2))
        @test conn3.continuation_stream == UInt32(0)
        @test isempty(conn3.orphan_header_block)

        # The decoder is now in sync: a follow-up indexed reference to "x-multi"
        # on a live stream resolves correctly.
        live = HT._try_register_stream_locked!(conn3)::HT.H2StreamState
        block = HT.encode_header_block(server_encoder, HT.HeaderField[
            HT.HeaderField(":status", "200", false),
            HT.HeaderField("x-multi", "split", false),
        ])
        HT._process_incoming_frame!(conn3, HT.HeadersFrame(live.stream_id, true, true, block))
        @test any(f -> f.name == "x-multi" && f.value == "split", live.decoded_headers)
    finally
        cleanup3()
    end
end
