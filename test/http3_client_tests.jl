using Test
using HTTP
using Reseau

# The HTTP/3 client against an in-process HTTP/3 server over loopback QUIC.

@isdefined(_H3TestServer) || include("http3_test_server.jl")

const H3C = HTTP
const H3Q = Reseau.QUIC

function _h3c_request(method, target; headers = Pair{String,String}[], body = nothing)
    req = body === nothing ? H3C.Request(method, target, headers) : H3C.Request(method, target, headers, body)
    return req
end

function _h3c_wait_goaway(conn)
    lock(conn.lock)
    try
        while conn.goaway_id == typemax(UInt64)
            wait(conn.cond)
        end
    finally
        unlock(conn.lock)
    end
end

function _h3c_wait_settings(conn)
    lock(conn.lock)
    try
        while !conn.peer_settings_received
            wait(conn.cond)
        end
    finally
        unlock(conn.lock)
    end
end

function _h3c_wait_closed(conn)
    lock(conn.lock)
    try
        while conn.error === nothing
            wait(conn.cond)
        end
    finally
        unlock(conn.lock)
    end
end

function _h3c_read_all(body)
    out = UInt8[]
    buf = Vector{UInt8}(undef, 16 * 1024)
    while (n = H3C.body_read!(body, buf)) > 0
        append!(out, view(buf, 1:n))
    end
    return out
end

function _h3c_read_n(body, n)
    out = UInt8[]
    buf = Vector{UInt8}(undef, n)
    while length(out) < n
        k = H3C.body_read!(body, view(buf, 1:(n - length(out))))
        k == 0 && break
        append!(out, view(buf, 1:k))
    end
    return out
end

function _h3c_error(f)
    try
        f()
    catch err
        return err
    end
    return nothing
end

@testset "HTTP/3 client" begin
    @testset "GET over HTTP/3" begin
        seen = Channel{_H3TestRequest}(1)
        server = _h3t_server() do req, s, conn
            put!(seen, req)
            _h3t_respond!(s, 200, ["content-type" => "text/plain", "x-reply" => "yes"], "hello h3")
        end
        conn = _h3t_connect(server)
        try
            resp = H3C.h3_roundtrip!(conn, _h3c_request("GET", "/hello?x=1"; headers = ["X-Test" => "1", "Connection" => "keep-alive"]))
            @test resp.status == 200
            @test resp.version == v"3"
            @test H3C.header(resp, "Content-Type") == "text/plain"
            @test H3C.header(resp, "X-Reply") == "yes"
            @test String(_h3c_read_all(resp.body)) == "hello h3"
            req = take!(seen)
            pseudo = [(f.name, f.value) for f in req.headers if startswith(f.name, ":")]
            @test pseudo == [(":method", "GET"), (":authority", _h3t_address(server)), (":scheme", "https"), (":path", "/hello?x=1")]
            @test _h3t_header(req, "x-test") == "1"
            # Connection-specific headers are not sent (RFC 9114 Section 4.2).
            @test _h3t_header(req, "connection") === nothing
            # The client's control stream starts with its SETTINGS.
            settings = take!(server.client_settings)
            @test (H3C._H3_SETTING_MAX_FIELD_SECTION_SIZE => UInt64(H3C._H2_DEFAULT_MAX_HEADER_LIST_SIZE)) in settings
        finally
            close(conn)
            _h3t_close(server)
        end
    end

    @testset "request bodies, content length, and trailers" begin
        server = _h3t_server() do req, s, conn
            _h3t_respond!(s, 201, ["x-length" => something(_h3t_header(req, "content-length"), "none")], req.body;
                trailers = ["x-checksum" => string(sum(req.body))])
        end
        conn = _h3t_connect(server)
        try
            payload = rand(UInt8, 300_000)
            resp = H3C.h3_roundtrip!(conn, _h3c_request("POST", "/upload"; body = payload))
            @test resp.status == 201
            @test H3C.header(resp, "X-Length") == string(length(payload))
            @test _h3c_read_all(resp.body) == payload
            @test H3C.header(resp.trailers, "X-Checksum") == string(sum(payload))
            # A streaming body of unknown length is sent too.
            stream_body = H3C.CallbackBody(let chunks = [b"abc", b"defg"]
                dst -> begin
                    isempty(chunks) && return 0
                    chunk = popfirst!(chunks)
                    copyto!(dst, 1, chunk, 1, length(chunk))
                    return length(chunk)
                end
            end, () -> nothing)
            resp = H3C.h3_roundtrip!(conn, _h3c_request("PUT", "/stream"; body = stream_body))
            @test String(_h3c_read_all(resp.body)) == "abcdefg"
            @test H3C.header(resp, "X-Length") == "none"
        finally
            close(conn)
            _h3t_close(server)
        end
    end

    @testset "a response before the whole upload stops the upload" begin
        # The server answers after the request headers and stops the upload
        # with H3_NO_ERROR (RFC 9114 Section 4.1).
        server = _h3t_server(; raw = true) do s, conn
            header = H3C._h3_read_frame_header(s)
            H3C._h3_skip!(s, header[2])
            _h3t_respond!(s, 413, Pair{String,String}[], "too big")
            H3Q.stop_sending!(s, H3C._H3_NO_ERROR)
        end
        conn = _h3t_connect(server)
        try
            resp = H3C.h3_roundtrip!(conn, _h3c_request("POST", "/upload"; body = zeros(UInt8, 8 * 1024 * 1024)))
            @test resp.status == 413
            @test String(_h3c_read_all(resp.body)) == "too big"
        finally
            close(conn)
            _h3t_close(server)
        end
    end

    @testset "the server's header size limit is respected" begin
        server = _h3t_server(; settings = [H3C._H3_SETTING_MAX_FIELD_SECTION_SIZE => UInt64(200)]) do req, s, conn
            _h3t_respond!(s, 200)
        end
        conn = _h3t_connect(server)
        try
            _h3c_wait_settings(conn)
            @test H3C.h3_roundtrip!(conn, _h3c_request("GET", "/")).status == 200
            err = _h3c_error(() -> H3C.h3_roundtrip!(conn, _h3c_request("GET", "/"; headers = ["x-big" => repeat("v", 300)])))
            @test err isa H3C.ProtocolError
            @test occursin("SETTINGS_MAX_FIELD_SECTION_SIZE", err.message)
        finally
            close(conn)
            _h3t_close(server)
        end
    end

    @testset "concurrent requests share one connection" begin
        server = _h3t_server() do req, s, conn
            _h3t_respond!(s, 200, ["content-length" => string(length(req.body))], req.body)
        end
        conn = _h3t_connect(server)
        try
            tasks = map(1:20) do i
                Threads.@spawn begin
                    payload = rand(UInt8, 10_000 * i)
                    resp = H3C.h3_roundtrip!(conn, _h3c_request("POST", "/echo/$i"; body = payload))
                    _h3c_read_all(resp.body) == payload
                end
            end
            @test all(fetch, tasks)
            @test length(server.conns) == 1
        finally
            close(conn)
            _h3t_close(server)
        end
    end

    @testset "informational responses and unknown frames are skipped" begin
        server = _h3t_server(; control_extra = _h3t_frame(0x21, UInt8[1, 2, 3])) do req, s, conn
            out = _h3t_headers_frame(":status" => "103", "link" => "</style.css>; rel=preload")
            append!(out, _h3t_frame(0x41, UInt8[]))  # an unknown type
            append!(out, _h3t_headers_frame(":status" => "200"))
            append!(out, _h3t_frame(0x21, UInt8[9]))
            append!(out, _h3t_data_frame("a"))
            append!(out, _h3t_data_frame(""))
            append!(out, _h3t_data_frame("b"))
            write(s, out)
            closewrite(s)
            # An unknown unidirectional stream type is ignored.
            u = H3Q.open_stream(conn; bidi = false)
            write(u, UInt8[0x21, 0xff])
            closewrite(u)
        end
        conn = _h3t_connect(server)
        try
            resp = H3C.h3_roundtrip!(conn, _h3c_request("GET", "/"))
            @test resp.status == 200
            @test String(_h3c_read_all(resp.body)) == "ab"
            resp = H3C.h3_roundtrip!(conn, _h3c_request("GET", "/again"))
            @test String(_h3c_read_all(resp.body)) == "ab"
        finally
            close(conn)
            _h3t_close(server)
        end
    end

    @testset "HEAD and bodyless statuses" begin
        server = _h3t_server() do req, s, conn
            _h3t_respond!(s, 200, ["content-length" => "1000"])
        end
        conn = _h3t_connect(server)
        try
            resp = H3C.h3_roundtrip!(conn, _h3c_request("HEAD", "/"))
            @test resp.status == 200
            @test isempty(_h3c_read_all(resp.body))
        finally
            close(conn)
            _h3t_close(server)
        end
    end

    @testset "a rejected request is safe to retry" begin
        server = _h3t_server() do req, s, conn
            H3Q.reset_stream!(s, H3C._H3_REQUEST_REJECTED)
        end
        conn = _h3t_connect(server)
        try
            err = _h3c_error(() -> H3C.h3_roundtrip!(conn, _h3c_request("GET", "/")))
            @test err isa H3C.H3StreamResetError
            @test err.code == H3C._H3_REQUEST_REJECTED
            @test H3C._h3_guaranteed_unprocessed(err)
        finally
            close(conn)
            _h3t_close(server)
        end
    end

    @testset "content length mismatches fail the body read" begin
        server = _h3t_server() do req, s, conn
            _h3t_respond!(s, 200, ["content-length" => "10"], req.body)
        end
        conn = _h3t_connect(server)
        try
            for (body, problem) in (("short", "ended before"), ("much too long", "exceeded"))
                resp = H3C.h3_roundtrip!(conn, _h3c_request("POST", "/"; body))
                err = _h3c_error(() -> _h3c_read_all(resp.body))
                @test err isa H3C.ProtocolError && occursin(problem, err.message)
            end
        finally
            close(conn)
            _h3t_close(server)
        end
    end

    @testset "closing a body early cancels the stream" begin
        stopped = Channel{Any}(1)
        server = _h3t_server() do req, s, conn
            out = _h3t_headers_frame(":status" => "200")
            append!(out, _h3t_data_frame(zeros(UInt8, 1000)))
            write(s, out)
            try
                while true
                    write(s, _h3t_data_frame(zeros(UInt8, 16_384)))
                end
            catch err
                put!(stopped, err)
            end
        end
        conn = _h3t_connect(server)
        try
            resp = H3C.h3_roundtrip!(conn, _h3c_request("GET", "/forever"))
            @test length(_h3c_read_n(resp.body, 100)) == 100
            H3C.body_close!(resp.body)
            err = take!(stopped)
            @test err isa H3Q.StreamStoppedError && err.code == H3C._H3_REQUEST_CANCELLED
        finally
            close(conn)
            _h3t_close(server)
        end
    end

    @testset "GOAWAY stops new requests on the connection" begin
        started = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        server = _h3t_server() do req, s, conn
            put!(started, nothing)
            take!(release)
            _h3t_respond!(s, 200, Pair{String,String}[], "done")
        end
        conn = _h3t_connect(server)
        try
            inflight = Threads.@spawn H3C.h3_roundtrip!(conn, _h3c_request("GET", "/slow"))
            take!(started)
            # Stream 0 may finish; nothing from stream 4 on is processed.
            _h3t_send_control!(server, _h3t_frame(H3C._H3_FRAME_GOAWAY, UInt8[0x04]))
            _h3c_wait_goaway(conn)
            @test !H3C._h3_conn_available(conn)
            err = _h3c_error(() -> H3C.h3_roundtrip!(conn, _h3c_request("GET", "/late")))
            @test err isa H3C.H3GoAwayError
            @test H3C._h3_guaranteed_unprocessed(err)
            put!(release, nothing)
            @test String(_h3c_read_all(fetch(inflight).body)) == "done"
        finally
            close(conn)
            _h3t_close(server)
        end
    end

    @testset "malformed responses close the connection with the right error" begin
        for (label, frames, code) in (
            ("DATA before HEADERS", _h3t_data_frame("x"), H3C._H3_FRAME_UNEXPECTED),
            ("undecodable QPACK", _h3t_frame(H3C._H3_FRAME_HEADERS, UInt8[0x01, 0x00, 0x80]), H3C._QPACK_DECOMPRESSION_FAILED),
            ("SETTINGS on a request stream", _h3t_frame(H3C._H3_FRAME_SETTINGS, UInt8[]), H3C._H3_FRAME_UNEXPECTED),
            ("an HTTP/2 frame type", _h3t_frame(0x02, UInt8[]), H3C._H3_FRAME_UNEXPECTED),
            ("a server push", _h3t_frame(H3C._H3_FRAME_PUSH_PROMISE, UInt8[0x00]), H3C._H3_ID_ERROR),
            ("a truncated frame", UInt8[0x01, 0x05, 0x00], H3C._H3_FRAME_ERROR),
        )
            server = _h3t_server() do req, s, conn
                write(s, frames)
                closewrite(s)
            end
            conn = _h3t_connect(server)
            try
                err = _h3c_error(() -> _h3c_read_all(H3C.h3_roundtrip!(conn, _h3c_request("GET", "/")).body))
                @test err isa H3C.ProtocolError
                peer_err = take!(server.conn_errors)
                @test peer_err isa H3Q.ConnectionError
                @test peer_err.app && peer_err.code == code
                @test !H3C._h3_conn_available(conn)
            finally
                close(conn)
                _h3t_close(server)
            end
        end
    end

    @testset "a second control stream closes the connection" begin
        server = _h3t_server((req, s, conn) -> nothing)
        conn = _h3t_connect(server)
        try
            _h3c_wait_settings(conn)
            server_conn = _h3t_server_conn(server)
            extra = H3Q.open_stream(server_conn; bidi = false)
            out = UInt8[]
            H3C._h3_append_varint!(out, H3C._H3_STREAM_CONTROL)
            append!(out, _h3t_frame(H3C._H3_FRAME_SETTINGS, UInt8[]))
            write(extra, out)
            err = take!(server.conn_errors)
            @test err isa H3Q.ConnectionError
            @test err.app && err.code == H3C._H3_STREAM_CREATION_ERROR
        finally
            close(conn)
            _h3t_close(server)
        end
    end

    @testset "control stream errors close the connection" begin
        goaway_first = _h3t_frame(H3C._H3_FRAME_GOAWAY, UInt8[0x00])
        data_on_control = vcat(_h3t_frame(H3C._H3_FRAME_SETTINGS, UInt8[]), _h3t_data_frame("x"))
        bad_goaway = vcat(_h3t_frame(H3C._H3_FRAME_SETTINGS, UInt8[]), _h3t_frame(H3C._H3_FRAME_GOAWAY, UInt8[0x01]))
        raised_goaway = vcat(_h3t_frame(H3C._H3_FRAME_SETTINGS, UInt8[]),
            _h3t_frame(H3C._H3_FRAME_GOAWAY, UInt8[0x04]), _h3t_frame(H3C._H3_FRAME_GOAWAY, UInt8[0x08]))
        for (label, kw, code) in (
            ("no SETTINGS first", (; control_payload = goaway_first), H3C._H3_MISSING_SETTINGS),
            ("a closed control stream", (; close_control = true), H3C._H3_CLOSED_CRITICAL_STREAM),
            ("DATA on the control stream", (; control_payload = data_on_control), H3C._H3_FRAME_UNEXPECTED),
            ("GOAWAY naming a server stream", (; control_payload = bad_goaway), H3C._H3_ID_ERROR),
            ("a GOAWAY raising the limit", (; control_payload = raised_goaway), H3C._H3_ID_ERROR),
            ("HTTP/2 settings", (; settings = [UInt64(0x03) => UInt64(1)]), H3C._H3_SETTINGS_ERROR),
        )
            server = _h3t_server((req, s, conn) -> nothing; kw...)
            conn = _h3t_connect(server)
            try
                err = take!(server.conn_errors)
                @test err isa H3Q.ConnectionError
                @test err.app && err.code == code
                _h3c_wait_closed(conn)
                @test !H3C._h3_conn_available(conn)
            finally
                close(conn)
                _h3t_close(server)
            end
        end
    end
end
