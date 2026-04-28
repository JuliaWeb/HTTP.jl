using Base64
using EnumX
using Random
using Reseau: ByteMemory, bytememory
using SHA

@enumx WsOpcode::UInt8 begin
    CONTINUATION = 0x00
    TEXT = 0x01
    BINARY = 0x02
    CLOSE = 0x08
    PING = 0x09
    PONG = 0x0a
end

ws_is_data_frame(opcode::UInt8)::Bool = return opcode <= 0x07
ws_is_data_frame(opcode::WsOpcode.T)::Bool = return ws_is_data_frame(UInt8(opcode))
ws_is_control_frame(opcode::UInt8)::Bool = return opcode >= 0x08
ws_is_control_frame(opcode::WsOpcode.T)::Bool = return ws_is_control_frame(UInt8(opcode))

const WS_MAX_PAYLOAD_LENGTH = UInt64(0x7fffffffffffffff)
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

struct WebSocketProtocolError <: HTTPError
    message::String
end

struct WebSocketInvalidPayloadError <: HTTPError
    message::String
end

function Base.showerror(io::IO, err::WebSocketProtocolError)
    print(io, err.message)
    return nothing
end

function Base.showerror(io::IO, err::WebSocketInvalidPayloadError)
    print(io, err.message)
    return nothing
end

struct WsFrame{P<:AbstractVector{UInt8}}
    fin::Bool
    rsv::NTuple{3,Bool}
    opcode::UInt8
    masked::Bool
    masking_key::NTuple{4,UInt8}
    payload_length::UInt64
    payload::P
end

function WsFrame(;
    opcode::UInt8=UInt8(WsOpcode.TEXT),
    payload::P=UInt8[],
    fin::Bool=true,
    masked::Bool=false,
    masking_key::NTuple{4,UInt8}=(0x00, 0x00, 0x00, 0x00),
    rsv::NTuple{3,Bool}=(false, false, false),
) where {P<:AbstractVector{UInt8}}
    return WsFrame{P}(fin, rsv, opcode, masked, masking_key, UInt64(length(payload)), payload)
end

function ws_encode_frame(frame::WsFrame)::ByteMemory
    header_size = 2
    if frame.payload_length >= 65536
        header_size += 8
    elseif frame.payload_length >= 126
        header_size += 2
    end
    frame.masked && (header_size += 4)
    total_size = header_size + Int(frame.payload_length)
    buf = bytememory(total_size)
    pos = 1
    b1 = frame.opcode & 0x0f
    frame.fin && (b1 |= 0x80)
    frame.rsv[1] && (b1 |= 0x40)
    frame.rsv[2] && (b1 |= 0x20)
    frame.rsv[3] && (b1 |= 0x10)
    buf[pos] = b1
    pos += 1
    b2 = UInt8(0)
    frame.masked && (b2 |= 0x80)
    if frame.payload_length < 126
        b2 |= UInt8(frame.payload_length)
        buf[pos] = b2
        pos += 1
    elseif frame.payload_length <= 0xffff
        b2 |= 126
        buf[pos] = b2
        pos += 1
        buf[pos] = UInt8((frame.payload_length >> 8) & 0xff)
        buf[pos+1] = UInt8(frame.payload_length & 0xff)
        pos += 2
    else
        b2 |= 127
        buf[pos] = b2
        pos += 1
        for i in 7:-1:0
            buf[pos] = UInt8((frame.payload_length >> (8 * i)) & 0xff)
            pos += 1
        end
    end
    if frame.masked
        buf[pos] = frame.masking_key[1]
        buf[pos+1] = frame.masking_key[2]
        buf[pos+2] = frame.masking_key[3]
        buf[pos+3] = frame.masking_key[4]
        pos += 4
    end
    if !isempty(frame.payload)
        if frame.masked
            for i in 1:Int(frame.payload_length)
                buf[pos] = frame.payload[i] ⊻ frame.masking_key[((i-1)%4)+1]
                pos += 1
            end
        else
            copyto!(buf, pos, frame.payload, 1, Int(frame.payload_length))
        end
    end
    return buf
end

@enumx WsDecoderState::UInt8 begin
    OPCODE_BYTE = 0
    LENGTH_BYTE = 1
    EXTENDED_LENGTH = 2
    MASKING_KEY = 3
    PAYLOAD = 4
    DONE = 5
end

mutable struct WsDecoder
    state::WsDecoderState.T
    fin::Bool
    rsv::NTuple{3,Bool}
    opcode::UInt8
    masked::Bool
    masking_key::NTuple{4,UInt8}
    payload_length::UInt64
    extended_length_size::Int
    length_cache::Vector{UInt8}
    key_cache::Vector{UInt8}
    payload_buf::Vector{UInt8}
    expecting_continuation::Bool
    fragment_opcode::UInt8
    text_fragment_payload::Vector{UInt8}
end

function ws_decoder_new()::WsDecoder
    return WsDecoder(
        WsDecoderState.OPCODE_BYTE,
        false,
        (false, false, false),
        UInt8(0),
        false,
        (0x00, 0x00, 0x00, 0x00),
        UInt64(0),
        0,
        UInt8[],
        UInt8[],
        UInt8[],
        false,
        UInt8(0),
        UInt8[],
    )
end

function _ws_decoder_reset!(dec::WsDecoder)::Nothing
    dec.state = WsDecoderState.OPCODE_BYTE
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

@inline function _ws_throw_protocol_error(message::AbstractString)
    throw(WebSocketProtocolError(String(message)))
end

@inline function _ws_throw_invalid_payload(message::AbstractString)
    throw(WebSocketInvalidPayloadError(String(message)))
end

function ws_decoder_process!(f::Union{Nothing,Function}, dec::WsDecoder, data::AbstractVector{UInt8}; on_frame_header=nothing)::Vector{WsFrame{Vector{UInt8}}}
    frames = WsFrame{Vector{UInt8}}[]
    pos = firstindex(data)
    while pos <= lastindex(data)
        if dec.state == WsDecoderState.OPCODE_BYTE
            b = data[pos]
            pos += 1
            dec.fin = (b & 0x80) != 0
            dec.rsv = ((b & 0x40) != 0, (b & 0x20) != 0, (b & 0x10) != 0)
            (dec.rsv[1] || dec.rsv[2] || dec.rsv[3]) && _ws_throw_protocol_error("unexpected websocket RSV bits without negotiated extensions")
            dec.opcode = b & 0x0f
            dec.opcode in (0x00, 0x01, 0x02, 0x08, 0x09, 0x0a) || _ws_throw_protocol_error("invalid websocket opcode")
            is_control = ws_is_control_frame(dec.opcode)
            is_control && !dec.fin && _ws_throw_protocol_error("control frames must not be fragmented")
            if !is_control
                if dec.opcode == UInt8(WsOpcode.CONTINUATION)
                    (!dec.expecting_continuation || dec.fragment_opcode == UInt8(0)) && _ws_throw_protocol_error("unexpected continuation frame")
                else
                    dec.expecting_continuation && _ws_throw_protocol_error("unexpected new data frame while fragmented message is open")
                    empty!(dec.text_fragment_payload)
                    dec.fragment_opcode = dec.fin ? UInt8(0) : dec.opcode
                end
                dec.expecting_continuation = !dec.fin
            end
            dec.state = WsDecoderState.LENGTH_BYTE
        elseif dec.state == WsDecoderState.LENGTH_BYTE
            b = data[pos]
            pos += 1
            dec.masked = (b & 0x80) != 0
            len7 = b & 0x7f
            ws_is_control_frame(dec.opcode) && len7 >= 126 && _ws_throw_protocol_error("control frame payload length must be <= 125")
            if len7 < 126
                dec.payload_length = UInt64(len7)
                dec.extended_length_size = 0
                on_frame_header === nothing || on_frame_header(dec.opcode, dec.fin, dec.payload_length)
                dec.state = dec.masked ? WsDecoderState.MASKING_KEY : WsDecoderState.PAYLOAD
                dec.payload_length == 0 && !dec.masked && (dec.state = WsDecoderState.DONE)
            elseif len7 == 126
                dec.extended_length_size = 2
                empty!(dec.length_cache)
                dec.state = WsDecoderState.EXTENDED_LENGTH
            else
                dec.extended_length_size = 8
                empty!(dec.length_cache)
                dec.state = WsDecoderState.EXTENDED_LENGTH
            end
        elseif dec.state == WsDecoderState.EXTENDED_LENGTH
            needed = dec.extended_length_size - length(dec.length_cache)
            available = min(needed, lastindex(data) - pos + 1)
            append!(dec.length_cache, @view data[pos:(pos+available-1)])
            pos += available
            if length(dec.length_cache) == dec.extended_length_size
                if dec.extended_length_size == 2
                    v = (UInt64(dec.length_cache[1]) << 8) | UInt64(dec.length_cache[2])
                    v < 126 && _ws_throw_protocol_error("non-canonical 16-bit websocket payload length")
                    dec.payload_length = v
                else
                    v = UInt64(0)
                    for i in 1:8
                        v = (v << 8) | UInt64(dec.length_cache[i])
                    end
                    (v < 65536 || v > WS_MAX_PAYLOAD_LENGTH) && _ws_throw_protocol_error("invalid 64-bit websocket payload length")
                    dec.payload_length = v
                end
                on_frame_header === nothing || on_frame_header(dec.opcode, dec.fin, dec.payload_length)
                dec.state = dec.masked ? WsDecoderState.MASKING_KEY : WsDecoderState.PAYLOAD
                dec.payload_length == 0 && !dec.masked && (dec.state = WsDecoderState.DONE)
            end
        elseif dec.state == WsDecoderState.MASKING_KEY
            needed = 4 - length(dec.key_cache)
            available = min(needed, lastindex(data) - pos + 1)
            append!(dec.key_cache, @view data[pos:(pos+available-1)])
            pos += available
            if length(dec.key_cache) == 4
                dec.masking_key = (dec.key_cache[1], dec.key_cache[2], dec.key_cache[3], dec.key_cache[4])
                dec.state = dec.payload_length > 0 ? WsDecoderState.PAYLOAD : WsDecoderState.DONE
            end
        elseif dec.state == WsDecoderState.PAYLOAD
            dec.payload_length > WS_MAX_PAYLOAD_LENGTH && _ws_throw_protocol_error("websocket payload length exceeds maximum")
            payload_length_int = Int(dec.payload_length)
            remaining = payload_length_int - length(dec.payload_buf)
            remaining < 0 && _ws_throw_protocol_error("websocket payload length underflow")
            available = min(remaining, lastindex(data) - pos + 1)
            chunk = @view data[pos:(pos+available-1)]
            pos += available
            if dec.masked
                offset = length(dec.payload_buf)
                for i in 1:available
                    push!(dec.payload_buf, chunk[i] ⊻ dec.masking_key[((offset+i-1)%4)+1])
                end
            else
                append!(dec.payload_buf, chunk)
            end
            length(dec.payload_buf) == payload_length_int && (dec.state = WsDecoderState.DONE)
        end
        if dec.state == WsDecoderState.DONE
            if dec.opcode == UInt8(WsOpcode.CLOSE)
                ws_validate_close_payload(dec.payload_buf)
            elseif dec.opcode == UInt8(WsOpcode.TEXT)
                if dec.fin
                    isvalid(String, dec.payload_buf) || _ws_throw_invalid_payload("invalid UTF-8 text frame payload")
                else
                    append!(dec.text_fragment_payload, dec.payload_buf)
                end
            elseif dec.opcode == UInt8(WsOpcode.CONTINUATION)
                if dec.fragment_opcode == UInt8(WsOpcode.TEXT)
                    append!(dec.text_fragment_payload, dec.payload_buf)
                    if dec.fin
                        if !isvalid(String, dec.text_fragment_payload)
                            dec.expecting_continuation = false
                            dec.fragment_opcode = UInt8(0)
                            empty!(dec.text_fragment_payload)
                            _ws_throw_invalid_payload("invalid UTF-8 continuation payload")
                        end
                        dec.fragment_opcode = UInt8(0)
                        empty!(dec.text_fragment_payload)
                    end
                elseif dec.fin
                    dec.fragment_opcode = UInt8(0)
                end
            end
            frame = WsFrame(
                dec.fin,
                dec.rsv,
                dec.opcode,
                dec.masked,
                dec.masking_key,
                dec.payload_length,
                copy(dec.payload_buf),
            )
            push!(frames, frame)
            f === nothing || f(frame)
            _ws_decoder_reset!(dec)
        end
    end
    return frames
end

function ws_decoder_process!(dec::WsDecoder, data::AbstractVector{UInt8}; on_frame_header=nothing)::Vector{WsFrame{Vector{UInt8}}}
    return ws_decoder_process!(nothing, dec, data; on_frame_header=on_frame_header)
end

function ws_is_valid_close_status(code::UInt16)::Bool
    code < 1000 && return false
    code in (1004, 1005, 1006) && return false
    code >= 1000 && code <= 1011 && return true
    code >= 3000 && code <= 4999 && return true
    return false
end

function ws_encode_close_payload(status_code::UInt16, reason::AbstractVector{UInt8}=UInt8[])::ByteMemory
    buf = bytememory(2 + length(reason))
    buf[1] = UInt8((status_code >> 8) & 0xff)
    buf[2] = UInt8(status_code & 0xff)
    if !isempty(reason)
        copyto!(buf, 3, reason, 1, length(reason))
    end
    return buf
end

function ws_validate_close_payload(payload::AbstractVector{UInt8})::Nothing
    len = length(payload)
    len == 0 && return nothing
    len == 1 && _ws_throw_protocol_error("close payload length must be 0 or >= 2")
    code = (UInt16(payload[1]) << 8) | UInt16(payload[2])
    ws_is_valid_close_status(code) || _ws_throw_protocol_error("invalid websocket close status")
    if len > 2
        reason = @view payload[3:len]
        isvalid(String, reason) || _ws_throw_invalid_payload("invalid websocket close reason")
    end
    return nothing
end

function ws_decode_close_payload(payload::AbstractVector{UInt8})::Tuple{UInt16,Vector{UInt8}}
    length(payload) < 2 && return UInt16(0), UInt8[]
    code = (UInt16(payload[1]) << 8) | UInt16(payload[2])
    reason = length(payload) > 2 ? copy(@view(payload[3:end])) : UInt8[]
    return code, reason
end

mutable struct WSConn
    is_client::Bool
    is_open::Bool
    close_sent::Bool
    close_received::Bool
    decoder::WsDecoder
    outgoing_frames::Vector{ByteMemory}
    max_incoming_payload_length::UInt64
    incoming_message_payload_total::UInt64
end

function WSConn(;
    is_client::Bool=true,
    max_incoming_payload_length::UInt64=UInt64(0),
)::WSConn
    decoder = ws_decoder_new()
    return WSConn(
        is_client,
        true,
        false,
        false,
        decoder,
        ByteMemory[],
        max_incoming_payload_length,
        UInt64(0),
    )
end

function ws_send_frame!(ws::WSConn, opcode::UInt8, payload::AbstractVector{UInt8}; fin::Bool=true)::Nothing
    ws.is_open || throw(ProtocolError("websocket connection is closed"))
    if ws_is_control_frame(opcode)
        !fin && throw(ArgumentError("control frames must not be fragmented"))
        length(payload) > 125 && throw(ArgumentError("control frame payloads must be <= 125 bytes"))
    end
    masking_key = if ws.is_client
        key = rand(UInt8, 4)
        (key[1], key[2], key[3], key[4])
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
    push!(ws.outgoing_frames, ws_encode_frame(frame))
    return nothing
end

function ws_send_ping!(ws::WSConn, payload::AbstractVector{UInt8}=UInt8[])::Nothing
    ws_send_frame!(ws, UInt8(WsOpcode.PING), payload)
    return nothing
end

function ws_send_pong!(ws::WSConn, payload::AbstractVector{UInt8}=UInt8[])::Nothing
    ws_send_frame!(ws, UInt8(WsOpcode.PONG), payload)
    return nothing
end

function ws_close!(ws::WSConn; status_code::UInt16=UInt16(1000), reason::AbstractVector{UInt8}=UInt8[])::Nothing
    ws.close_sent && return nothing
    ws_is_valid_close_status(status_code) || throw(ArgumentError("invalid websocket close status"))
    isempty(reason) || isvalid(String, reason) || throw(ArgumentError("websocket close reason must be valid UTF-8"))
    length(reason) <= 123 || throw(ArgumentError("websocket close reason must be <= 123 bytes"))
    payload = ws_encode_close_payload(status_code, reason)
    ws_send_frame!(ws, UInt8(WsOpcode.CLOSE), payload)
    ws.close_sent = true
    return nothing
end

function ws_on_incoming_data!(f::Union{Nothing,Function}, ws::WSConn, data::AbstractVector{UInt8})::Vector{WsFrame{Vector{UInt8}}}
    frames = if ws.max_incoming_payload_length > 0
        incoming_total = ws.incoming_message_payload_total
        ws_decoder_process!(
            f,
            ws.decoder,
            data;
            on_frame_header=(opcode::UInt8, fin::Bool, payload_length::UInt64) -> begin
                if ws_is_data_frame(opcode)
                    running_total = opcode == UInt8(WsOpcode.CONTINUATION) ? incoming_total : UInt64(0)
                    if running_total > ws.max_incoming_payload_length || payload_length > (ws.max_incoming_payload_length - running_total)
                        _ws_throw_protocol_error("incoming websocket payload exceeds configured maximum")
                    end
                    incoming_total = running_total + payload_length
                    fin && (incoming_total = UInt64(0))
                else
                    payload_length > ws.max_incoming_payload_length && _ws_throw_protocol_error("incoming websocket control frame exceeds configured maximum")
                end
                return nothing
            end,
        )
    else
        ws_decoder_process!(f, ws.decoder, data)
    end
    for (i, frame) in pairs(frames)
        if ws.is_client
            frame.masked && _ws_throw_protocol_error("server websocket frames must not be masked")
        else
            !frame.masked && _ws_throw_protocol_error("client websocket frames must be masked")
        end
        if ws.max_incoming_payload_length > 0
            if ws_is_data_frame(frame.opcode)
                running_total = frame.opcode == UInt8(WsOpcode.CONTINUATION) ? ws.incoming_message_payload_total : UInt64(0)
                if running_total > ws.max_incoming_payload_length || frame.payload_length > (ws.max_incoming_payload_length - running_total)
                    _ws_throw_protocol_error("incoming websocket payload exceeds configured maximum")
                end
                ws.incoming_message_payload_total = running_total + frame.payload_length
            else
                frame.payload_length > ws.max_incoming_payload_length && _ws_throw_protocol_error("incoming websocket control frame exceeds configured maximum")
            end
        end
        if frame.opcode == UInt8(WsOpcode.PING)
            ws_send_pong!(ws, frame.payload)
        end
        if frame.opcode == UInt8(WsOpcode.CLOSE)
            ws.close_received = true
            if !ws.close_sent
                ws_send_frame!(ws, UInt8(WsOpcode.CLOSE), frame.payload)
                ws.close_sent = true
            end
            ws.is_open = false
            resize!(frames, i)
            return frames
        end
        if ws_is_data_frame(frame.opcode) && frame.fin
            ws.incoming_message_payload_total = UInt64(0)
        end
    end
    return frames
end

function ws_on_incoming_data!(ws::WSConn, data::AbstractVector{UInt8})::Vector{WsFrame{Vector{UInt8}}}
    return ws_on_incoming_data!(nothing, ws, data)
end

function ws_get_outgoing_data!(ws::WSConn)::Vector{UInt8}
    total = 0
    for frame in ws.outgoing_frames
        total += length(frame)
    end
    output = Vector{UInt8}(undef, total)
    pos = 1
    for frame in ws.outgoing_frames
        n = length(frame)
        copyto!(output, pos, frame, 1, n)
        pos += n
    end
    empty!(ws.outgoing_frames)
    return output
end

function ws_random_handshake_key()::String
    return _base64encode(rand(UInt8, 16))
end

function ws_compute_accept_key(key::AbstractString)::String
    hash = SHA.sha1(Vector{UInt8}(codeunits(string(key, WS_GUID))))
    return _base64encode(hash)
end

function _ws_valid_handshake_key(key::AbstractString)::Bool
    stripped = strip(String(key))
    isempty(stripped) && return false
    decoded = try
        Base64.base64decode(stripped)
    catch
        return false
    end
    return length(decoded) == 16
end

@inline function _ws_header_value_has_token(value::AbstractString, token::AbstractString, case_sensitive::Bool=false)::Bool
    for part in eachsplit(value, ',')
        trimmed = strip(part)
        isempty(trimmed) && continue
        if case_sensitive
            trimmed == token && return true
        else
            lowercase(trimmed) == lowercase(token) && return true
        end
    end
    return false
end

@inline function _ws_headers_have_token(hdrs::Headers, name::AbstractString, token::AbstractString, case_sensitive::Bool=false)::Bool
    values = headers(hdrs, name)
    isempty(values) && return false
    for value in values
        _ws_header_value_has_token(value, token, case_sensitive) && return true
    end
    return false
end

function ws_is_websocket_request(request::Request)::Bool
    uppercase(request.method) == "GET" || return false
    _ws_headers_have_token(request.headers, "Upgrade", "websocket", false) || return false
    _ws_headers_have_token(request.headers, "Connection", "upgrade", false) || return false
    ws_get_request_sec_websocket_key(request) === nothing && return false
    version = header(request.headers, "Sec-WebSocket-Version", nothing)
    version === nothing && return false
    strip(version) == "13" || return false
    return true
end

function ws_get_request_sec_websocket_key(request::Request)::Union{Nothing,String}
    key = header(request.headers, "Sec-WebSocket-Key", nothing)
    key === nothing && return nothing
    stripped = strip(key)
    _ws_valid_handshake_key(stripped) || return nothing
    return stripped
end

function ws_select_subprotocol(request::Request, server_protocols::AbstractVector{<:AbstractString})::Union{Nothing,String}
    values = headers(request.headers, "Sec-WebSocket-Protocol")
    isempty(values) && return nothing
    requested = String[]
    for value in values
        for part in eachsplit(value, ',')
            trimmed = strip(part)
            isempty(trimmed) && continue
            push!(requested, String(trimmed))
        end
    end
    for server_protocol in server_protocols
        protocol = String(server_protocol)
        protocol in requested && return protocol
    end
    return nothing
end
