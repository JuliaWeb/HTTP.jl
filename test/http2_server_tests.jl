using Test
using HTTP
using Reseau
using Dates

const HT = HTTP
const ND = Reseau.HostResolvers
const NC = Reseau.TCP

function _wait_http_server_addr(server::HT.Server; timeout_s::Float64 = 5.0)::String
    deadline = time() + timeout_s
    while time() < deadline
        try
            return HT.server_addr(server)
        catch
            sleep(0.01)
        end
    end
    error("timed out waiting for server address")
end

function _read_all_h2_server(body::HT.AbstractBody)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 64)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
end

function _write_all_h2_server_raw!(conn::NC.Conn, bytes::Vector{UInt8})
    total = 0
    while total < length(bytes)
        n = write(conn, bytes[(total + 1):end])
        n > 0 || error("expected write progress")
        total += n
    end
    return nothing
end

function _write_frame_h2_server_raw!(conn::NC.Conn, frame::HT.AbstractFrame)
    io = IOBuffer()
    framer = io
    HT.write_frame!(framer, frame)
    _write_all_h2_server_raw!(conn, take!(io))
    return nothing
end

function _open_raw_h2_server_conn(address::String; settings::Vector{Pair{UInt16, UInt32}} = Pair{UInt16, UInt32}[])
    conn = ND.connect("tcp", address)
    reader = HT._ConnReader(conn)
    _write_all_h2_server_raw!(conn, HT._H2_PREFACE)
    _write_frame_h2_server_raw!(conn, HT.SettingsFrame(false, settings))
    first = HT.read_frame!(reader)
    second = HT.read_frame!(reader)
    frames = (first, second)
    count(frame -> frame isa HT.SettingsFrame && !(frame::HT.SettingsFrame).ack, frames) == 1 || error("expected server SETTINGS frame")
    count(frame -> frame isa HT.SettingsFrame && (frame::HT.SettingsFrame).ack, frames) == 1 || error("expected server SETTINGS ACK frame")
    return conn, reader
end

function _write_h2_server_request_headers!(
        conn::NC.Conn,
        encoder::HT.Encoder,
        stream_id::UInt32,
        address::String,
        path::String;
        method::String = "GET",
        headers::Vector{HT.HeaderField} = HT.HeaderField[],
        end_stream::Bool = true,
    )
    fields = HT.HeaderField[
        HT.HeaderField(":method", method, false),
        HT.HeaderField(":scheme", "http", false),
        HT.HeaderField(":authority", address, false),
        HT.HeaderField(":path", path, false),
    ]
    append!(fields, headers)
    _write_frame_h2_server_raw!(conn, HT.HeadersFrame(stream_id, end_stream, true, HT.encode_header_block(encoder, fields)))
    return nothing
end

function _read_h2_server_header_block!(reader::IO)
    first = HT.read_frame!(reader)
    while first isa HT.WindowUpdateFrame || first isa HT.SettingsFrame || first isa HT.PingFrame
        first = HT.read_frame!(reader)
    end
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

function _read_h2_server_data_frame!(reader::IO)::HT.DataFrame
    while true
        frame = HT.read_frame!(reader)
        frame isa HT.DataFrame && return frame::HT.DataFrame
        frame isa HT.WindowUpdateFrame && continue
        frame isa HT.SettingsFrame && continue
        frame isa HT.PingFrame && continue
        error("expected data frame, got $(typeof(frame))")
    end
end

@testset "HTTP/2 server request handling" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            payload = collect(codeunits("h2:" * request.target))
            return HT.Response(200, HT.BytesBody(payload); content_length = length(payload), proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = HT.connect_h2!(address; secure = false)
    try
        req1 = HT.Request("GET", "/one"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        req2 = HT.Request("GET", "/two"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        res1 = HT.h2_roundtrip!(conn, req1)
        res2 = HT.h2_roundtrip!(conn, req2)
        @test res1.status == 200
        @test res2.status == 200
        @test String(_read_all_h2_server(res1.body)) == "h2:/one"
        @test String(_read_all_h2_server(res2.body)) == "h2:/two"
    finally
        close(conn)
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server request handlers support text response bodies" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
        _ = request
        return HT.Response(404, "Not found"; proto_major = 2, proto_minor = 0)
    end
    address = _wait_http_server_addr(server)
    conn = HT.connect_h2!(address; secure = false)
    try
        req = HT.Request("GET", "/missing"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        res = HT.h2_roundtrip!(conn, req)
        @test res.status == 404
        @test String(_read_all_h2_server(res.body)) == "Not found"
    finally
        close(conn)
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server servecontent supports ranges and conditionals" begin
    payload = collect(codeunits("abcdef"))
    modtime = Dates.DateTime(2024, 1, 2, 3, 4, 5)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            return HT.servecontent(request, payload; name = "demo.txt", etag = "\"v1\"", modtime = modtime)
        end
    address = _wait_http_server_addr(server)
    conn = HT.connect_h2!(address; secure = false)
    try
        range_headers = HT.Headers()
        HT.setheader(range_headers, "Range", "bytes=2-4")
        range_req = HT.Request("GET", "/"; host = address, headers = range_headers, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        range_res = HT.h2_roundtrip!(conn, range_req)
        @test range_res.status == 206
        @test HT.header(range_res.headers, "Content-Range") == "bytes 2-4/6"
        @test HT.header(range_res.headers, "Content-Length") == "3"
        @test String(_read_all_h2_server(range_res.body)) == "cde"

        none_match_headers = HT.Headers()
        HT.setheader(none_match_headers, "If-None-Match", "\"v1\"")
        none_match_req = HT.Request("GET", "/"; host = address, headers = none_match_headers, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        none_match_res = HT.h2_roundtrip!(conn, none_match_req)
        @test none_match_res.status == 304
        @test isempty(_read_all_h2_server(none_match_res.body))
    finally
        close(conn)
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server fileserver serves files and redirects canonically" begin
    mktempdir() do dir
        write(joinpath(dir, "hello.txt"), "hello world")
        docs_dir = joinpath(dir, "docs")
        mkpath(docs_dir)
        write(joinpath(docs_dir, "index.html"), "<p>docs</p>")

        server = HT.serve!(HT.fileserver(dir; etag = :weak_stat), "127.0.0.1", 0; listenany = true)
        address = _wait_http_server_addr(server)
        conn = HT.connect_h2!(address; secure = false)
        try
            range_headers = HT.Headers()
            HT.setheader(range_headers, "Range", "bytes=6-10")
            range_req = HT.Request("GET", "/hello.txt"; host = address, headers = range_headers, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
            range_res = HT.h2_roundtrip!(conn, range_req)
            @test range_res.status == 206
            @test HT.header(range_res.headers, "Content-Range") == "bytes 6-10/11"
            @test !isempty(HT.header(range_res.headers, "ETag", ""))
            @test String(_read_all_h2_server(range_res.body)) == "world"

            redirect_req = HT.Request("GET", "/docs"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
            redirect_res = HT.h2_roundtrip!(conn, redirect_req)
            @test redirect_res.status == 301
            @test HT.header(redirect_res.headers, "Location") == "/docs/"
            @test isempty(_read_all_h2_server(redirect_res.body))

            index_req = HT.Request("GET", "/docs/"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
            index_res = HT.h2_roundtrip!(conn, index_req)
            @test index_res.status == 200
            @test String(_read_all_h2_server(index_res.body)) == "<p>docs</p>"
        finally
            close(conn)
            HT.forceclose(server)
            _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
        end
    end
end

@testset "HTTP/2 server fileserver supports SPA fallback" begin
    mktempdir() do dir
        write(joinpath(dir, "index.html"), "<p>shell</p>")
        assets_dir = joinpath(dir, "assets")
        mkpath(assets_dir)
        write(joinpath(assets_dir, "app.js"), "console.log('ok');")

        server = HT.serve!(HT.fileserver(dir; spa_fallback = "index.html"), "127.0.0.1", 0; listenany = true)
        address = _wait_http_server_addr(server)
        conn = HT.connect_h2!(address; secure = false)
        try
            route_req = HT.Request("GET", "/gallery"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
            route_res = HT.h2_roundtrip!(conn, route_req)
            @test route_res.status == 200
            @test String(_read_all_h2_server(route_res.body)) == "<p>shell</p>"

            asset_req = HT.Request("GET", "/assets/app.js"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
            asset_res = HT.h2_roundtrip!(conn, asset_req)
            @test asset_res.status == 200
            @test String(_read_all_h2_server(asset_res.body)) == "console.log('ok');"

            missing_asset_req = HT.Request("GET", "/assets/missing.js"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
            missing_asset_res = HT.h2_roundtrip!(conn, missing_asset_req)
            @test missing_asset_res.status == 404
            @test isempty(_read_all_h2_server(missing_asset_res.body))

            dotted_route_req = HT.Request("GET", "/gallery.v2"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
            dotted_route_res = HT.h2_roundtrip!(conn, dotted_route_req)
            @test dotted_route_res.status == 404
            @test isempty(_read_all_h2_server(dotted_route_res.body))
        finally
            close(conn)
            HT.forceclose(server)
            _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
        end
    end
end

@testset "HTTP/2 server request handler timeout middleware" begin
    handler = HT.handlertimeout(0.05)(request -> begin
        if request.target == "/fast"
            return HT.Response(200, HT.BytesBody(UInt8[0x6f, 0x6b]); content_length = 2, proto_major = 2, proto_minor = 0)
        end
        sleep(0.15)
        return HT.Response(200, HT.BytesBody(UInt8[0x6c, 0x61, 0x74, 0x65]); content_length = 4, proto_major = 2, proto_minor = 0)
    end)
    server = HT.serve!(handler, "127.0.0.1", 0; listenany = true)
    address = _wait_http_server_addr(server)
    conn = HT.connect_h2!(address; secure = false)
    try
        slow_req = HT.Request("GET", "/slow"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        slow_res = HT.h2_roundtrip!(conn, slow_req)
        @test slow_res.status == 503
        @test String(_read_all_h2_server(slow_res.body)) == "handler timed out"

        fast_req = HT.Request("GET", "/fast"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        fast_res = HT.h2_roundtrip!(conn, fast_req)
        @test fast_res.status == 200
        @test String(_read_all_h2_server(fast_res.body)) == "ok"
    finally
        close(conn)
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server accepts legal request trailers" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            buf = Vector{UInt8}(undef, 8)
            body_bytes = UInt8[]
            while true
                n = HT.body_read!(request.body, buf)
                n == 0 && break
                append!(body_bytes, @view(buf[1:n]))
            end
            body = String(body_bytes)
            trailer = HT.header(request.trailers, "X-Trailer", "")
            payload = collect(codeunits(body * "|" * trailer))
            return HT.Response(200, HT.BytesBody(payload); content_length = length(payload), proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn, reader = _open_raw_h2_server_conn(address)
    encoder = HT.Encoder()
    decoder = HT.Decoder()
    try
        _write_h2_server_request_headers!(conn, encoder, UInt32(1), address, "/trailers"; method = "POST", end_stream = false)
        _write_frame_h2_server_raw!(conn, HT.DataFrame(UInt32(1), false, collect(codeunits("ok"))))
        trailer_block = HT.encode_header_block(encoder, HT.HeaderField[HT.HeaderField("x-trailer", "done", false)])
        _write_frame_h2_server_raw!(conn, HT.HeadersFrame(UInt32(1), true, true, trailer_block))
        headers_frame, header_block, _ = _read_h2_server_header_block!(reader)
        decoded_headers = HT.decode_header_block(decoder, header_block)
        @test any(field -> field.name == ":status" && field.value == "200", decoded_headers)
        data_frame = HT.read_frame!(reader)
        while data_frame isa HT.WindowUpdateFrame || data_frame isa HT.SettingsFrame || data_frame isa HT.PingFrame
            data_frame = HT.read_frame!(reader)
        end
        @test data_frame isa HT.DataFrame
        @test String((data_frame::HT.DataFrame).data) == "ok|done"
        @test (data_frame::HT.DataFrame).end_stream
    finally
        try
            NC.close(conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server rejects invalid request trailer pseudo-headers" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            return HT.Response(200, HT.BytesBody(UInt8[0x6f, 0x6b]); content_length = 2, proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = nothing
    try
        conn, reader = _open_raw_h2_server_conn(address)
        encoder = HT.Encoder()
        _write_h2_server_request_headers!(conn, encoder, UInt32(1), address, "/bad-trailer"; end_stream = false)
        bad_trailer_block = HT.encode_header_block(encoder, HT.HeaderField[HT.HeaderField(":path", "/oops", false)])
        _write_frame_h2_server_raw!(conn, HT.HeadersFrame(UInt32(1), true, true, bad_trailer_block))
        NC.set_deadline!(conn::NC.Conn, Int64(time_ns() + 1_000_000_000))
        saw_goaway = false
        saw_exception = false
        goaway_error_code = UInt32(0)
        try
            while true
                frame_or_err = try
                    HT.read_frame!(reader)
                catch err
                    err
                end
                if frame_or_err isa HT.GoAwayFrame
                    saw_goaway = true
                    goaway_error_code = (frame_or_err::HT.GoAwayFrame).error_code
                    break
                end
                if frame_or_err isa Exception
                    saw_exception = true
                    break
                end
            end
        finally
            NC.set_deadline!(conn::NC.Conn, Int64(0))
        end
        @test saw_goaway || saw_exception
        saw_goaway && @test goaway_error_code == UInt32(0x1)
    finally
        conn === nothing || try
            NC.close(conn::NC.Conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server fragments large response headers" begin
    large_value = repeat("h", 50_000)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            headers = HT.Headers()
            HT.setheader(headers, "X-Large", large_value)
            return HT.Response(200, HT.EmptyBody(); headers = headers, content_length = 0, proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn, reader = _open_raw_h2_server_conn(address)
    encoder = HT.Encoder()
    decoder = HT.Decoder()
    try
        _write_h2_server_request_headers!(conn, encoder, UInt32(1), address, "/large-headers")
        headers_frame, fragments, frames = _read_h2_server_header_block!(reader)
        @test headers_frame.end_stream
        @test !headers_frame.end_headers
        @test count(frame -> frame isa HT.ContinuationFrame, frames) > 0
        decoded = HT.decode_header_block(decoder, fragments)
        @test any(field -> field.name == ":status" && field.value == "200", decoded)
        @test any(field -> field.name == "x-large" && field.value == large_value, decoded)
    finally
        try
            NC.close(conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server fragments large response trailers" begin
    large_trailer = repeat("t", 50_000)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            trailers = HT.Headers()
            HT.setheader(trailers, "X-Large-Trailer", large_trailer)
            body = HT.BytesBody(collect(codeunits("ok")))
            return HT.Response(200, body; trailers = trailers, content_length = 2, proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn, reader = _open_raw_h2_server_conn(address)
    encoder = HT.Encoder()
    decoder = HT.Decoder()
    try
        _write_h2_server_request_headers!(conn, encoder, UInt32(1), address, "/large-trailers")
        headers_frame, header_block, _ = _read_h2_server_header_block!(reader)
        decoded_headers = HT.decode_header_block(decoder, header_block)
        @test any(field -> field.name == ":status" && field.value == "200", decoded_headers)
        data_frame = HT.read_frame!(reader)
        @test data_frame isa HT.DataFrame
        @test !(data_frame::HT.DataFrame).end_stream
        @test String((data_frame::HT.DataFrame).data) == "ok"
        trailer_frame, trailer_block, trailer_frames = _read_h2_server_header_block!(reader)
        @test trailer_frame.end_stream
        @test count(frame -> frame isa HT.ContinuationFrame, trailer_frames) > 0
        decoded_trailers = HT.decode_header_block(decoder, trailer_block)
        @test any(field -> field.name == "x-large-trailer" && field.value == large_trailer, decoded_trailers)
    finally
        try
            NC.close(conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server reuses HPACK encoder state across responses" begin
    repeated_value = repeat("r", 512)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            headers = HT.Headers()
            HT.setheader(headers, "X-Reused", repeated_value)
            return HT.Response(200, HT.EmptyBody(); headers = headers, content_length = 0, proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn, reader = _open_raw_h2_server_conn(address)
    encoder = HT.Encoder()
    decoder = HT.Decoder()
    try
        _write_h2_server_request_headers!(conn, encoder, UInt32(1), address, "/one")
        _, block1, _ = _read_h2_server_header_block!(reader)
        _ = HT.decode_header_block(decoder, block1)
        _write_h2_server_request_headers!(conn, encoder, UInt32(3), address, "/two")
        _, block2, _ = _read_h2_server_header_block!(reader)
        decoded2 = HT.decode_header_block(decoder, block2)
        @test any(field -> field.name == "x-reused" && field.value == repeated_value, decoded2)
        @test length(block2) < length(block1)
    finally
        try
            NC.close(conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server honors peer header table size settings" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            headers = HT.Headers()
            HT.setheader(headers, "X-Reused", "same")
            return HT.Response(200, HT.EmptyBody(); headers = headers, content_length = 0, proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn, reader = _open_raw_h2_server_conn(address; settings = Pair{UInt16, UInt32}[UInt16(0x1) => UInt32(0)])
    encoder = HT.Encoder()
    decoder = HT.Decoder()
    try
        _write_h2_server_request_headers!(conn, encoder, UInt32(1), address, "/one")
        _, block1, _ = _read_h2_server_header_block!(reader)
        decoded1 = HT.decode_header_block(decoder, block1)
        @test any(field -> field.name == "x-reused" && field.value == "same", decoded1)
        @test isempty(decoder.table.entries)

        _write_h2_server_request_headers!(conn, encoder, UInt32(3), address, "/two")
        _, block2, _ = _read_h2_server_header_block!(reader)
        decoded2 = HT.decode_header_block(decoder, block2)
        @test any(field -> field.name == "x-reused" && field.value == "same", decoded2)
        @test isempty(decoder.table.entries)
    finally
        try
            NC.close(conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server accepts duplicate peer settings in order" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            payload = collect(codeunits("dup:" * request.target))
            return HT.Response(200, HT.BytesBody(payload); content_length = length(payload), proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn, reader = _open_raw_h2_server_conn(address; settings = Pair{UInt16, UInt32}[
        UInt16(0x5) => UInt32(32_768),
        UInt16(0x5) => UInt32(16_384),
    ])
    encoder = HT.Encoder()
    decoder = HT.Decoder()
    try
        _write_h2_server_request_headers!(conn, encoder, UInt32(1), address, "/dup-settings")
        headers_frame = HT.read_frame!(reader)
        @test headers_frame isa HT.HeadersFrame
        decoded_headers = HT.decode_header_block(decoder, (headers_frame::HT.HeadersFrame).header_block_fragment)
        @test any(field -> field.name == ":status" && field.value == "200", decoded_headers)
        data_frame = HT.read_frame!(reader)
        @test data_frame isa HT.DataFrame
        @test String((data_frame::HT.DataFrame).data) == "dup:/dup-settings"
    finally
        try
            NC.close(conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server router request handlers work" begin
    router = HT.Router()
    HT.register!(router, "GET", "/router/{name}", req -> begin
            payload = collect(codeunits("router:" * HT.getparam(req, "name")))
            return HT.Response(200, HT.BytesBody(payload); content_length = length(payload), proto_major = 2, proto_minor = 0)
        end)
    server = HT.serve!(router, "127.0.0.1", 0; listenany = true)
    address = _wait_http_server_addr(server)
    conn = HT.connect_h2!(address; secure = false)
    try
        ok_req = HT.Request("GET", "/router/alex?debug=1"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        ok_res = HT.h2_roundtrip!(conn, ok_req)
        @test ok_res.status == 200
        @test String(_read_all_h2_server(ok_res.body)) == "router:alex"

        wrong_method = HT.Request("POST", "/router/alex"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        wrong_method_res = HT.h2_roundtrip!(conn, wrong_method)
        @test wrong_method_res.status == 405

        missing_req = HT.Request("GET", "/missing"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        missing_res = HT.h2_roundtrip!(conn, missing_req)
        @test missing_res.status == 404
    finally
        close(conn)
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server stream handlers work and suppress HEAD bodies" begin
    server = HT.listen!("127.0.0.1", 0; listenany = true) do stream
            request = HT.startread(stream)
            body = String(read(stream))
            HT.setstatus(stream, 200)
            HT.setheader(stream, "Content-Type", "text/plain")
            HT.startwrite(stream)
            write(stream, isempty(body) ? "ok" : body)
            return nothing
        end
    address = _wait_http_server_addr(server)
    conn = HT.connect_h2!(address; secure = false)
    try
        get_req = HT.Request("GET", "/stream"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        get_res = HT.h2_roundtrip!(conn, get_req)
        @test get_res.status == 200
        @test String(_read_all_h2_server(get_res.body)) == "ok"

        post_payload = collect(codeunits("echo"))
        post_req = HT.Request("POST", "/echo"; host = address, body = HT.BytesBody(post_payload), content_length = length(post_payload), proto_major = 2, proto_minor = 0)
        post_res = HT.h2_roundtrip!(conn, post_req)
        @test post_res.status == 200
        @test String(_read_all_h2_server(post_res.body)) == "echo"

        head_req = HT.Request("HEAD", "/head"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        head_res = HT.h2_roundtrip!(conn, head_req)
        @test head_res.status == 200
        @test isempty(_read_all_h2_server(head_res.body))
    finally
        close(conn)
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server stream handlers flush DATA before handler return" begin
    first_written = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    server = HT.listen!("127.0.0.1", 0; listenany = true) do stream
        _ = HT.startread(stream)
        HT.setstatus(stream, 200)
        HT.setheader(stream, "Content-Type", "text/plain")
        HT.startwrite(stream)
        write(stream, "first")
        put!(first_written, nothing)
        take!(release)
        write(stream, "second")
        return nothing
    end
    address = _wait_http_server_addr(server)
    conn = nothing
    try
        conn, reader = _open_raw_h2_server_conn(address)
        encoder = HT.Encoder()
        decoder = HT.Decoder()
        _write_h2_server_request_headers!(conn::NC.Conn, encoder, UInt32(1), address, "/streaming")
        take!(first_written)

        NC.set_read_deadline!(conn::NC.Conn, Int64(time_ns() + 1_000_000_000))
        headers_frame, header_block, _ = _read_h2_server_header_block!(reader)
        first_data = _read_h2_server_data_frame!(reader)
        NC.set_read_deadline!(conn::NC.Conn, Int64(0))

        decoded_headers = HT.decode_header_block(decoder, header_block)
        first_payload = copy(first_data.data)
        @test any(field -> field.name == ":status" && field.value == "200", decoded_headers)
        @test String(copy(first_payload)) == "first"
        @test !first_data.end_stream

        put!(release, nothing)
        body = first_payload
        while true
            frame = _read_h2_server_data_frame!(reader)
            append!(body, frame.data)
            frame.end_stream && break
        end
        @test String(body) == "firstsecond"
        @test headers_frame.stream_id == UInt32(1)
    finally
        isready(release) || put!(release, nothing)
        conn === nothing || try
            NC.close(conn::NC.Conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server router stream handlers work" begin
    router = HT.Router()
    HT.register!(router, "POST", "/stream/{name}", stream -> begin
            request = HT.startread(stream)
            body = String(read(stream))
            HT.setstatus(stream, 200)
            HT.setheader(stream, "Content-Type", "text/plain")
            write(stream, "router-stream:" * HT.getparam(request, "name") * ":" * body)
            return nothing
        end)
    server = HT.listen!(router, "127.0.0.1", 0; listenany = true)
    address = _wait_http_server_addr(server)
    conn = HT.connect_h2!(address; secure = false)
    try
        payload = collect(codeunits("echo"))
        req = HT.Request("POST", "/stream/sam?debug=1"; host = address, body = HT.BytesBody(payload), content_length = length(payload), proto_major = 2, proto_minor = 0)
        res = HT.h2_roundtrip!(conn, req)
        @test res.status == 200
        @test String(_read_all_h2_server(res.body)) == "router-stream:sam:echo"

        wrong_method = HT.Request("GET", "/stream/sam"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        wrong_method_res = HT.h2_roundtrip!(conn, wrong_method)
        @test wrong_method_res.status == 405
    finally
        close(conn)
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server request flow control for large uploads" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            total = 0
            buf = Vector{UInt8}(undef, 16 * 1024)
            while true
                n = HT.body_read!(request.body, buf)
                n == 0 && break
                total += n
            end
            payload = collect(codeunits(string(total)))
            return HT.Response(200, HT.BytesBody(payload); content_length = length(payload), proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = HT.connect_h2!(address; secure = false)
    try
        payload = fill(UInt8('u'), 70_000)
        req = HT.Request("POST", "/upload"; host = address, body = HT.BytesBody(payload), content_length = length(payload), proto_major = 2, proto_minor = 0)
        res = HT.h2_roundtrip!(conn, req)
        @test res.status == 200
        @test String(_read_all_h2_server(res.body)) == "70000"
    finally
        close(conn)
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server starts handling request bodies before upload completion" begin
    first_chunk_seen = Channel{String}(1)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            buf = Vector{UInt8}(undef, 5)
            n = HT.body_read!(request.body, buf)
            put!(first_chunk_seen, String(buf[1:n]))
            total = n
            while true
                n = HT.body_read!(request.body, buf)
                n == 0 && break
                total += n
            end
            payload = collect(codeunits(string(total)))
            return HT.Response(200, HT.BytesBody(payload); content_length = length(payload), proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = HT.connect_h2!(address; secure = false)
    try
        stage = Ref(1)
        request_body = HT.CallbackBody(
            dst -> begin
                if stage[] == 1
                    bytes = collect(codeunits("hello"))
                    copyto!(dst, 1, bytes, 1, length(bytes))
                    stage[] = 2
                    return length(bytes)
                end
                if stage[] == 2
                    bytes = collect(codeunits("!"))
                    copyto!(dst, 1, bytes, 1, length(bytes))
                    stage[] = 3
                    return length(bytes)
                end
                if stage[] == 3
                    sleep(1.0)
                    bytes = collect(codeunits("world"))
                    copyto!(dst, 1, bytes, 1, length(bytes))
                    stage[] = 4
                    return length(bytes)
                end
                return 0
            end,
            () -> nothing,
        )
        request = HT.Request("POST", "/stream-body"; host = address, body = request_body, content_length = 11, proto_major = 2, proto_minor = 0)
        started = time()
        response_task = Threads.@spawn HT.h2_roundtrip!(conn, request)
        first_chunk = take!(first_chunk_seen)
        elapsed = time() - started
        @test first_chunk == "hello"
        @test elapsed < 0.75
        response = fetch(response_task)
        @test response.status == 200
        @test String(_read_all_h2_server(response.body)) == "11"
    finally
        close(conn)
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server handles concurrent streams on one connection" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            sleep(1.0)
            payload = collect(codeunits(request.target))
            return HT.Response(200, HT.BytesBody(payload); content_length = length(payload), proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = HT.connect_h2!(address; secure = false)
    try
        req1 = HT.Request("GET", "/one"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        req2 = HT.Request("GET", "/two"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        started = time()
        task1 = Threads.@spawn begin
            response = HT.h2_roundtrip!(conn, req1)
            return (response.status, String(_read_all_h2_server(response.body)))
        end
        sleep(0.1)
        task2 = Threads.@spawn begin
            response = HT.h2_roundtrip!(conn, req2)
            return (response.status, String(_read_all_h2_server(response.body)))
        end
        res1 = fetch(task1)
        res2 = fetch(task2)
        elapsed = time() - started
        @test res1[1] == 200
        @test res2[1] == 200
        @test Set((res1[2], res2[2])) == Set(("/one", "/two"))
        @test elapsed < 1.75
    finally
        close(conn)
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server shutdown closes listener" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            return HT.Response(200, HT.BytesBody(UInt8[0x6f, 0x6b]); content_length = 2, proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = HT.connect_h2!(address; secure = false)
    try
        req = HT.Request("GET", "/ok"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        res = HT.h2_roundtrip!(conn, req)
        @test res.status == 200
    finally
        close(conn)
    end
    HT.forceclose(server)
    _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    fail_fast_resolver = ND.HostResolver(timeout_ns = Int64(1_000_000_000))
    @test_throws Exception HT.connect_h2!(address; secure = false, host_resolver = fail_fast_resolver)
end

@testset "HTTP/2 server close sends GOAWAY and drains active streams" begin
    started = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            put!(started, nothing)
            take!(release)
            payload = collect(codeunits("ok"))
            return HT.Response(200, HT.BytesBody(payload); content_length = length(payload), proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = nothing
    close_task = nothing
    try
        conn, reader = _open_raw_h2_server_conn(address)
        decoder = HT.Decoder()
        _write_h2_server_request_headers!(conn::NC.Conn, HT.Encoder(), UInt32(1), address, "/slow")
        take!(started)
        close_task = Threads.@spawn close(server)
        goaway = HT.read_frame!(reader)
        @test goaway isa HT.GoAwayFrame
        @test (goaway::HT.GoAwayFrame).error_code == UInt32(0)
        @test (goaway::HT.GoAwayFrame).last_stream_id == UInt32(1)

        put!(release, nothing)
        saw_headers = false
        response_body = UInt8[]
        while true
            frame = HT.read_frame!(reader)
            if frame isa HT.HeadersFrame
                headers_frame = frame::HT.HeadersFrame
                headers_frame.stream_id == UInt32(1) || continue
                decoded = HT.decode_header_block(decoder, headers_frame.header_block_fragment)
                @test any(field -> field.name == ":status" && field.value == "200", decoded)
                saw_headers = true
                continue
            end
            frame isa HT.DataFrame || continue
            data_frame = frame::HT.DataFrame
            data_frame.stream_id == UInt32(1) || continue
            append!(response_body, data_frame.data)
            data_frame.end_stream && break
        end
        @test saw_headers
        @test String(response_body) == "ok"
        close_task === nothing || fetch(close_task::Task)
        fail_fast_resolver = ND.HostResolver(timeout_ns = Int64(1_000_000_000))
        @test_throws Exception HT.connect_h2!(address; secure = false, host_resolver = fail_fast_resolver)
    finally
        conn === nothing || try
            NC.close(conn::NC.Conn)
        catch
        end
        close_task === nothing || try
            fetch(close_task::Task)
        catch
        end
        isopen(server) && HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server splits large response bodies into valid DATA frames" begin
    large_payload = fill(UInt8('z'), 70_000)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            return HT.Response(200, HT.BytesBody(large_payload); content_length = length(large_payload), proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = HT.connect_h2!(address; secure = false)
    try
        req = HT.Request("GET", "/large"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        res = HT.h2_roundtrip!(conn, req)
        @test res.status == 200
        body = _read_all_h2_server(res.body)
        @test length(body) == 70_000
        @test body == large_payload
    finally
        close(conn)
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server suppresses bodies for 204 and 304 responses" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            payload = collect(codeunits("oops"))
            if request.target == "/nocontent"
                return HT.Response(204, HT.BytesBody(payload); content_length = length(payload), proto_major = 2, proto_minor = 0)
            end
            return HT.Response(304, HT.BytesBody(payload); content_length = length(payload), proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = HT.connect_h2!(address; secure = false)
    try
        no_content_req = HT.Request("GET", "/nocontent"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        no_content_res = HT.h2_roundtrip!(conn, no_content_req)
        @test no_content_res.status == 204
        @test isempty(_read_all_h2_server(no_content_res.body))

        not_modified_req = HT.Request("GET", "/not-modified"; host = address, body = HT.EmptyBody(), content_length = 0, proto_major = 2, proto_minor = 0)
        not_modified_res = HT.h2_roundtrip!(conn, not_modified_req)
        @test not_modified_res.status == 304
        @test isempty(_read_all_h2_server(not_modified_res.body))
    finally
        close(conn)
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server rejects invalid continuation sequencing" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            return HT.Response(200, HT.BytesBody(UInt8[0x6f, 0x6b]); content_length = 2, proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = ND.connect("tcp", address)
    reader = HT._ConnReader(conn)
    try
        _write_all_h2_server_raw!(conn, HT._H2_PREFACE)
        _write_frame_h2_server_raw!(conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
        _ = HT.read_frame!(reader)
        _ = HT.read_frame!(reader)
        encoder = HT.Encoder()
        header_block = HT.encode_header_block(
            encoder,
            HT.HeaderField[
                HT.HeaderField(":method", "GET", false),
                HT.HeaderField(":scheme", "http", false),
                HT.HeaderField(":authority", address, false),
                HT.HeaderField(":path", "/bad", false),
            ],
        )
        split_idx = max(1, length(header_block) ÷ 2)
        _write_frame_h2_server_raw!(conn, HT.HeadersFrame(UInt32(1), false, false, header_block[1:split_idx]))
        _write_frame_h2_server_raw!(conn, HT.DataFrame(UInt32(1), true, UInt8[]))
        NC.set_deadline!(conn, Int64(time_ns() + 1_000_000_000))
        frame_or_err = try
            HT.read_frame!(reader)
        catch err
            err
        finally
            NC.set_deadline!(conn, Int64(0))
        end
        @test frame_or_err isa HT.GoAwayFrame || frame_or_err isa Exception
        if frame_or_err isa HT.GoAwayFrame
            @test (frame_or_err::HT.GoAwayFrame).error_code == UInt32(0x1)
        end
    finally
        try
            NC.close(conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server rejects invalid request headers" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            return HT.Response(200, HT.BytesBody(UInt8[0x6f, 0x6b]); content_length = 2, proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    invalid_cases = (
        HT.HeaderField[
            HT.HeaderField(":method", "GET", false),
            HT.HeaderField(":scheme", "http", false),
            HT.HeaderField("x-test", "1", false),
            HT.HeaderField(":authority", address, false),
            HT.HeaderField(":path", "/bad-order", false),
        ],
        HT.HeaderField[
            HT.HeaderField(":method", "GET", false),
            HT.HeaderField(":scheme", "http", false),
            HT.HeaderField(":authority", address, false),
            HT.HeaderField(":path", "/bad-connection", false),
            HT.HeaderField("connection", "close", false),
        ],
        HT.HeaderField[
            HT.HeaderField(":method", "GET", false),
            HT.HeaderField(":scheme", "http", false),
            HT.HeaderField(":authority", address, false),
            HT.HeaderField(":path", "/bad-value", false),
            HT.HeaderField("x-test", "ok\r\nInjected: yes", false),
        ],
        HT.HeaderField[
            HT.HeaderField(":method", "GET", false),
            HT.HeaderField(":scheme", "http", false),
            HT.HeaderField(":authority", address, false),
            HT.HeaderField(":path", "/bad-name", false),
            HT.HeaderField("bad name", "ok", false),
        ],
    )
    try
        for header_fields in invalid_cases
            conn = nothing
            try
                conn, reader = _open_raw_h2_server_conn(address)
                _write_frame_h2_server_raw!(conn::NC.Conn, HT.HeadersFrame(UInt32(1), true, true, HT.encode_header_block(HT.Encoder(), header_fields)))
                NC.set_deadline!(conn::NC.Conn, Int64(time_ns() + 1_000_000_000))
                frame_or_err = try
                    HT.read_frame!(reader)
                catch err
                    err
                finally
                    NC.set_deadline!(conn::NC.Conn, Int64(0))
                end
                @test frame_or_err isa HT.GoAwayFrame || frame_or_err isa Exception
                if frame_or_err isa HT.GoAwayFrame
                    @test (frame_or_err::HT.GoAwayFrame).error_code == UInt32(0x1)
                end
            finally
                conn === nothing || try
                    NC.close(conn::NC.Conn)
                catch
                end
            end
        end
    finally
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server combines cookie fields with semicolons" begin
    fields = HT.HeaderField[
        HT.HeaderField(":method", "GET", false),
        HT.HeaderField(":scheme", "http", false),
        HT.HeaderField(":authority", "example.test", false),
        HT.HeaderField(":path", "/", false),
        HT.HeaderField("cookie", "a=1", false),
        HT.HeaderField("cookie", "b=2", false),
    ]
    _, _, _, _, headers = HT._validate_h2_request_headers!(fields)
    @test HT.header(headers, "Cookie") == "a=1; b=2"
end

@testset "HTTP/2 server rejects request Content-Length mismatches" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = String(_read_all_h2_server(request.body))
            return HT.Response(200, HT.BytesBody(UInt8[0x6f, 0x6b]); content_length = 2, proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    try
        for (declared, payload) in ((2, "abc"), (5, "abc"))
            conn = nothing
            try
                conn, reader = _open_raw_h2_server_conn(address)
                encoder = HT.Encoder()
                _write_h2_server_request_headers!(
                    conn::NC.Conn,
                    encoder,
                    UInt32(1),
                    address,
                    "/bad-length";
                    method = "POST",
                    headers = HT.HeaderField[HT.HeaderField("content-length", string(declared), false)],
                    end_stream = false,
                )
                _write_frame_h2_server_raw!(conn::NC.Conn, HT.DataFrame(UInt32(1), true, collect(codeunits(payload))))
                NC.set_deadline!(conn::NC.Conn, Int64(time_ns() + 1_000_000_000))
                frame_or_err = try
                    HT.read_frame!(reader)
                catch err
                    err
                finally
                    NC.set_deadline!(conn::NC.Conn, Int64(0))
                end
                @test frame_or_err isa HT.GoAwayFrame || frame_or_err isa Exception
                if frame_or_err isa HT.GoAwayFrame
                    @test (frame_or_err::HT.GoAwayFrame).error_code == UInt32(0x1)
                end
            finally
                conn === nothing || try
                    NC.close(conn::NC.Conn)
                catch
                end
            end
        end
    finally
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server rejects oversized request header blocks" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true, max_header_bytes = 64) do request
            _ = request
            return HT.Response(200, HT.BytesBody(UInt8[0x6f, 0x6b]); content_length = 2, proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = nothing
    try
        conn, reader = _open_raw_h2_server_conn(address)
        encoder = HT.Encoder()
        large_value = String(UInt8[UInt8(0x21 + ((i - 1) % 90)) for i in 1:512])
        header_fields = HT.HeaderField[
            HT.HeaderField(":method", "GET", false),
            HT.HeaderField(":scheme", "http", false),
            HT.HeaderField(":authority", address, false),
            HT.HeaderField(":path", "/oversized-block", false),
            HT.HeaderField("x-huge", large_value, false),
        ]
        header_block = HT.encode_header_block(encoder, header_fields)
        @test length(header_block) > 128
        split_idx = max(1, length(header_block) ÷ 2)
        _write_frame_h2_server_raw!(conn::NC.Conn, HT.HeadersFrame(UInt32(1), true, false, header_block[1:split_idx]))
        _write_frame_h2_server_raw!(conn::NC.Conn, HT.ContinuationFrame(UInt32(1), true, header_block[(split_idx + 1):end]))
        NC.set_deadline!(conn::NC.Conn, Int64(time_ns() + 1_000_000_000))
        frame_or_err = try
            HT.read_frame!(reader)
        catch err
            err
        finally
            NC.set_deadline!(conn::NC.Conn, Int64(0))
        end
        @test frame_or_err isa HT.GoAwayFrame || frame_or_err isa Exception
        if frame_or_err isa HT.GoAwayFrame
            @test (frame_or_err::HT.GoAwayFrame).error_code == UInt32(0x1)
        end
    finally
        conn === nothing || try
            NC.close(conn::NC.Conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server rejects oversized decoded request header lists" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true, max_header_bytes = 96) do request
            _ = request
            return HT.Response(200, HT.BytesBody(UInt8[0x6f, 0x6b]); content_length = 2, proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = nothing
    try
        conn, reader = _open_raw_h2_server_conn(address)
        encoder = HT.Encoder()
        header_fields = HT.HeaderField[
            HT.HeaderField(":method", "GET", false),
            HT.HeaderField(":scheme", "http", false),
            HT.HeaderField(":authority", address, false),
            HT.HeaderField(":path", "/oversized-list", false),
            HT.HeaderField("x-a", repeat("a", 20), false),
            HT.HeaderField("x-b", repeat("b", 20), false),
        ]
        header_block = HT.encode_header_block(encoder, header_fields)
        @test length(header_block) <= 192
        _write_frame_h2_server_raw!(conn::NC.Conn, HT.HeadersFrame(UInt32(1), true, true, header_block))
        NC.set_deadline!(conn::NC.Conn, Int64(time_ns() + 1_000_000_000))
        frame_or_err = try
            HT.read_frame!(reader)
        catch err
            err
        finally
            NC.set_deadline!(conn::NC.Conn, Int64(0))
        end
        @test frame_or_err isa HT.GoAwayFrame || frame_or_err isa Exception
        if frame_or_err isa HT.GoAwayFrame
            @test (frame_or_err::HT.GoAwayFrame).error_code == UInt32(0x1)
        end
    finally
        conn === nothing || try
            NC.close(conn::NC.Conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server honors peer response-header filtering and stream flow control" begin
    payload = fill(UInt8('x'), 128)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            headers = HT.Headers()
            HT.appendheader(headers, "Connection", "keep-alive")
            HT.appendheader(headers, "Keep-Alive", "timeout=5")
            HT.appendheader(headers, "Transfer-Encoding", "chunked")
            HT.appendheader(headers, "TE", "trailers")
            HT.appendheader(headers, "Trailer", "x-drop-me")
            HT.appendheader(headers, "X-Extra", "ok")
            return HT.Response(200, HT.BytesBody(payload); headers = headers, content_length = length(payload), proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = nothing
    try
        conn, reader = _open_raw_h2_server_conn(address; settings = Pair{UInt16, UInt32}[UInt16(0x4) => UInt32(32)])
        decoder = HT.Decoder()
        _write_h2_server_request_headers!(conn::NC.Conn, HT.Encoder(), UInt32(1), address, "/windowed")
        headers_frame = HT.read_frame!(reader)
        @test headers_frame isa HT.HeadersFrame
        decoded_headers = HT.decode_header_block(decoder, (headers_frame::HT.HeadersFrame).header_block_fragment)
        @test any(field -> field.name == ":status" && field.value == "200", decoded_headers)
        @test any(field -> field.name == "x-extra" && field.value == "ok", decoded_headers)
        @test all(field -> !(field.name in ("connection", "keep-alive", "te", "trailer", "transfer-encoding", "upgrade")), decoded_headers)

        first_data = HT.read_frame!(reader)
        @test first_data isa HT.DataFrame
        @test length((first_data::HT.DataFrame).data) == 32
        @test !((first_data::HT.DataFrame).end_stream)

        _write_frame_h2_server_raw!(conn::NC.Conn, HT.WindowUpdateFrame(UInt32(1), UInt32(96)))
        received = length((first_data::HT.DataFrame).data)
        while received < length(payload)
            frame = HT.read_frame!(reader)
            frame isa HT.DataFrame || continue
            received += length((frame::HT.DataFrame).data)
            (frame::HT.DataFrame).end_stream && break
        end
        @test received == length(payload)
    finally
        conn === nothing || try
            NC.close(conn::NC.Conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server honors connection-level flow control on responses" begin
    payload = fill(UInt8('z'), 70_000)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            return HT.Response(200, HT.BytesBody(payload); content_length = length(payload), proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = nothing
    try
        conn, reader = _open_raw_h2_server_conn(address)
        _write_h2_server_request_headers!(conn::NC.Conn, HT.Encoder(), UInt32(1), address, "/conn-window")
        headers_frame = HT.read_frame!(reader)
        @test headers_frame isa HT.HeadersFrame
        received = 0
        while received < 65_535
            frame = HT.read_frame!(reader)
            frame isa HT.DataFrame || continue
            received += length((frame::HT.DataFrame).data)
        end
        @test received == 65_535
        NC.set_deadline!(conn::NC.Conn, Int64(time_ns() + 250_000_000))
        stalled = try
            HT.read_frame!(reader)
            false
        catch
            true
        finally
            NC.set_deadline!(conn::NC.Conn, Int64(0))
        end
        @test stalled

        remaining = length(payload) - received
        _write_frame_h2_server_raw!(conn::NC.Conn, HT.WindowUpdateFrame(UInt32(0), UInt32(remaining)))
        _write_frame_h2_server_raw!(conn::NC.Conn, HT.WindowUpdateFrame(UInt32(1), UInt32(remaining)))
        while received < length(payload)
            frame = HT.read_frame!(reader)
            frame isa HT.DataFrame || continue
            received += length((frame::HT.DataFrame).data)
            (frame::HT.DataFrame).end_stream && break
        end
        @test received == length(payload)
    finally
        conn === nothing || try
            NC.close(conn::NC.Conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end

@testset "HTTP/2 server send-window reservation honors write deadlines" begin
    send_state = HT._H2SendWindowState()
    HT._register_h2_send_window!(send_state, UInt32(1))
    lock(send_state.state_lock)
    try
        send_state.conn_send_window = Int64(0)
    finally
        unlock(send_state.state_lock)
    end
    deadline_ns = Int64(time_ns()) + Int64(50_000_000)
    elapsed = @elapsed begin
        @test_throws Reseau.IOPoll.DeadlineExceededError HT._reserve_h2_send_window!(send_state, UInt32(1), 1, deadline_ns)
    end
    @test elapsed < 0.5
end

@testset "HTTP/2 server keeps the connection usable after stream resets" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            if request.target == "/cancel"
                sleep(0.3)
                return HT.Response(200, HT.BytesBody(collect(codeunits("cancel"))); content_length = 6, proto_major = 2, proto_minor = 0)
            end
            return HT.Response(200, HT.BytesBody(collect(codeunits("ok"))); content_length = 2, proto_major = 2, proto_minor = 0)
        end
    address = _wait_http_server_addr(server)
    conn = nothing
    try
        conn, reader = _open_raw_h2_server_conn(address)
        encoder = HT.Encoder()
        decoder = HT.Decoder()
        _write_h2_server_request_headers!(conn::NC.Conn, encoder, UInt32(1), address, "/cancel")
        _write_frame_h2_server_raw!(conn::NC.Conn, HT.RSTStreamFrame(UInt32(1), UInt32(0x8)))
        _write_h2_server_request_headers!(conn::NC.Conn, encoder, UInt32(3), address, "/ok")

        response_body = UInt8[]
        saw_headers = false
        while true
            frame = HT.read_frame!(reader)
            if frame isa HT.HeadersFrame
                headers_frame = frame::HT.HeadersFrame
                headers_frame.stream_id == UInt32(3) || continue
                decoded = HT.decode_header_block(decoder, headers_frame.header_block_fragment)
                @test any(field -> field.name == ":status" && field.value == "200", decoded)
                saw_headers = true
                continue
            end
            frame isa HT.DataFrame || continue
            data_frame = frame::HT.DataFrame
            data_frame.stream_id == UInt32(3) || continue
            append!(response_body, data_frame.data)
            data_frame.end_stream && break
        end
        @test saw_headers
        @test String(response_body) == "ok"
    finally
        try
            NC.close(conn::NC.Conn)
        catch
        end
        HT.forceclose(server)
        _ = timedwait(() -> istaskdone(server.serve_task::Task), 3.0; pollint = 0.001)
    end
end
