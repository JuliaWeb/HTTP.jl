using Test

using HTTP
using Reseau

const HT = HTTP
const W = HT.WebSockets

@testset "HTTP websocket opcode helpers" begin
    @test UInt8(HT.WsOpcode.CONTINUATION) == 0x00
    @test UInt8(HT.WsOpcode.TEXT) == 0x01
    @test UInt8(HT.WsOpcode.BINARY) == 0x02
    @test UInt8(HT.WsOpcode.CLOSE) == 0x08
    @test UInt8(HT.WsOpcode.PING) == 0x09
    @test UInt8(HT.WsOpcode.PONG) == 0x0a
    @test HT.ws_is_data_frame(UInt8(0x01))
    @test HT.ws_is_data_frame(HT.WsOpcode.BINARY)
    @test !HT.ws_is_data_frame(UInt8(0x09))
    @test HT.ws_is_control_frame(UInt8(0x08))
    @test HT.ws_is_control_frame(HT.WsOpcode.PONG)
    @test !HT.ws_is_control_frame(UInt8(0x01))
end

@testset "HTTP websocket frame encoder" begin
    payload = Vector{UInt8}("Hello")
    frame = HT.WsFrame(opcode = UInt8(HT.WsOpcode.TEXT), payload = payload, fin = true)
    encoded = HT.ws_encode_frame(frame)
    @test length(encoded) == 7
    @test encoded[1] == 0x81
    @test encoded[2] == 0x05
    @test collect(encoded[3:end]) == payload

    masked = HT.WsFrame(
        opcode = UInt8(HT.WsOpcode.TEXT),
        payload = Vector{UInt8}("Hi"),
        fin = true,
        masked = true,
        masking_key = (0x37, 0xfa, 0x21, 0x3d),
    )
    masked_encoded = HT.ws_encode_frame(masked)
    @test (masked_encoded[2] & 0x80) != 0
    @test collect(masked_encoded[3:6]) == UInt8[0x37, 0xfa, 0x21, 0x3d]
    @test length(masked_encoded) == 8

    medium_payload = fill(UInt8('a'), 126)
    medium_encoded = HT.ws_encode_frame(HT.WsFrame(opcode = UInt8(HT.WsOpcode.BINARY), payload = medium_payload, fin = true))
    @test medium_encoded[2] == 126
    @test medium_encoded[3] == 0x00
    @test medium_encoded[4] == 0x7e
    @test length(medium_encoded) == 130

    large_payload = fill(UInt8('b'), 66_000)
    large_encoded = HT.ws_encode_frame(HT.WsFrame(opcode = UInt8(HT.WsOpcode.BINARY), payload = large_payload, fin = true))
    @test large_encoded[2] == 127
    @test length(large_encoded) == 66_010
    encoded_len = zero(UInt64)
    for byte in large_encoded[3:10]
        encoded_len = (encoded_len << 8) | UInt64(byte)
    end
    @test encoded_len == UInt64(length(large_payload))
end

@testset "HTTP websocket decoder" begin
    decoder = HT.ws_decoder_new()
    payload = Vector{UInt8}("Hello")
    frames = HT.ws_decoder_process!(decoder, UInt8[0x81, 0x05, payload...])
    @test length(frames) == 1
    @test frames[1].opcode == UInt8(HT.WsOpcode.TEXT)
    @test frames[1].payload == payload

    decoder = HT.ws_decoder_new()
    key = UInt8[0x37, 0xfa, 0x21, 0x3d]
    plain = Vector{UInt8}("Hi")
    masked = UInt8[plain[1] ⊻ key[1], plain[2] ⊻ key[2]]
    frames = HT.ws_decoder_process!(decoder, UInt8[0x81, 0x82, key..., masked...])
    @test length(frames) == 1
    @test frames[1].masked
    @test frames[1].payload == plain

    decoder = HT.ws_decoder_new()
    first_frames = HT.ws_decoder_process!(decoder, UInt8[0x01, 0x03, UInt8('H'), UInt8('e'), UInt8('l')])
    @test length(first_frames) == 1
    @test !first_frames[1].fin
    second_frames = HT.ws_decoder_process!(decoder, UInt8[0x80, 0x02, UInt8('l'), UInt8('o')])
    @test length(second_frames) == 1
    @test second_frames[1].opcode == UInt8(HT.WsOpcode.CONTINUATION)

    decoder = HT.ws_decoder_new()
    @test_throws HT.WebSocketProtocolError HT.ws_decoder_process!(decoder, UInt8[0x09, 0x00])

    decoder = HT.ws_decoder_new()
    @test_throws HT.WebSocketInvalidPayloadError HT.ws_decoder_process!(decoder, UInt8[0x81, 0x02, 0xc3, 0x28])

    decoder = HT.ws_decoder_new()
    @test_throws HT.WebSocketProtocolError HT.ws_decoder_process!(decoder, UInt8[0x88, 0x01, 0x00])

    decoder = HT.ws_decoder_new()
    @test_throws HT.WebSocketProtocolError HT.ws_decoder_process!(decoder, UInt8[0xc1, 0x01, UInt8('a')])

    decoder = HT.ws_decoder_new()
    @test_throws HT.WebSocketProtocolError HT.ws_decoder_process!(decoder, UInt8[0xa2, 0x01, UInt8(0x01)])

    decoder = HT.ws_decoder_new()
    @test_throws HT.WebSocketProtocolError HT.ws_decoder_process!(decoder, UInt8[0x98, 0x00])

    decoder = HT.ws_decoder_new()
    header_events = Tuple{UInt8, Bool, UInt64}[]
    medium_payload = fill(UInt8('m'), 126)
    medium_frames = HT.ws_decoder_process!(
        nothing,
        decoder,
        HT.ws_encode_frame(HT.WsFrame(opcode = UInt8(HT.WsOpcode.BINARY), payload = medium_payload, fin = true));
        on_frame_header = (opcode, fin, len) -> push!(header_events, (opcode, fin, len)),
    )
    @test length(medium_frames) == 1
    @test medium_frames[1].payload == medium_payload
    @test header_events == [(UInt8(HT.WsOpcode.BINARY), true, UInt64(126))]

    decoder = HT.ws_decoder_new()
    large_payload = fill(UInt8('z'), 66_000)
    large_frames = HT.ws_decoder_process!(decoder, HT.ws_encode_frame(HT.WsFrame(opcode = UInt8(HT.WsOpcode.BINARY), payload = large_payload, fin = true)))
    @test length(large_frames) == 1
    @test large_frames[1].payload == large_payload
end

@testset "HTTP websocket close payload helpers" begin
    @test HT.ws_is_valid_close_status(UInt16(1000))
    @test HT.ws_is_valid_close_status(UInt16(1001))
    @test !HT.ws_is_valid_close_status(UInt16(1005))
    @test !HT.ws_is_valid_close_status(UInt16(999))

    payload = HT.ws_encode_close_payload(UInt16(1000), Vector{UInt8}("bye"))
    code, reason = HT.ws_decode_close_payload(payload)
    @test code == UInt16(1000)
    @test reason == Vector{UInt8}("bye")
    @test HT.ws_validate_close_payload(payload) === nothing
    @test_throws HT.WebSocketProtocolError HT.ws_validate_close_payload(UInt8[0x03])
    @test_throws HT.WebSocketInvalidPayloadError HT.ws_validate_close_payload(UInt8[0x03, 0xe8, 0xc3, 0x28])
end

@testset "HTTP websocket connection state machine" begin
    ws = W.Conn(is_client = false)
    HT.ws_send_frame!(ws, UInt8(HT.WsOpcode.TEXT), Vector{UInt8}("A"))
    HT.ws_send_frame!(ws, UInt8(HT.WsOpcode.BINARY), UInt8[0x42])
    outgoing = HT.ws_get_outgoing_data!(ws)
    @test isempty(ws.outgoing_frames)
    frames = HT.ws_decoder_process!(HT.ws_decoder_new(), outgoing)
    @test length(frames) == 2
    @test frames[1].opcode == UInt8(HT.WsOpcode.TEXT)
    @test frames[2].opcode == UInt8(HT.WsOpcode.BINARY)

    server_ws = W.Conn(is_client = false)
    ping_frame = HT.WsFrame(
        opcode = UInt8(HT.WsOpcode.PING),
        payload = Vector{UInt8}("ok"),
        fin = true,
        masked = true,
        masking_key = (0x01, 0x02, 0x03, 0x04),
    )
    incoming = HT.ws_encode_frame(ping_frame)
    frames = HT.ws_on_incoming_data!(server_ws, incoming)
    @test length(frames) == 1
    @test frames[1].opcode == UInt8(HT.WsOpcode.PING)
    pong_wire = HT.ws_get_outgoing_data!(server_ws)
    pong_frames = HT.ws_decoder_process!(HT.ws_decoder_new(), pong_wire)
    @test length(pong_frames) == 1
    @test pong_frames[1].opcode == UInt8(HT.WsOpcode.PONG)
    @test pong_frames[1].payload == Vector{UInt8}("ok")

    close_ws = W.Conn(is_client = false)
    close_frame = HT.WsFrame(
        opcode = UInt8(HT.WsOpcode.CLOSE),
        payload = HT.ws_encode_close_payload(UInt16(1000)),
        fin = true,
        masked = true,
        masking_key = (0x01, 0x02, 0x03, 0x04),
    )
    close_frames = HT.ws_on_incoming_data!(close_ws, HT.ws_encode_frame(close_frame))
    @test length(close_frames) == 1
    @test close_frames[1].opcode == UInt8(HT.WsOpcode.CLOSE)
    @test close_ws.close_received
    @test close_ws.close_sent
    @test !close_ws.is_open

    @test_throws HT.WebSocketProtocolError HT.ws_on_incoming_data!(W.Conn(is_client = false), HT.ws_encode_frame(HT.WsFrame(opcode = UInt8(HT.WsOpcode.TEXT), payload = UInt8[0x41], fin = true)))
    @test_throws HT.WebSocketProtocolError HT.ws_on_incoming_data!(W.Conn(is_client = true), HT.ws_encode_frame(HT.WsFrame(opcode = UInt8(HT.WsOpcode.TEXT), payload = UInt8[0x41], fin = true, masked = true, masking_key = (0x01, 0x02, 0x03, 0x04))))
end

@testset "HTTP websocket payload limits" begin
    ws = W.Conn(is_client = false, max_incoming_payload_length = UInt64(4))
    frame = HT.WsFrame(
        opcode = UInt8(HT.WsOpcode.TEXT),
        payload = Vector{UInt8}("hello"),
        fin = true,
        masked = true,
        masking_key = (0x01, 0x02, 0x03, 0x04),
    )
    @test_throws HT.WebSocketProtocolError HT.ws_on_incoming_data!(ws, HT.ws_encode_frame(frame))
end

@testset "HTTP websocket handshake helpers" begin
    key = HT.ws_random_handshake_key()
    @test length(key) == 24
    @test length(HTTP.Base64.base64decode(key)) == 16
    @test key != HT.ws_random_handshake_key()

    @test HT.ws_compute_accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

    headers = HT.Headers()
    HT.setheader(headers, "Upgrade", "websocket")
    HT.setheader(headers, "Connection", "keep-alive, Upgrade")
    HT.setheader(headers, "Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
    HT.setheader(headers, "Sec-WebSocket-Version", "13")
    HT.setheader(headers, "Sec-WebSocket-Protocol", "chat, superchat")
    request = HT.Request("GET", "/ws"; headers = headers, host = "example.com", content_length = 0)
    @test HT.ws_is_websocket_request(request)
    @test HT.ws_get_request_sec_websocket_key(request) == "dGhlIHNhbXBsZSBub25jZQ=="
    @test HT.ws_select_subprotocol(request, ["superchat", "chat"]) == "superchat"
    @test HT.ws_select_subprotocol(request, ["mqtt"]) === nothing

    bad_headers = HT.Headers()
    HT.setheader(bad_headers, "Upgrade", "websocket")
    HT.setheader(bad_headers, "Connection", "x-upgrade-token")
    HT.setheader(bad_headers, "Sec-WebSocket-Key", "abc")
    HT.setheader(bad_headers, "Sec-WebSocket-Version", "13")
    bad_request = HT.Request("GET", "/ws"; headers = bad_headers, host = "example.com", content_length = 0)
    @test !HT.ws_is_websocket_request(bad_request)

    invalid_key_headers = copy(headers)
    HT.setheader(invalid_key_headers, "Sec-WebSocket-Key", "x")
    invalid_key_request = HT.Request("GET", "/ws"; headers = invalid_key_headers, host = "example.com", content_length = 0)
    @test !HT.ws_is_websocket_request(invalid_key_request)
    @test HT.ws_get_request_sec_websocket_key(invalid_key_request) === nothing

    malformed_key_headers = copy(headers)
    HT.setheader(malformed_key_headers, "Sec-WebSocket-Key", "%%%")
    malformed_key_request = HT.Request("GET", "/ws"; headers = malformed_key_headers, host = "example.com", content_length = 0)
    @test !HT.ws_is_websocket_request(malformed_key_request)
    @test HT.ws_get_request_sec_websocket_key(malformed_key_request) === nothing

    short_key_headers = copy(headers)
    HT.setheader(short_key_headers, "Sec-WebSocket-Key", "AQIDBA==")
    short_key_request = HT.Request("GET", "/ws"; headers = short_key_headers, host = "example.com", content_length = 0)
    @test !HT.ws_is_websocket_request(short_key_request)
    @test HT.ws_get_request_sec_websocket_key(short_key_request) === nothing
end
