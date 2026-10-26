using Test
using HTTP
using Reseau

# HTTP/3 client cases ported from quic-go v0.48.2 http3/ (client_test.go,
# conn_test.go, transport_test.go, headers_test.go, body_test.go). Each
# testset is named after the quic-go case it ports. quic-go drives mocked
# streams; here an in-process HTTP/3 server sends the same bytes and observes
# the same stream cancellations. Where this client deliberately differs from
# quic-go, the testset says how.
#
# Not ported: server, response writer, datagram, capsule, Extended CONNECT,
# 0-RTT, and hijacker cases (unsupported); gzip (handled above the protocol in
# HTTP.Client); Go API details (nil bodies, Transport options, Stringers).

@isdefined(_H3TestServer) || include("http3_test_server.jl")

const H3G = HTTP
const H3GQ = Reseau.QUIC

_h3g_request(method, target; headers = Pair{String,String}[], body = nothing) =
    body === nothing ? H3G.Request(method, target, headers) : H3G.Request(method, target, headers, body)

function _h3g_error(f)
    try
        f()
    catch err
        return err
    end
    return nothing
end

function _h3g_read_all(body)
    out = UInt8[]
    buf = Vector{UInt8}(undef, 16 * 1024)
    while (n = H3G.body_read!(body, buf)) > 0
        append!(out, view(buf, 1:n))
    end
    return out
end

# Reads until an error; returns what was read and the error.
function _h3g_read_until_error(body)
    out = UInt8[]
    buf = Vector{UInt8}(undef, 1)
    try
        while (n = H3G.body_read!(body, buf)) > 0
            append!(out, view(buf, 1:n))
        end
    catch err
        return out, err
    end
    return out, nothing
end

# Writes on `s` until the client's STOP_SENDING arrives; returns its code.
# The bytes are reserved frames (RFC 9114 Section 7.2.8), which the client
# ignores whether or not it has the response head yet.
function _h3g_stop_code(s)
    chunk = UInt8[]
    H3G._h3_append_varint!(chunk, UInt64(0x21))
    H3G._h3_append_varint!(chunk, UInt64(1020))
    append!(chunk, zeros(UInt8, 1020))
    for _ in 1:100_000
        try
            write(s, chunk)
        catch err
            err isa H3GQ.StreamStoppedError && return err.code
            err isa H3GQ.ConnectionError && return :connection_closed
            rethrow()
        end
        yield()
    end
    return nothing
end

# Reads `s` until the client's RESET_STREAM arrives; returns the bytes read
# before it and its code (nothing when the stream ended cleanly).
function _h3g_reset_code(s)
    got = UInt8[]
    try
        while !eof(s)
            append!(got, readavailable(s))
        end
    catch err
        err isa H3GQ.StreamResetError && return got, err.code
        rethrow()
    end
    return got, nothing
end

_h3g_wait(conn, pred) = lock(conn.lock) do
    while !pred(conn)
        wait(conn.cond)
    end
end

_h3g_settings_frame() = _h3t_frame(H3G._H3_FRAME_SETTINGS, UInt8[])

function _h3g_uni!(server_conn, type::UInt64, payload::Vector{UInt8} = UInt8[]; fin::Bool = false)
    s = H3GQ.open_stream(server_conn; bidi = false)
    out = UInt8[]
    H3G._h3_append_varint!(out, type)
    append!(out, payload)
    write(s, out)
    fin && closewrite(s)
    return s
end

_h3g_server_conn(server) = _h3t_server_conn(server)

function _h3g_with(f, server)
    conn = _h3t_connect(server)
    try
        f(conn)
    finally
        close(conn)
        _h3t_close(server)
    end
end

@testset "HTTP/3 client: cases ported from quic-go" begin
    @testset "client_test: receives SETTINGS" begin
        server = _h3t_server(; settings = [H3G._H3_SETTING_MAX_FIELD_SECTION_SIZE => UInt64(1337)]) do req, s, conn
        end
        _h3g_with(server) do conn
            _h3g_wait(conn, c -> c.peer_settings_received)
            @test conn.peer_max_field_section_size == 1337
        end
    end

    @testset "client_test: cancels reading when hijacker didn't hijack an unidirectional stream" begin
        server = _h3t_server((req, s, conn) -> nothing)
        _h3g_with(server) do conn
            u = _h3g_uni!(_h3g_server_conn(server), UInt64(0x54))
            @test _h3g_stop_code(u) == H3G._H3_STREAM_CREATION_ERROR
            # The connection is unaffected.
            @test H3G._h3_conn_available(conn)
        end
    end

    @testset "client_test: closes the connection when hijacker didn't hijack a bidirectional stream" begin
        # A server must not open bidirectional streams (RFC 9114 Section 6.1).
        server = _h3t_server((req, s, conn) -> nothing)
        _h3g_with(server) do conn
            b = H3GQ.open_stream(_h3g_server_conn(server))
            write(b, _h3t_data_frame("x"))
            err = take!(server.conn_errors)
            @test err isa H3GQ.ConnectionError && err.app && err.code == H3G._H3_STREAM_CREATION_ERROR
        end
    end

    @testset "client_test: errors if it can't open a request stream" begin
        server = _h3t_server((req, s, conn) -> _h3t_respond!(s, 200))
        _h3g_with(server) do conn
            close(_h3g_server_conn(server); code = H3G._H3_NO_ERROR)
            _h3g_wait(conn, c -> c.error !== nothing)
            err = _h3g_error(() -> H3G.h3_roundtrip!(conn, _h3g_request("GET", "/")))
            @test err isa H3G.ProtocolError
        end
    end

    @testset "client_test: returns a response" begin
        server = _h3t_server((req, s, conn) -> _h3t_respond!(s, 418))
        _h3g_with(server) do conn
            resp = H3G.h3_roundtrip!(conn, _h3g_request("GET", "/"))
            @test resp.status == 418
            @test resp.version == v"3"
            @test resp.request !== nothing
        end
    end

    @testset "client_test: returns a response with trailers" begin
        server = _h3t_server((req, s, conn) -> _h3t_respond!(s, 418; trailers = ["this-is-a-trailer" => "0"]))
        _h3g_with(server) do conn
            resp = H3G.h3_roundtrip!(conn, _h3g_request("GET", "/"))
            @test isempty(_h3g_read_all(resp.body))
            @test H3G.header(resp.trailers, "This-Is-A-Trailer") == "0"
            @test resp.status == 418
        end
    end

    @testset "client_test: errors on invalid HEADERS frames" begin
        # A HEADERS frame claiming 10 bytes, followed by bytes that are not QPACK.
        server = _h3t_server(; raw = true) do s, conn
            out = _h3t_headers_frame(":status" => "418")
            H3G._h3_append_varint!(out, H3G._H3_FRAME_HEADERS)
            H3G._h3_append_varint!(out, UInt64(10))
            append!(out, codeunits("invalid headers frame"))
            write(s, out)
            closewrite(s)
        end
        _h3g_with(server) do conn
            resp = H3G.h3_roundtrip!(conn, _h3g_request("GET", "/"))
            @test _h3g_error(() -> _h3g_read_all(resp.body)) isa Exception
        end
    end

    # quic-go fails only the body read here; RFC 9114 Section 4.1 makes an
    # invalid frame sequence a connection error (H3_FRAME_UNEXPECTED), which
    # this client raises as well.
    for (label, second) in (
        ("returns an error if trailers are sent twice", () -> _h3t_headers_frame("this-is-a-trailer" => "1")),
        ("returns an error if body frame is received after trailers", () -> _h3t_data_frame("test body please ignore")),
    )
        @testset "client_test: $(label)" begin
            server = _h3t_server(; raw = true) do s, conn
                out = _h3t_headers_frame(":status" => "418")
                append!(out, _h3t_headers_frame("this-is-a-trailer" => "0"))
                append!(out, second())
                write(s, out)
                closewrite(s)
            end
            _h3g_with(server) do conn
                resp = H3G.h3_roundtrip!(conn, _h3g_request("GET", "/"))
                @test resp.status == 418
                @test _h3g_error(() -> _h3g_read_all(resp.body)) isa H3G.ProtocolError
                @test H3G.header(resp.trailers, "This-Is-A-Trailer") == "0"
                err = take!(server.conn_errors)
                @test err isa H3GQ.ConnectionError && err.code == H3G._H3_FRAME_UNEXPECTED
            end
        end
    end

    @testset "client_test: requests containing a Body: sends a request" begin
        seen = Channel{_H3TestRequest}(1)
        server = _h3t_server() do req, s, conn
            put!(seen, req)
            _h3t_respond!(s, 200)
        end
        _h3g_with(server) do conn
            H3G.h3_roundtrip!(conn, _h3g_request("POST", "/upload"; body = "request body"))
            req = take!(seen)
            @test _h3t_header(req, ":method") == "POST"
            @test _h3t_header(req, ":path") == "/upload"
            @test String(req.body) == "request body"
        end
    end

    @testset "client_test: requests containing a Body: doesn't send more bytes than allowed by http.Request.ContentLength" begin
        seen = Channel{Any}(1)
        server = _h3t_server(; raw = true) do s, conn
            # The whole stream, headers included: the reset may come first.
            put!(seen, _h3g_reset_code(s))
        end
        _h3g_with(server) do conn
            chunks = [b"request body"]
            body = H3G.CallbackBody(dst -> begin
                isempty(chunks) && return 0
                chunk = popfirst!(chunks)
                copyto!(dst, 1, chunk, 1, length(chunk))
                return length(chunk)
            end, () -> nothing)
            req = H3G.Request("POST", "/upload"; body, content_length = 7)
            @test _h3g_error(() -> H3G.h3_roundtrip!(conn, req)) isa Exception
            got, code = take!(seen)
            @test code == H3G._H3_REQUEST_CANCELLED
            @test !occursin("request body", String(got))
        end
    end

    @testset "client_test: requests containing a Body: returns the error that occurred when reading the body" begin
        seen = Channel{Any}(1)
        server = _h3t_server(; raw = true) do s, conn
            put!(seen, _h3g_reset_code(s)[2])
        end
        _h3g_with(server) do conn
            body = H3G.CallbackBody(dst -> error("testErr"), () -> nothing)
            err = _h3g_error(() -> H3G.h3_roundtrip!(conn, _h3g_request("POST", "/upload"; body)))
            @test err isa ErrorException && err.msg == "testErr"
            @test take!(seen) == H3G._H3_REQUEST_CANCELLED
        end
    end

    @testset "client_test: requests containing a Body: closes the connection when the first frame is not a HEADERS frame" begin
        server = _h3t_server(; raw = true) do s, conn
            H3G._h3_read_frame_header(s)
            out = UInt8[]
            H3G._h3_append_varint!(out, H3G._H3_FRAME_DATA)
            H3G._h3_append_varint!(out, UInt64(0x42))
            write(s, out)
        end
        _h3g_with(server) do conn
            @test _h3g_error(() -> H3G.h3_roundtrip!(conn, _h3g_request("POST", "/upload"; body = "x"))) isa H3G.ProtocolError
            err = take!(server.conn_errors)
            @test err isa H3GQ.ConnectionError && err.code == H3G._H3_FRAME_UNEXPECTED
        end
    end

    @testset "client_test: requests containing a Body: cancels the stream when parsing the headers fails" begin
        codes = Channel{Any}(1)
        server = _h3t_server(; raw = true) do s, conn
            if _h3t_header(_h3t_read_request(s), ":path") == "/bad"
                # :method is not a valid response pseudo-header.
                write(s, _h3t_headers_frame(":method" => "GET"))
                put!(codes, _h3g_stop_code(s))
            else
                _h3t_respond!(s, 200)
            end
        end
        _h3g_with(server) do conn
            @test _h3g_error(() -> H3G.h3_roundtrip!(conn, _h3g_request("GET", "/bad"))) isa H3G.ProtocolError
            @test take!(codes) == H3G._H3_MESSAGE_ERROR
            # Only the stream is cancelled.
            @test H3G.h3_roundtrip!(conn, _h3g_request("GET", "/good")).status == 200
        end
    end

    @testset "client_test: requests containing a Body: cancels the stream when the HEADERS frame is too large" begin
        codes = Channel{Any}(1)
        server = _h3t_server(; raw = true) do s, conn
            if _h3t_header(_h3t_read_request(s), ":path") == "/big"
                out = UInt8[]
                H3G._h3_append_varint!(out, H3G._H3_FRAME_HEADERS)
                H3G._h3_append_varint!(out, UInt64(1338))
                write(s, out)
                put!(codes, _h3g_stop_code(s))
            else
                _h3t_respond!(s, 200)
            end
        end
        _h3g_with(server) do conn
            conn.max_field_section_size = 1337
            err = _h3g_error(() -> H3G.h3_roundtrip!(conn, _h3g_request("GET", "/big")))
            @test err isa H3G.ProtocolError
            @test occursin("1338", err.message) && occursin("1337", err.message)
            @test take!(codes) == H3G._H3_FRAME_ERROR
            @test H3G.h3_roundtrip!(conn, _h3g_request("GET", "/small")).status == 200
        end
    end

    @testset "client_test: request cancellations: cancels a request while the request is still in flight" begin
        started = Channel{Nothing}(1)
        codes = Channel{Any}(1)
        server = _h3t_server(; raw = true) do s, conn
            _h3t_read_request(s)
            put!(started, nothing)
            put!(codes, _h3g_stop_code(s))
        end
        _h3g_with(server) do conn
            req = _h3g_request("GET", "/")
            ctx = H3G.get_request_context(req)
            t = Threads.@spawn _h3g_error(() -> H3G.h3_roundtrip!(conn, req))
            take!(started)
            H3G.cancel!(ctx)
            @test fetch(t) isa H3G.CanceledError
            @test take!(codes) == H3G._H3_REQUEST_CANCELLED
        end
    end

    @testset "client_test: request cancellations: cancels a request after the response arrived" begin
        codes = Channel{Any}(1)
        server = _h3t_server(; raw = true) do s, conn
            _h3t_read_request(s)
            write(s, _h3t_headers_frame(":status" => "404"))
            put!(codes, _h3g_stop_code(s))
        end
        _h3g_with(server) do conn
            req = _h3g_request("GET", "/")
            resp = H3G.h3_roundtrip!(conn, req)
            @test resp.status == 404
            H3G.cancel!(H3G.get_request_context(req))
            @test take!(codes) == H3G._H3_REQUEST_CANCELLED
        end
    end

    @testset "client_test: 1xx status code: continues to read next header if code is 103" begin
        server = _h3t_server(; raw = true) do s, conn
            _h3t_read_request(s)
            out = _h3t_headers_frame(":status" => "103", "link" => "</style.css>; rel=preload; as=style")
            append!(out, _h3t_headers_frame(":status" => "200"))
            write(s, out)
            closewrite(s)
        end
        _h3g_with(server) do conn
            @test H3G.h3_roundtrip!(conn, _h3g_request("GET", "/")).status == 200
        end
    end

    @testset "client_test: 1xx status code: doesn't continue to read next header if code is a terminal status" begin
        # quic-go returns a 101 as the final response; HTTP/3 has no protocol
        # upgrade (RFC 9114 Section 4.5), so this client rejects it.
        server = _h3t_server(; raw = true) do s, conn
            _h3t_read_request(s)
            write(s, _h3t_headers_frame(":status" => "101"))
            closewrite(s)
        end
        _h3g_with(server) do conn
            @test _h3g_error(() -> H3G.h3_roundtrip!(conn, _h3g_request("GET", "/"))) isa H3G.ProtocolError
        end
    end

    @testset "conn_test: control stream handling: ignores the QPACK encoder streams" begin
        server = _h3t_server((req, s, conn) -> _h3t_respond!(s, 200))
        _h3g_with(server) do conn
            server_conn = _h3g_server_conn(server)
            _h3g_uni!(server_conn, H3G._H3_STREAM_QPACK_ENCODER, UInt8[0x20])  # Set Dynamic Table Capacity 0
            _h3g_uni!(server_conn, H3G._H3_STREAM_QPACK_DECODER)
            @test H3G.h3_roundtrip!(conn, _h3g_request("GET", "/")).status == 200
            @test H3G._h3_conn_available(conn)
        end
    end

    for (label, type) in (("encoder", H3G._H3_STREAM_QPACK_ENCODER), ("decoder", H3G._H3_STREAM_QPACK_DECODER))
        @testset "conn_test: control stream handling: rejects duplicate QPACK $(label) streams" begin
            server = _h3t_server((req, s, conn) -> nothing)
            _h3g_with(server) do conn
                server_conn = _h3g_server_conn(server)
                _h3g_uni!(server_conn, type)
                _h3g_uni!(server_conn, type)
                err = take!(server.conn_errors)
                @test err isa H3GQ.ConnectionError && err.code == H3G._H3_STREAM_CREATION_ERROR
            end
        end
    end

    @testset "conn_test: control stream handling: errors when the server opens a push stream" begin
        server = _h3t_server((req, s, conn) -> nothing)
        _h3g_with(server) do conn
            _h3g_uni!(_h3g_server_conn(server), H3G._H3_STREAM_PUSH)
            err = take!(server.conn_errors)
            @test err isa H3GQ.ConnectionError && err.code == H3G._H3_ID_ERROR
        end
    end

    @testset "headers_test: Response" begin
        f(pairs...) = [H3G.HeaderField(String(n), String(v), false) for (n, v) in pairs]
        decode(fields) = H3G._decode_response_headers(fields)
        @testset "populates responses" begin
            status, headers = decode(f(":status" => "200", "content-length" => "42"))
            @test status == 200
            @test H3G.header(headers, "Content-Length") == "42"
        end
        @testset "rejects pseudo header fields after regular header fields" begin
            @test_throws H3G.ProtocolError decode(f("content-length" => "42", ":status" => "200"))
        end
        @testset "rejects response with no status field" begin
            @test_throws H3G.ProtocolError decode(f("content-length" => "42"))
        end
        @testset "rejects invalid status codes" begin
            for bad in ("foobar", "-1", "+200", "99999", "20", "2000", " 200")
                @test_throws H3G.ProtocolError decode(f(":status" => bad))
            end
        end
        @testset "rejects pseudo header fields defined for requests" begin
            @test_throws H3G.ProtocolError decode(f(":status" => "404", ":method" => "GET"))
        end
        @testset "rejecting invalid header fields: $(name)" for name in ("connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade")
            @test_throws H3G.ProtocolError decode(f(":status" => "404", name => "some-value"))
        end
        @testset "rejects the TE header field, unless it is set to trailers" begin
            @test decode(f(":status" => "404", "te" => "trailers"))[1] == 404
            @test_throws H3G.ProtocolError decode(f(":status" => "404", "te" => "not-trailers"))
        end
        @testset "parses trailers" begin
            # quic-go keeps a content-length trailer; HTTP.jl drops responses
            # whose trailers carry fields that must not be trailers, for every
            # protocol (RFC 9110 Section 6.5.1).
            @test_throws H3G.ProtocolError H3G._decode_h2_trailer_headers(f("content-length" => "42"))
            @test H3G.header(H3G._decode_h2_trailer_headers(f("x-checksum" => "42")), "X-Checksum") == "42"
            @test_throws H3G.ProtocolError H3G._decode_h2_trailer_headers(f(":status" => "200"))
        end
    end

    @testset "body_test: Response Body" begin
        @testset "closes the reqDone channel when Read errors; allows multiple calls to Read, when Read errors" begin
            # A reset may discard data not yet read (RFC 9000 Section 3.2),
            # so it is sent once the client has the response head.
            head_read = Channel{Nothing}(1)
            server = _h3t_server(; raw = true) do s, conn
                _h3t_read_request(s)
                out = _h3t_headers_frame(":status" => "200")
                append!(out, _h3t_data_frame("partial"))
                write(s, out)
                take!(head_read)
                H3GQ.reset_stream!(s, H3G._H3_INTERNAL_ERROR)
            end
            _h3g_with(server) do conn
                resp = H3G.h3_roundtrip!(conn, _h3g_request("GET", "/"))
                put!(head_read, nothing)
                _, err = _h3g_read_until_error(resp.body)
                @test err isa H3G.H3StreamResetError
                # The request is done, and the error keeps being reported.
                @test lock(() -> conn.active_streams, conn.lock) == 0
                @test _h3g_error(() -> H3G.body_read!(resp.body, zeros(UInt8, 1))) isa H3G.H3StreamResetError
            end
        end

        @testset "closes responses; allows multiple calls to Close" begin
            codes = Channel{Any}(1)
            server = _h3t_server(; raw = true) do s, conn
                _h3t_read_request(s)
                write(s, _h3t_headers_frame(":status" => "200"))
                put!(codes, _h3g_stop_code(s))
            end
            _h3g_with(server) do conn
                resp = H3G.h3_roundtrip!(conn, _h3g_request("GET", "/"))
                H3G.body_close!(resp.body)
                H3G.body_close!(resp.body)
                @test take!(codes) == H3G._H3_REQUEST_CANCELLED
                @test lock(() -> conn.active_streams, conn.lock) == 0
            end
        end

        for (label, content_length, frames, expected) in (
            ("reads all frames", 6, ["foobar"], "foobar"),
            ("errors if more data than the maximum length is sent, in the middle of a frame", 4, ["foo", "bar"], "foob"),
            ("errors if more data than the maximum length is sent, as an additional frame", 3, ["foo", "bar"], "foo"),
        )
            @testset "length limiting: $(label)" begin
                codes = Channel{Any}(1)
                server = _h3t_server(; raw = true) do s, conn
                    _h3t_read_request(s)
                    out = _h3t_headers_frame(":status" => "200", "content-length" => string(content_length))
                    foreach(fr -> append!(out, _h3t_data_frame(fr)), frames)
                    write(s, out)
                    if expected == join(frames)
                        closewrite(s)
                        put!(codes, nothing)
                    else
                        put!(codes, _h3g_stop_code(s))
                    end
                end
                _h3g_with(server) do conn
                    resp = H3G.h3_roundtrip!(conn, _h3g_request("GET", "/"))
                    got, err = _h3g_read_until_error(resp.body)
                    @test String(got) == expected
                    if expected == join(frames)
                        @test err === nothing
                        @test take!(codes) === nothing
                    else
                        @test err isa H3G.ProtocolError
                        # Later reads keep failing.
                        @test _h3g_error(() -> H3G.body_read!(resp.body, zeros(UInt8, 1))) isa H3G.ProtocolError
                        @test take!(codes) == H3G._H3_MESSAGE_ERROR
                    end
                end
            end
        end
    end
end

# transport_test.go: how the Client pools HTTP/3 connections.
_h3g_client() = H3G.Client(; transport = H3G.Transport(tls_config = Reseau.TLS.Config(verify_peer = false, server_name = "localhost")))

@testset "HTTP/3 client pool: cases ported from quic-go transport_test" begin
    @testset "immediately removes a clients when a request errored" begin
        server = _h3t_server((req, s, conn) -> _h3t_respond!(s, 200, Pair{String,String}[], "ok"))
        client = _h3g_client()
        url = "https://$(_h3t_address(server))/"
        try
            @test String(H3G.request("GET", url; client, protocol = :h3).body) == "ok"
            # The connection fails under the client; the next request dials again.
            close(_h3g_server_conn(server); code = H3G._H3_INTERNAL_ERROR)
            pooled = lock(() -> client.h3_conns[_h3t_address(server)], client.h3_lock)
            _h3g_wait(pooled, c -> c.error !== nothing)
            @test String(H3G.request("GET", url; client, protocol = :h3).body) == "ok"
            @test length(server.conns) == 2
        finally
            close(client)
            _h3t_close(server)
        end
    end

    @testset "does not remove a client when a request returns context canceled error" begin
        started = Channel{Nothing}(1)
        server = _h3t_server(; raw = true) do s, conn
            req = _h3t_read_request(s)
            if _h3t_header(req, ":path") == "/slow"
                put!(started, nothing)
                _h3g_stop_code(s)
            else
                _h3t_respond!(s, 200)
            end
        end
        client = _h3g_client()
        base = "https://$(_h3t_address(server))"
        try
            ctx = H3G.RequestContext()
            t = Threads.@spawn _h3g_error(() -> H3G.request("GET", base * "/slow"; client, protocol = :h3, context = ctx, retry = false))
            take!(started)
            H3G.cancel!(ctx)
            @test fetch(t) isa H3G.CanceledError
            @test H3G.request("GET", base * "/next"; client, protocol = :h3).status == 200
            @test length(server.conns) == 1
        finally
            close(client)
            _h3t_close(server)
        end
    end

    @testset "handles a burst of requests" begin
        server = _h3t_server((req, s, conn) -> _h3t_respond!(s, 200, Pair{String,String}[], "ok"))
        client = _h3g_client()
        url = "https://$(_h3t_address(server))/"
        try
            tasks = [Threads.@spawn(String(H3G.request("GET", url; client, protocol = :h3).body)) for _ in 1:20]
            @test all(t -> fetch(t) == "ok", tasks)
            @test length(server.conns) == 1
        finally
            close(client)
            _h3t_close(server)
        end
    end

    @testset "rejects requests with an invalid request method" begin
        server = _h3t_server((req, s, conn) -> _h3t_respond!(s, 200))
        client = _h3g_client()
        try
            @test_throws Exception H3G.request("foo bar", "https://$(_h3t_address(server))/"; client, protocol = :h3)
        finally
            close(client)
            _h3t_close(server)
        end
    end

    @testset "closes idle connections" begin
        server = _h3t_server((req, s, conn) -> _h3t_respond!(s, 200))
        client = _h3g_client()
        try
            @test H3G.request("GET", "https://$(_h3t_address(server))/"; client, protocol = :h3).status == 200
            H3G.close_idle_connections!(client)
            err = take!(server.conn_errors)
            @test err isa H3GQ.ConnectionError && err.app && err.code == H3G._H3_NO_ERROR && err.remote
            @test isempty(lock(() -> client.h3_conns, client.h3_lock))
        finally
            close(client)
            _h3t_close(server)
        end
    end
end
