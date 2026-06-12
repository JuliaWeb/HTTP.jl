using Test

using Base64
using HTTP
using Reseau

const HT = HTTP
const W = HT.WebSockets

@testset "HTTP websocket opcode helpers" begin
    @test UInt8(HT.WebSockets.WsOpcode.CONTINUATION) == 0x00
    @test UInt8(HT.WebSockets.WsOpcode.TEXT) == 0x01
    @test UInt8(HT.WebSockets.WsOpcode.BINARY) == 0x02
    @test UInt8(HT.WebSockets.WsOpcode.CLOSE) == 0x08
    @test UInt8(HT.WebSockets.WsOpcode.PING) == 0x09
    @test UInt8(HT.WebSockets.WsOpcode.PONG) == 0x0a
    @test HT.WebSockets.ws_is_data_frame(UInt8(0x01))
    @test HT.WebSockets.ws_is_data_frame(HT.WebSockets.WsOpcode.BINARY)
    @test !HT.WebSockets.ws_is_data_frame(UInt8(0x09))
    @test HT.WebSockets.ws_is_control_frame(UInt8(0x08))
    @test HT.WebSockets.ws_is_control_frame(HT.WebSockets.WsOpcode.PONG)
    @test !HT.WebSockets.ws_is_control_frame(UInt8(0x01))
end

@testset "HTTP websocket frame encoder" begin
    payload = Vector{UInt8}("Hello")
    frame = HT.WebSockets.WsFrame(opcode = UInt8(HT.WebSockets.WsOpcode.TEXT), payload = payload, fin = true)
    encoded = HT.WebSockets.ws_encode_frame(frame)
    @test length(encoded) == 7
    @test encoded[1] == 0x81
    @test encoded[2] == 0x05
    @test collect(encoded[3:end]) == payload

    masked = HT.WebSockets.WsFrame(
        opcode = UInt8(HT.WebSockets.WsOpcode.TEXT),
        payload = Vector{UInt8}("Hi"),
        fin = true,
        masked = true,
        masking_key = (0x37, 0xfa, 0x21, 0x3d),
    )
    masked_encoded = HT.WebSockets.ws_encode_frame(masked)
    @test (masked_encoded[2] & 0x80) != 0
    @test collect(masked_encoded[3:6]) == UInt8[0x37, 0xfa, 0x21, 0x3d]
    @test length(masked_encoded) == 8

    medium_payload = fill(UInt8('a'), 126)
    medium_encoded = HT.WebSockets.ws_encode_frame(HT.WebSockets.WsFrame(opcode = UInt8(HT.WebSockets.WsOpcode.BINARY), payload = medium_payload, fin = true))
    @test medium_encoded[2] == 126
    @test medium_encoded[3] == 0x00
    @test medium_encoded[4] == 0x7e
    @test length(medium_encoded) == 130

    large_payload = fill(UInt8('b'), 66_000)
    large_encoded = HT.WebSockets.ws_encode_frame(HT.WebSockets.WsFrame(opcode = UInt8(HT.WebSockets.WsOpcode.BINARY), payload = large_payload, fin = true))
    @test large_encoded[2] == 127
    @test length(large_encoded) == 66_010
    encoded_len = zero(UInt64)
    for byte in large_encoded[3:10]
        encoded_len = (encoded_len << 8) | UInt64(byte)
    end
    @test encoded_len == UInt64(length(large_payload))
end

@testset "HTTP websocket decoder" begin
    decoder = HT.WebSockets.ws_decoder_new()
    payload = Vector{UInt8}("Hello")
    frames = HT.WebSockets.ws_decoder_process!(decoder, UInt8[0x81, 0x05, payload...])
    @test length(frames) == 1
    @test frames[1].opcode == UInt8(HT.WebSockets.WsOpcode.TEXT)
    @test frames[1].payload == payload

    decoder = HT.WebSockets.ws_decoder_new()
    key = UInt8[0x37, 0xfa, 0x21, 0x3d]
    plain = Vector{UInt8}("Hi")
    masked = UInt8[plain[1] ⊻ key[1], plain[2] ⊻ key[2]]
    frames = HT.WebSockets.ws_decoder_process!(decoder, UInt8[0x81, 0x82, key..., masked...])
    @test length(frames) == 1
    @test frames[1].masked
    @test frames[1].payload == plain

    decoder = HT.WebSockets.ws_decoder_new()
    first_frames = HT.WebSockets.ws_decoder_process!(decoder, UInt8[0x01, 0x03, UInt8('H'), UInt8('e'), UInt8('l')])
    @test length(first_frames) == 1
    @test !first_frames[1].fin
    second_frames = HT.WebSockets.ws_decoder_process!(decoder, UInt8[0x80, 0x02, UInt8('l'), UInt8('o')])
    @test length(second_frames) == 1
    @test second_frames[1].opcode == UInt8(HT.WebSockets.WsOpcode.CONTINUATION)

    decoder = HT.WebSockets.ws_decoder_new()
    @test_throws HT.WebSockets.WebSocketProtocolError HT.WebSockets.ws_decoder_process!(decoder, UInt8[0x09, 0x00])

    decoder = HT.WebSockets.ws_decoder_new()
    @test_throws HT.WebSockets.WebSocketInvalidPayloadError HT.WebSockets.ws_decoder_process!(decoder, UInt8[0x81, 0x02, 0xc3, 0x28])

    decoder = HT.WebSockets.ws_decoder_new()
    @test_throws HT.WebSockets.WebSocketProtocolError HT.WebSockets.ws_decoder_process!(decoder, UInt8[0x88, 0x01, 0x00])

    decoder = HT.WebSockets.ws_decoder_new()
    @test_throws HT.WebSockets.WebSocketProtocolError HT.WebSockets.ws_decoder_process!(decoder, UInt8[0xc1, 0x01, UInt8('a')])

    decoder = HT.WebSockets.ws_decoder_new()
    @test_throws HT.WebSockets.WebSocketProtocolError HT.WebSockets.ws_decoder_process!(decoder, UInt8[0xa2, 0x01, UInt8(0x01)])

    decoder = HT.WebSockets.ws_decoder_new()
    @test_throws HT.WebSockets.WebSocketProtocolError HT.WebSockets.ws_decoder_process!(decoder, UInt8[0x98, 0x00])

    decoder = HT.WebSockets.ws_decoder_new()
    header_events = Tuple{UInt8, Bool, UInt64}[]
    medium_payload = fill(UInt8('m'), 126)
    medium_frames = HT.WebSockets.ws_decoder_process!(
        nothing,
        decoder,
        HT.WebSockets.ws_encode_frame(HT.WebSockets.WsFrame(opcode = UInt8(HT.WebSockets.WsOpcode.BINARY), payload = medium_payload, fin = true));
        on_frame_header = (opcode, fin, len) -> push!(header_events, (opcode, fin, len)),
    )
    @test length(medium_frames) == 1
    @test medium_frames[1].payload == medium_payload
    @test header_events == [(UInt8(HT.WebSockets.WsOpcode.BINARY), true, UInt64(126))]

    decoder = HT.WebSockets.ws_decoder_new()
    large_payload = fill(UInt8('z'), 66_000)
    large_frames = HT.WebSockets.ws_decoder_process!(decoder, HT.WebSockets.ws_encode_frame(HT.WebSockets.WsFrame(opcode = UInt8(HT.WebSockets.WsOpcode.BINARY), payload = large_payload, fin = true)))
    @test length(large_frames) == 1
    @test large_frames[1].payload == large_payload
end

@testset "HTTP websocket close payload helpers" begin
    @test HT.WebSockets.ws_is_valid_close_status(UInt16(1000))
    @test HT.WebSockets.ws_is_valid_close_status(UInt16(1001))
    @test !HT.WebSockets.ws_is_valid_close_status(UInt16(1005))
    @test !HT.WebSockets.ws_is_valid_close_status(UInt16(999))

    payload = HT.WebSockets.ws_encode_close_payload(UInt16(1000), Vector{UInt8}("bye"))
    code, reason = HT.WebSockets.ws_decode_close_payload(payload)
    @test code == UInt16(1000)
    @test reason == Vector{UInt8}("bye")
    @test HT.WebSockets.ws_validate_close_payload(payload) === nothing
    @test_throws HT.WebSockets.WebSocketProtocolError HT.WebSockets.ws_validate_close_payload(UInt8[0x03])
    @test_throws HT.WebSockets.WebSocketInvalidPayloadError HT.WebSockets.ws_validate_close_payload(UInt8[0x03, 0xe8, 0xc3, 0x28])
end

@testset "HTTP websocket connection state machine" begin
    ws = W.Conn(is_client = false)
    HT.WebSockets.ws_send_frame!(ws, UInt8(HT.WebSockets.WsOpcode.TEXT), Vector{UInt8}("A"))
    HT.WebSockets.ws_send_frame!(ws, UInt8(HT.WebSockets.WsOpcode.BINARY), UInt8[0x42])
    outgoing = HT.WebSockets.ws_get_outgoing_data!(ws)
    @test isempty(ws.outgoing)
    frames = HT.WebSockets.ws_decoder_process!(HT.WebSockets.ws_decoder_new(), outgoing)
    @test length(frames) == 2
    @test frames[1].opcode == UInt8(HT.WebSockets.WsOpcode.TEXT)
    @test frames[2].opcode == UInt8(HT.WebSockets.WsOpcode.BINARY)

    server_ws = W.Conn(is_client = false)
    ping_frame = HT.WebSockets.WsFrame(
        opcode = UInt8(HT.WebSockets.WsOpcode.PING),
        payload = Vector{UInt8}("ok"),
        fin = true,
        masked = true,
        masking_key = (0x01, 0x02, 0x03, 0x04),
    )
    incoming = HT.WebSockets.ws_encode_frame(ping_frame)
    frames = HT.WebSockets.ws_on_incoming_data!(server_ws, incoming)
    @test length(frames) == 1
    @test frames[1].opcode == UInt8(HT.WebSockets.WsOpcode.PING)
    pong_wire = HT.WebSockets.ws_get_outgoing_data!(server_ws)
    pong_frames = HT.WebSockets.ws_decoder_process!(HT.WebSockets.ws_decoder_new(), pong_wire)
    @test length(pong_frames) == 1
    @test pong_frames[1].opcode == UInt8(HT.WebSockets.WsOpcode.PONG)
    @test pong_frames[1].payload == Vector{UInt8}("ok")

    close_ws = W.Conn(is_client = false)
    close_frame = HT.WebSockets.WsFrame(
        opcode = UInt8(HT.WebSockets.WsOpcode.CLOSE),
        payload = HT.WebSockets.ws_encode_close_payload(UInt16(1000)),
        fin = true,
        masked = true,
        masking_key = (0x01, 0x02, 0x03, 0x04),
    )
    close_frames = HT.WebSockets.ws_on_incoming_data!(close_ws, HT.WebSockets.ws_encode_frame(close_frame))
    @test length(close_frames) == 1
    @test close_frames[1].opcode == UInt8(HT.WebSockets.WsOpcode.CLOSE)
    @test close_ws.close_received
    @test close_ws.close_sent
    @test !close_ws.is_open

    @test_throws HT.WebSockets.WebSocketProtocolError HT.WebSockets.ws_on_incoming_data!(W.Conn(is_client = false), HT.WebSockets.ws_encode_frame(HT.WebSockets.WsFrame(opcode = UInt8(HT.WebSockets.WsOpcode.TEXT), payload = UInt8[0x41], fin = true)))
    @test_throws HT.WebSockets.WebSocketProtocolError HT.WebSockets.ws_on_incoming_data!(W.Conn(is_client = true), HT.WebSockets.ws_encode_frame(HT.WebSockets.WsFrame(opcode = UInt8(HT.WebSockets.WsOpcode.TEXT), payload = UInt8[0x41], fin = true, masked = true, masking_key = (0x01, 0x02, 0x03, 0x04))))
end

@testset "HTTP websocket payload limits" begin
    ws = W.Conn(is_client = false, max_incoming_payload_length = UInt64(4))
    frame = HT.WebSockets.WsFrame(
        opcode = UInt8(HT.WebSockets.WsOpcode.TEXT),
        payload = Vector{UInt8}("hello"),
        fin = true,
        masked = true,
        masking_key = (0x01, 0x02, 0x03, 0x04),
    )
    @test_throws HT.WebSockets.WebSocketProtocolError HT.WebSockets.ws_on_incoming_data!(ws, HT.WebSockets.ws_encode_frame(frame))
end

@testset "HTTP websocket handshake helpers" begin
    key = HT.WebSockets.ws_random_handshake_key()
    @test length(key) == 24
    @test length(Base64.base64decode(key)) == 16
    @test key != HT.WebSockets.ws_random_handshake_key()

    @test HT.WebSockets.ws_compute_accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

    headers = HT.Headers()
    HT.setheader(headers, "Upgrade", "websocket")
    HT.setheader(headers, "Connection", "keep-alive, Upgrade")
    HT.setheader(headers, "Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
    HT.setheader(headers, "Sec-WebSocket-Version", "13")
    HT.setheader(headers, "Sec-WebSocket-Protocol", "chat, superchat")
    request = HT.Request("GET", "/ws"; headers = headers, host = "example.com", content_length = 0)
    @test HT.WebSockets.ws_is_websocket_request(request)
    @test HT.WebSockets.ws_get_request_sec_websocket_key(request) == "dGhlIHNhbXBsZSBub25jZQ=="
    @test HT.WebSockets.ws_select_subprotocol(request, ["superchat", "chat"]) == "superchat"
    @test HT.WebSockets.ws_select_subprotocol(request, ["mqtt"]) === nothing

    bad_headers = HT.Headers()
    HT.setheader(bad_headers, "Upgrade", "websocket")
    HT.setheader(bad_headers, "Connection", "x-upgrade-token")
    HT.setheader(bad_headers, "Sec-WebSocket-Key", "abc")
    HT.setheader(bad_headers, "Sec-WebSocket-Version", "13")
    bad_request = HT.Request("GET", "/ws"; headers = bad_headers, host = "example.com", content_length = 0)
    @test !HT.WebSockets.ws_is_websocket_request(bad_request)

    invalid_key_headers = copy(headers)
    HT.setheader(invalid_key_headers, "Sec-WebSocket-Key", "x")
    invalid_key_request = HT.Request("GET", "/ws"; headers = invalid_key_headers, host = "example.com", content_length = 0)
    @test !HT.WebSockets.ws_is_websocket_request(invalid_key_request)
    @test HT.WebSockets.ws_get_request_sec_websocket_key(invalid_key_request) === nothing

    malformed_key_headers = copy(headers)
    HT.setheader(malformed_key_headers, "Sec-WebSocket-Key", "%%%")
    malformed_key_request = HT.Request("GET", "/ws"; headers = malformed_key_headers, host = "example.com", content_length = 0)
    @test !HT.WebSockets.ws_is_websocket_request(malformed_key_request)
    @test HT.WebSockets.ws_get_request_sec_websocket_key(malformed_key_request) === nothing

    short_key_headers = copy(headers)
    HT.setheader(short_key_headers, "Sec-WebSocket-Key", "AQIDBA==")
    short_key_request = HT.Request("GET", "/ws"; headers = short_key_headers, host = "example.com", content_length = 0)
    @test !HT.WebSockets.ws_is_websocket_request(short_key_request)
    @test HT.WebSockets.ws_get_request_sec_websocket_key(short_key_request) === nothing
end

@testset "HTTP websocket decoder large-frame growth path and chunked masking" begin
    # > _WS_PAYLOAD_PREALLOC_CAP exercises the incremental-growth branch (the
    # claimed length must not be preallocated up front); odd-sized chunks
    # exercise the masking key phase across chunk boundaries.
    W = HT.WebSockets
    sz = W._WS_PAYLOAD_PREALLOC_CAP + 65_537
    payload = rand(UInt8, sz)
    frame = W.WsFrame(opcode = UInt8(W.WsOpcode.BINARY), payload = payload, fin = true,
                      masked = true, masking_key = (0x12, 0x34, 0x56, 0x78))
    wire = Vector{UInt8}(W.ws_encode_frame(frame))
    dec = W.ws_decoder_new()
    frames = nothing
    pos = 1
    while pos <= length(wire)
        n = min(13_331, length(wire) - pos + 1)   # odd chunk size: rotate key phase
        got = W.ws_decoder_process!(dec, view(wire, pos:pos+n-1))
        isempty(got) || (frames = collect(got))
        pos += n
    end
    @test frames !== nothing && length(frames) == 1
    @test frames[1].payload == payload

    # exact-size presize path stays correct for a small masked frame split
    # at every possible boundary
    small = rand(UInt8, 19)
    sframe = W.WsFrame(opcode = UInt8(W.WsOpcode.BINARY), payload = small, fin = true,
                       masked = true, masking_key = (0xaa, 0xbb, 0xcc, 0xdd))
    swire = Vector{UInt8}(W.ws_encode_frame(sframe))
    for split in 1:(length(swire) - 1)
        d = W.ws_decoder_new()
        f1 = W.ws_decoder_process!(d, view(swire, 1:split))
        f2 = W.ws_decoder_process!(d, view(swire, split+1:length(swire)))
        out = isempty(f2) ? f1 : f2
        @test length(out) == 1 && out[1].payload == small
    end
end

@testset "HTTP websocket max-length guard (header pre-check)" begin
    W = HT.WebSockets
    conn = W.WSConn(is_client = false, max_incoming_payload_length = UInt64(100))
    key = (0x01, 0x02, 0x03, 0x04)
    enc(op, p; fin = true) = Vector{UInt8}(W.ws_encode_frame(
        W.WsFrame(opcode = UInt8(op), payload = p, fin = fin, masked = true, masking_key = key)))

    # within limit across a fragmented message, reset after fin
    a = enc(W.WsOpcode.BINARY, rand(UInt8, 60); fin = false)
    b = enc(W.WsOpcode.CONTINUATION, rand(UInt8, 40); fin = true)
    frames = W.ws_on_incoming_data!(conn, vcat(a, b))
    @test length(frames) == 2
    c = enc(W.WsOpcode.BINARY, rand(UInt8, 100))   # full budget again post-reset
    @test length(W.ws_on_incoming_data!(conn, c)) == 1

    # fragmented total exceeding the limit is rejected at the header
    conn2 = W.WSConn(is_client = false, max_incoming_payload_length = UInt64(100))
    a2 = enc(W.WsOpcode.BINARY, rand(UInt8, 60); fin = false)
    b2 = enc(W.WsOpcode.CONTINUATION, rand(UInt8, 41); fin = true)
    @test_throws W.WebSocketProtocolError W.ws_on_incoming_data!(conn2, vcat(a2, b2))

    # control frame over the limit is rejected
    conn3 = W.WSConn(is_client = false, max_incoming_payload_length = UInt64(8))
    ping = enc(W.WsOpcode.PING, rand(UInt8, 9))
    @test_throws W.WebSocketProtocolError W.ws_on_incoming_data!(conn3, ping)
end

@testset "HTTP websocket outgoing buffer swap semantics" begin
    W = HT.WebSockets
    conn = W.WSConn(is_client = false)
    W.ws_send_frame!(conn, UInt8(W.WsOpcode.TEXT), Vector{UInt8}("one"))
    first_take = W.ws_get_outgoing_data!(conn)
    @test !isempty(first_take)
    @test isempty(W.ws_get_outgoing_data!(conn))   # nothing pending
    W.ws_send_frame!(conn, UInt8(W.WsOpcode.TEXT), Vector{UInt8}("two"))
    second_take = W.ws_get_outgoing_data!(conn)
    dec = W.ws_decoder_new()
    f2 = W.ws_decoder_process!(dec, second_take)
    @test length(f2) == 1 && String(copy(f2[1].payload)) == "two"
end
