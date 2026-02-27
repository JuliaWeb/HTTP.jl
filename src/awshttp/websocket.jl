# WebSocket - Encoder, decoder, handler, handshake
# Port of aws-c-http websocket*.h/c (RFC 6455)

using Random
import SHA

# ─── WebSocket opcodes ───

@enumx WsOpcode::UInt8 begin
    CONTINUATION = 0x0
    TEXT = 0x1
    BINARY = 0x2
    CLOSE = 0x8
    PING = 0x9
    PONG = 0xA
end

ws_is_data_frame(opcode::UInt8)::Bool = opcode <= 0x07
ws_is_data_frame(opcode::WsOpcode.T)::Bool = ws_is_data_frame(UInt8(opcode))
ws_is_control_frame(opcode::UInt8)::Bool = opcode >= 0x08
ws_is_control_frame(opcode::WsOpcode.T)::Bool = ws_is_control_frame(UInt8(opcode))

const WS_MAX_PAYLOAD_LENGTH = Int64(0x7FFFFFFFFFFFFFFF)
const WS_MAX_HANDSHAKE_KEY_LENGTH = 25
const WS_CLOSE_TIMEOUT_NS = 1_000_000_000  # 1 second
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# ─── WebSocket frame ───

mutable struct WsFrame
    fin::Bool
    rsv::NTuple{3, Bool}
    opcode::UInt8
    masked::Bool
    masking_key::NTuple{4, UInt8}
    payload_length::UInt64
    payload::Vector{UInt8}
end

function WsFrame(;
    opcode::UInt8=UInt8(WsOpcode.TEXT),
    payload::AbstractVector{UInt8}=UInt8[],
    fin::Bool=true,
    masked::Bool=false,
    masking_key::NTuple{4, UInt8}=(0x00, 0x00, 0x00, 0x00),
    rsv::NTuple{3, Bool}=(false, false, false),
)
    return WsFrame(fin, rsv, opcode, masked, masking_key, UInt64(length(payload)), Vector{UInt8}(payload))
end

# ─── WebSocket encoder ───

"""
    ws_encode_frame(frame::WsFrame) -> Memory{UInt8}

Encode a WebSocket frame into wire format.
"""
function ws_encode_frame(frame::WsFrame)::Memory{UInt8}
    # Calculate encoded size
    header_size = 2
    if frame.payload_length >= 65536
        header_size += 8
    elseif frame.payload_length >= 126
        header_size += 2
    end
    if frame.masked
        header_size += 4
    end
    total_size = header_size + Int(frame.payload_length)

    buf = Memory{UInt8}(undef, total_size)
    pos = 1

    # Byte 1: FIN + RSV + opcode
    b1 = frame.opcode & 0x0F
    if frame.fin
        b1 |= 0x80
    end
    if frame.rsv[1]; b1 |= 0x40; end
    if frame.rsv[2]; b1 |= 0x20; end
    if frame.rsv[3]; b1 |= 0x10; end
    buf[pos] = b1
    pos += 1

    # Byte 2: MASK + length
    b2 = UInt8(0)
    if frame.masked
        b2 |= 0x80
    end
    if frame.payload_length < 126
        b2 |= UInt8(frame.payload_length)
        buf[pos] = b2
        pos += 1
    elseif frame.payload_length <= 0xFFFF
        b2 |= 126
        buf[pos] = b2
        pos += 1
        buf[pos] = UInt8((frame.payload_length >> 8) & 0xFF)
        buf[pos+1] = UInt8(frame.payload_length & 0xFF)
        pos += 2
    else
        b2 |= 127
        buf[pos] = b2
        pos += 1
        for i in 7:-1:0
            buf[pos] = UInt8((frame.payload_length >> (8 * i)) & 0xFF)
            pos += 1
        end
    end

    # Masking key
    if frame.masked
        buf[pos] = frame.masking_key[1]
        buf[pos+1] = frame.masking_key[2]
        buf[pos+2] = frame.masking_key[3]
        buf[pos+3] = frame.masking_key[4]
        pos += 4
    end

    # Payload (with masking if needed)
    if !isempty(frame.payload)
        if frame.masked
            for i in 1:Int(frame.payload_length)
                buf[pos] = frame.payload[i] ⊻ frame.masking_key[((i - 1) % 4) + 1]
                pos += 1
            end
        else
            copyto!(buf, pos, frame.payload, 1, Int(frame.payload_length))
        end
    end

    return buf
end

"""
    ws_frame_encoded_size(frame::WsFrame) -> UInt64

Calculate the total encoded size of a WebSocket frame.
"""
function ws_frame_encoded_size(frame::WsFrame)::UInt64
    size = UInt64(2)
    if frame.payload_length >= 65536
        size += 8
    elseif frame.payload_length >= 126
        size += 2
    end
    if frame.masked
        size += 4
    end
    return size + frame.payload_length
end

# ─── WebSocket decoder ───

struct WsDecodedFrame
    fin::Bool
    rsv::NTuple{3, Bool}
    opcode::UInt8
    masked::Bool
    masking_key::NTuple{4, UInt8}
    payload_length::UInt64
    payload::Vector{UInt8}  # unmasked payload
end

@enumx WsDecoderState::UInt8 begin
    OPCODE_BYTE = 0
    LENGTH_BYTE = 1
    EXTENDED_LENGTH = 2
    MASKING_KEY = 3
    PAYLOAD = 4
    DONE = 5
end

mutable struct WsDecoder{FF, FP, UD}
    state::WsDecoderState.T
    state_bytes_processed::UInt64

    # Current frame being decoded
    fin::Bool
    rsv::NTuple{3, Bool}
    opcode::UInt8
    masked::Bool
    masking_key::NTuple{4, UInt8}
    payload_length::UInt64
    extended_length_size::Int  # 0, 2, or 8
    length_cache::Vector{UInt8}
    key_cache::Vector{UInt8}
    payload_buf::Vector{UInt8}

    # Fragmentation tracking
    expecting_continuation::Bool

    # Callbacks
    on_frame::FF        # (frame::WsDecodedFrame) -> Int
    on_payload::FP      # (data::Vector{UInt8}) -> Int
    user_data::UD
end

function ws_decoder_new(; on_frame=nothing, on_payload=nothing, user_data=nothing)::WsDecoder
    return WsDecoder(
        WsDecoderState.OPCODE_BYTE,
        UInt64(0),
        false, (false, false, false), UInt8(0), false,
        (0x00, 0x00, 0x00, 0x00),
        UInt64(0), 0,
        UInt8[], UInt8[], UInt8[],
        false,
        on_frame, on_payload, user_data,
    )
end

function _ws_decoder_reset!(dec::WsDecoder)::Nothing
    dec.state = WsDecoderState.OPCODE_BYTE
    dec.state_bytes_processed = UInt64(0)
    dec.fin = false
    dec.rsv = (false, false, false)
    dec.opcode = UInt8(0)
    dec.masked = false
    dec.masking_key = (0x00, 0x00, 0x00, 0x00)
    dec.payload_length = UInt64(0)
    dec.extended_length_size = 0
    empty!(dec.length_cache)
    empty!(dec.key_cache)
    empty!(dec.payload_buf)
    return nothing
end

"""
    ws_decoder_process!(decoder, data) -> (Int, Vector{WsDecodedFrame})

Feed data to the decoder. Returns (status, decoded_frames).
"""
function ws_decoder_process!(dec::WsDecoder, data::AbstractVector{UInt8})::Tuple{Int, Vector{WsDecodedFrame}}
    frames = WsDecodedFrame[]
    pos = 1

    while pos <= length(data)
        if dec.state == WsDecoderState.OPCODE_BYTE
            b = data[pos]
            pos += 1
            dec.fin = (b & 0x80) != 0
            dec.rsv = ((b & 0x40) != 0, (b & 0x20) != 0, (b & 0x10) != 0)
            dec.opcode = b & 0x0F

            # Validate opcode
            if dec.opcode ∉ (0x0, 0x1, 0x2, 0x8, 0x9, 0xA)
                return (raise_error(ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR), frames)
            end

            # Fragmentation validation
            is_control = ws_is_control_frame(dec.opcode)
            if is_control && !dec.fin
                return (raise_error(ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR), frames)
            end
            if !is_control
                if dec.opcode == UInt8(WsOpcode.CONTINUATION)
                    if !dec.expecting_continuation
                        return (raise_error(ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR), frames)
                    end
                else
                    if dec.expecting_continuation
                        return (raise_error(ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR), frames)
                    end
                end
                dec.expecting_continuation = !dec.fin
            end

            dec.state = WsDecoderState.LENGTH_BYTE

        elseif dec.state == WsDecoderState.LENGTH_BYTE
            b = data[pos]
            pos += 1
            dec.masked = (b & 0x80) != 0
            len7 = b & 0x7F

            if ws_is_control_frame(dec.opcode) && len7 >= 126
                return (raise_error(ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR), frames)
            end

            if len7 < 126
                dec.payload_length = UInt64(len7)
                dec.extended_length_size = 0
                dec.state = dec.masked ? WsDecoderState.MASKING_KEY : WsDecoderState.PAYLOAD
                dec.state_bytes_processed = UInt64(0)
                if dec.payload_length == 0 && !dec.masked
                    dec.state = WsDecoderState.DONE
                end
            elseif len7 == 126
                dec.extended_length_size = 2
                empty!(dec.length_cache)
                dec.state = WsDecoderState.EXTENDED_LENGTH
                dec.state_bytes_processed = UInt64(0)
            else  # 127
                dec.extended_length_size = 8
                empty!(dec.length_cache)
                dec.state = WsDecoderState.EXTENDED_LENGTH
                dec.state_bytes_processed = UInt64(0)
            end

        elseif dec.state == WsDecoderState.EXTENDED_LENGTH
            needed = dec.extended_length_size - length(dec.length_cache)
            available = min(needed, length(data) - pos + 1)
            append!(dec.length_cache, @view data[pos:pos+available-1])
            pos += available

            if length(dec.length_cache) == dec.extended_length_size
                if dec.extended_length_size == 2
                    dec.payload_length = UInt64(dec.length_cache[1]) << 8 |
                                         UInt64(dec.length_cache[2])
                else
                    v = UInt64(0)
                    for i in 1:8
                        v = (v << 8) | UInt64(dec.length_cache[i])
                    end
                    dec.payload_length = v
                end
                dec.state = dec.masked ? WsDecoderState.MASKING_KEY : WsDecoderState.PAYLOAD
                dec.state_bytes_processed = UInt64(0)
                if dec.payload_length == 0 && !dec.masked
                    dec.state = WsDecoderState.DONE
                end
            end

        elseif dec.state == WsDecoderState.MASKING_KEY
            needed = 4 - length(dec.key_cache)
            available = min(needed, length(data) - pos + 1)
            append!(dec.key_cache, @view data[pos:pos+available-1])
            pos += available

            if length(dec.key_cache) == 4
                dec.masking_key = (dec.key_cache[1], dec.key_cache[2], dec.key_cache[3], dec.key_cache[4])
                dec.state = dec.payload_length > 0 ? WsDecoderState.PAYLOAD : WsDecoderState.DONE
                dec.state_bytes_processed = UInt64(0)
            end

        elseif dec.state == WsDecoderState.PAYLOAD
            remaining = Int(dec.payload_length) - length(dec.payload_buf)
            available = min(remaining, length(data) - pos + 1)
            chunk = @view data[pos:pos+available-1]
            pos += available

            # Unmask if needed
            if dec.masked
                offset = length(dec.payload_buf)
                for i in 1:available
                    push!(dec.payload_buf, chunk[i] ⊻ dec.masking_key[((offset + i - 1) % 4) + 1])
                end
            else
                append!(dec.payload_buf, chunk)
            end

            if length(dec.payload_buf) == Int(dec.payload_length)
                dec.state = WsDecoderState.DONE
            end
        end

        if dec.state == WsDecoderState.DONE
            frame = WsDecodedFrame(
                dec.fin, dec.rsv, dec.opcode, dec.masked,
                dec.masking_key, dec.payload_length,
                copy(dec.payload_buf),
            )
            push!(frames, frame)

            # Invoke callback
            if dec.on_frame !== nothing
                dec.on_frame(frame)
            end

            _ws_decoder_reset!(dec)
        end
    end

    return (OP_SUCCESS, frames)
end

# ─── WebSocket close status codes ───

const WS_CLOSE_STATUS_NORMAL = UInt16(1000)
const WS_CLOSE_STATUS_GOING_AWAY = UInt16(1001)
const WS_CLOSE_STATUS_PROTOCOL_ERROR = UInt16(1002)
const WS_CLOSE_STATUS_UNSUPPORTED_DATA = UInt16(1003)
const WS_CLOSE_STATUS_NO_STATUS = UInt16(1005)
const WS_CLOSE_STATUS_ABNORMAL = UInt16(1006)
const WS_CLOSE_STATUS_INVALID_PAYLOAD = UInt16(1007)
const WS_CLOSE_STATUS_POLICY_VIOLATION = UInt16(1008)
const WS_CLOSE_STATUS_MESSAGE_TOO_BIG = UInt16(1009)
const WS_CLOSE_STATUS_EXTENSIONS_NEEDED = UInt16(1010)
const WS_CLOSE_STATUS_INTERNAL_ERROR = UInt16(1011)

function ws_is_valid_close_status(code::UInt16)::Bool
    code < 1000 && return false
    code in (1004, 1005, 1006) && return false
    code >= 1000 && code <= 1011 && return true
    code >= 3000 && code <= 4999 && return true
    return false
end

# ─── CLOSE frame payload helpers ───

function ws_encode_close_payload(status_code::UInt16, reason::AbstractVector{UInt8}=UInt8[])::Memory{UInt8}
    buf = Memory{UInt8}(undef, 2 + length(reason))
    buf[1] = UInt8((status_code >> 8) & 0xFF)
    buf[2] = UInt8(status_code & 0xFF)
    if !isempty(reason)
        copyto!(buf, 3, reason, 1, length(reason))
    end
    return buf
end

function ws_decode_close_payload(payload::AbstractVector{UInt8})::Tuple{UInt16, Vector{UInt8}}
    if length(payload) < 2
        return (UInt16(0), UInt8[])
    end
    code = UInt16(payload[1]) << 8 | UInt16(payload[2])
    reason = length(payload) > 2 ? payload[3:end] : UInt8[]
    return (code, reason)
end

# ─── WebSocket handler ───

mutable struct WebSocket{UD, Dec <: WsDecoder, FBegin, FPayload, FComplete, FShutdown}
    is_client::Bool
    is_open::Bool
    close_sent::Bool
    close_received::Bool
    user_data::UD

    # Frame encoder/decoder
    decoder::Dec

    # Outgoing frame queue
    outgoing_frames::Vector{Memory{UInt8}}

    # Read window
    read_window::UInt64
    manual_window_management::Bool

    # Auto-PING
    ping_interval_ms::UInt64
    last_ping_time_ns::UInt64

    # Max payload
    max_incoming_payload_length::UInt64
    incoming_message_payload_total::UInt64

    # Callbacks
    on_incoming_frame_begin::FBegin     # (ws, frame_info) -> Bool
    on_incoming_frame_payload::FPayload # (ws, frame_info, data) -> Bool
    on_incoming_frame_complete::FComplete # (ws, frame_info, error_code) -> Bool
    on_connection_shutdown::FShutdown    # (ws, error_code) -> Nothing
end

function ws_new(;
    is_client::Bool=true,
    user_data=nothing,
    manual_window_management::Bool=false,
    initial_window_size::UInt64=typemax(UInt64),
    max_incoming_payload_length::UInt64=UInt64(0),
    ping_interval_ms::UInt64=UInt64(0),
    on_incoming_frame_begin=nothing,
    on_incoming_frame_payload=nothing,
    on_incoming_frame_complete=nothing,
    on_connection_shutdown=nothing,
)::WebSocket

    decoder = ws_decoder_new()

    return WebSocket(
        is_client,
        true, false, false,
        user_data,
        decoder,
        Memory{UInt8}[],
        initial_window_size,
        manual_window_management,
        ping_interval_ms, UInt64(0),
        max_incoming_payload_length,
        UInt64(0),
        on_incoming_frame_begin,
        on_incoming_frame_payload,
        on_incoming_frame_complete,
        on_connection_shutdown,
    )
end

# ─── Send operations ───

"""
    ws_send_frame!(ws, opcode, payload; fin=true, on_complete=nothing, user_data=nothing) -> Int

Send a WebSocket frame.
"""
function ws_send_frame!(ws::WebSocket, opcode::UInt8, payload::AbstractVector{UInt8};
    fin::Bool=true, on_complete=nothing, user_data=nothing)::Int

    if !ws.is_open
        return raise_error(ERROR_HTTP_CONNECTION_CLOSED)
    end

    # Control frames must not be fragmented and must be <= 125 bytes
    if ws_is_control_frame(opcode)
        if !fin
            return raise_error(ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR)
        end
        if length(payload) > 125
            return raise_error(ERROR_INVALID_ARGUMENT)
        end
    end

    masking_key = if ws.is_client
        k = rand(UInt8, 4)
        (k[1], k[2], k[3], k[4])
    else
        (0x00, 0x00, 0x00, 0x00)
    end

    frame = WsFrame(
        opcode=opcode,
        payload=payload,
        fin=fin,
        masked=ws.is_client,
        masking_key=masking_key,
    )

    encoded = ws_encode_frame(frame)
    push!(ws.outgoing_frames, encoded)

    if on_complete !== nothing
        on_complete(ws, OP_SUCCESS, user_data)
    end

    return OP_SUCCESS
end

ws_send_text!(ws::WebSocket, payload::AbstractVector{UInt8}; kwargs...) =
    ws_send_frame!(ws, UInt8(WsOpcode.TEXT), payload; kwargs...)

ws_send_binary!(ws::WebSocket, payload::AbstractVector{UInt8}; kwargs...) =
    ws_send_frame!(ws, UInt8(WsOpcode.BINARY), payload; kwargs...)

ws_send_ping!(ws::WebSocket, payload::AbstractVector{UInt8}=UInt8[]; kwargs...) =
    ws_send_frame!(ws, UInt8(WsOpcode.PING), payload; kwargs...)

ws_send_pong!(ws::WebSocket, payload::AbstractVector{UInt8}=UInt8[]; kwargs...) =
    ws_send_frame!(ws, UInt8(WsOpcode.PONG), payload; kwargs...)

"""
    ws_close!(ws; status_code=WS_CLOSE_STATUS_NORMAL, reason=UInt8[]) -> Int

Send a CLOSE frame.
"""
function ws_close!(ws::WebSocket;
    status_code::UInt16=WS_CLOSE_STATUS_NORMAL,
    reason::AbstractVector{UInt8}=UInt8[])::Int

    if ws.close_sent
        return OP_SUCCESS  # already sent
    end

    payload = ws_encode_close_payload(status_code, reason)
    status = ws_send_frame!(ws, UInt8(WsOpcode.CLOSE), payload)
    if status == OP_SUCCESS
        ws.close_sent = true
    end
    return status
end

"""
    ws_increment_read_window!(ws, size) -> Nothing

Increment the read window for manual backpressure.
"""
function ws_increment_read_window!(ws::WebSocket, size::UInt64)::Nothing
    ws.read_window += size
    return nothing
end

# ─── Incoming frame processing ───

"""
    ws_on_incoming_data!(ws, data) -> (Int, Vector{WsDecodedFrame})

Process incoming WebSocket data. Invokes callbacks for each decoded frame.
Auto-responds to PING with PONG. Handles CLOSE handshake.
"""
function ws_on_incoming_data!(ws::WebSocket, data::AbstractVector{UInt8})::Tuple{Int, Vector{WsDecodedFrame}}
    status, frames = ws_decoder_process!(ws.decoder, data)
    if status != OP_SUCCESS
        return (status, frames)
    end

    for frame in frames
        if ws.is_client
            if frame.masked
                return (raise_error(ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR), frames)
            end
        else
            if !frame.masked
                return (raise_error(ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR), frames)
            end
        end
        # Max payload check
        if ws.max_incoming_payload_length > 0
            if ws_is_data_frame(frame.opcode)
                running_total = frame.opcode == UInt8(WsOpcode.CONTINUATION) ?
                    ws.incoming_message_payload_total : UInt64(0)
                if running_total > ws.max_incoming_payload_length ||
                        frame.payload_length > (ws.max_incoming_payload_length - running_total)
                    return (raise_error(ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR), frames)
                end
                ws.incoming_message_payload_total = running_total + frame.payload_length
            else
                if frame.payload_length > ws.max_incoming_payload_length
                    return (raise_error(ERROR_HTTP_WEBSOCKET_PROTOCOL_ERROR), frames)
                end
            end
        end

        frame_info = (
            payload_length=frame.payload_length,
            opcode=frame.opcode,
            fin=frame.fin,
        )

        # Invoke begin callback
        if ws.on_incoming_frame_begin !== nothing
            cont = ws.on_incoming_frame_begin(ws, frame_info, ws.user_data)
            if cont === false
                return (raise_error(ERROR_HTTP_CALLBACK_FAILURE), frames)
            end
        end

        # Invoke payload callback
        if ws.on_incoming_frame_payload !== nothing && !isempty(frame.payload)
            cont = ws.on_incoming_frame_payload(ws, frame_info, frame.payload, ws.user_data)
            if cont === false
                return (raise_error(ERROR_HTTP_CALLBACK_FAILURE), frames)
            end
        end

        # Invoke complete callback
        if ws.on_incoming_frame_complete !== nothing
            cont = ws.on_incoming_frame_complete(ws, frame_info, 0, ws.user_data)
            if cont === false
                return (raise_error(ERROR_HTTP_CALLBACK_FAILURE), frames)
            end
        end

        # Auto-PONG
        if frame.opcode == UInt8(WsOpcode.PING)
            ws_send_pong!(ws, frame.payload)
        end

        # CLOSE handshake
        if frame.opcode == UInt8(WsOpcode.CLOSE)
            ws.close_received = true
            if !ws.close_sent
                # Echo the close back
                ws_send_frame!(ws, UInt8(WsOpcode.CLOSE), frame.payload)
                ws.close_sent = true
            end
            ws.is_open = false
        end

        if ws_is_data_frame(frame.opcode) && frame.fin
            ws.incoming_message_payload_total = 0
        end
    end

    return (OP_SUCCESS, frames)
end

# ─── Outgoing frame collection ───

"""
    ws_get_outgoing_data!(ws) -> Vector{UInt8}

Collect all queued outgoing frames into a single buffer.
"""
function ws_get_outgoing_data!(ws::WebSocket)::Vector{UInt8}
    output = UInt8[]
    for frame in ws.outgoing_frames
        append!(output, frame)
    end
    empty!(ws.outgoing_frames)
    return output
end

# ─── Handshake helpers ───

"""
    ws_random_handshake_key() -> String

Generate a random Sec-WebSocket-Key value (base64-encoded 16 random bytes).
"""
function ws_random_handshake_key()::String
    key_bytes = rand(UInt8, 16)
    return Base64.base64encode(key_bytes)
end

"""
    ws_compute_accept_key(key::AbstractString) -> String

Compute the Sec-WebSocket-Accept value from a Sec-WebSocket-Key.
"""
function ws_compute_accept_key(key::AbstractString)::String
    combined = string(key, WS_GUID)
    hash = SHA.sha1(Vector{UInt8}(combined))
    return Base64.base64encode(hash)
end

"""
    ws_new_handshake_request(path, host) -> HttpMessage

Create a WebSocket client handshake request (HTTP/1.1 Upgrade).
"""
function ws_new_handshake_request(path::AbstractString, host::AbstractString)::HttpMessage
    msg = http_message_new_request()
    http_message_set_request_method(msg, "GET")
    http_message_set_request_path(msg, String(path))

    key = ws_random_handshake_key()
    hdrs = http_message_get_headers(msg)
    http_headers_add(hdrs, "Host", String(host))
    http_headers_add(hdrs, "Upgrade", "websocket")
    http_headers_add(hdrs, "Connection", "Upgrade")
    http_headers_add(hdrs, "Sec-WebSocket-Key", key)
    http_headers_add(hdrs, "Sec-WebSocket-Version", "13")

    return msg
end

"""
    ws_new_handshake_response(sec_websocket_key) -> HttpMessage

Create a WebSocket server handshake response (101 Switching Protocols).
"""
function ws_new_handshake_response(sec_websocket_key::AbstractString)::HttpMessage
    msg = http_message_new_response()
    http_message_set_response_status(msg, 101)

    accept = ws_compute_accept_key(sec_websocket_key)
    hdrs = http_message_get_headers(msg)
    http_headers_add(hdrs, "Upgrade", "websocket")
    http_headers_add(hdrs, "Connection", "Upgrade")
    http_headers_add(hdrs, "Sec-WebSocket-Accept", accept)

    return msg
end

"""
    ws_is_websocket_request(request::HttpMessage) -> Bool

Validate that an HTTP request is a valid WebSocket upgrade request.
"""
function ws_is_websocket_request(request::HttpMessage)::Bool
    if !http_message_is_request(request)
        return false
    end
    method = http_message_get_request_method(request)
    method === nothing && return false
    uppercase(method) != "GET" && return false

    hdrs = http_message_get_headers(request)

    upgrade_val = http_headers_get(hdrs, "Upgrade")
    upgrade_val === nothing && return false
    lowercase(upgrade_val) != "websocket" && return false

    conn_val = http_headers_get(hdrs, "Connection")
    conn_val === nothing && return false
    !occursin("upgrade", lowercase(conn_val)) && return false

    key_val = http_headers_get(hdrs, "Sec-WebSocket-Key")
    key_val === nothing && return false

    version_val = http_headers_get(hdrs, "Sec-WebSocket-Version")
    version_val === nothing && return false
    version_val != "13" && return false

    return true
end

"""
    ws_get_request_sec_websocket_key(request::HttpMessage) -> Union{String, Nothing}

Extract the Sec-WebSocket-Key header from a request.
"""
function ws_get_request_sec_websocket_key(request::HttpMessage)::Union{String, Nothing}
    return http_headers_get(http_message_get_headers(request), "Sec-WebSocket-Key")
end

"""
    ws_select_subprotocol(request, server_protocols) -> Union{String, Nothing}

Select a subprotocol from the client's requested list that the server supports.
"""
function ws_select_subprotocol(request::HttpMessage, server_protocols::AbstractVector{String})::Union{String, Nothing}
    hdrs = http_message_get_headers(request)
    client_val = http_headers_get(hdrs, "Sec-WebSocket-Protocol")
    client_val === nothing && return nothing

    for part in eachsplit(client_val, ',')
        trimmed = strip(part)
        for sp in server_protocols
            if lowercase(trimmed) == lowercase(sp)
                return sp
            end
        end
    end
    return nothing
end
