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

# RFC 6455 §5.3 requires the client frame masking key to be derived from a strong
# source of entropy so that an observer of prior frames cannot predict future
# masks (a predictable mask enables crafting wire bytes that a non-conformant
# transparent intermediary may interpret and cache, i.e. proxy cache poisoning).
# The default task-local `rand` uses Xoshiro256++, which is not cryptographically
# secure: its internal state is recoverable from a short run of outputs. Draw the
# masking key (and the Sec-WebSocket-Key handshake nonce) from a CSPRNG instead.
const WS_CSPRNG = Random.RandomDevice()
ws_secure_random_bytes(n::Integer)::Vector{UInt8} = rand(WS_CSPRNG, UInt8, n)

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

# XOR `n` bytes of `src` (from `src_from`) with the rotating 4-byte mask `key`
# into `dst` (from `dst_from`), where `key_phase` payload bytes preceded this
# chunk (frames arrive split across reads at arbitrary boundaries). Works
# in-place (dst === src over the same region). Contiguous sources process 8
# bytes per iteration with the key broadcast into a UInt64, so masking runs at
# memcpy speed instead of the ~1 GiB/s of a byte-at-a-time XOR with a per-byte
# modulo. Non-contiguous sources fall back to indexed access to preserve
# AbstractVector semantics.
@inline function _ws_contiguous_vector(v::AbstractVector{UInt8})::Bool
    v isa DenseVector{UInt8} && return true
    v isa StridedVector{UInt8} && return stride(v, 1) == 1
    return false
end

function _ws_mask_into_indexed!(dst::AbstractVector{UInt8}, dst_from::Int,
                                src::AbstractVector{UInt8}, src_from::Int,
                                n::Int, key::NTuple{4,UInt8}, key_phase::Int)::Nothing
    phase = key_phase % 4
    k = (key[phase+1], key[(phase+1)%4+1], key[(phase+2)%4+1], key[(phase+3)%4+1])
    dst_i = dst_from
    src_i = src_from
    i = 0
    @inbounds while i < n
        dst[dst_i] = src[src_i] ⊻ k[(i % 4) + 1]
        dst_i = nextind(dst, dst_i)
        src_i = nextind(src, src_i)
        i += 1
    end
    return nothing
end

function _ws_mask_into!(dst::AbstractVector{UInt8}, dst_from::Int,
                        src::AbstractVector{UInt8}, src_from::Int,
                        n::Int, key::NTuple{4,UInt8}, key_phase::Int)::Nothing
    n <= 0 && return nothing
    if !_ws_contiguous_vector(dst) || !_ws_contiguous_vector(src)
        return _ws_mask_into_indexed!(dst, dst_from, src, src_from, n, key, key_phase)
    end
    phase = key_phase % 4
    k = (key[phase+1], key[(phase+1)%4+1], key[(phase+2)%4+1], key[(phase+3)%4+1])
    k64 = UInt64(k[1]) | (UInt64(k[2]) << 8) | (UInt64(k[3]) << 16) | (UInt64(k[4]) << 24)
    k64 |= k64 << 32   # little-endian: byte j of k64 is k[(j % 4) + 1]
    i = 0
    GC.@preserve dst src begin
        pd = pointer(dst, dst_from)
        ps = pointer(src, src_from)
        while i + 8 <= n
            v = unsafe_load(Ptr{UInt64}(ps + i))
            unsafe_store!(Ptr{UInt64}(pd + i), v ⊻ k64)
            i += 8
        end
        while i < n
            unsafe_store!(pd + i, unsafe_load(ps + i) ⊻ k[(i % 4) + 1])
            i += 1
        end
    end
    return nothing
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
            _ws_mask_into!(buf, pos, frame.payload, 1, Int(frame.payload_length), frame.masking_key, 0)
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
    payload_received::Int
    expecting_continuation::Bool
    fragment_opcode::UInt8
    text_fragment_payload::Vector{UInt8}
    # permessage-deflate (RFC 7692): `pmce_enabled` is set when the extension was
    # negotiated (so RSV1 is allowed); `message_compressed` carries the current
    # message's RSV1 across its fragments. When a message is compressed the
    # decoder defers UTF-8 validation — the bytes are compressed until the upper
    # layer inflates the reassembled message.
    pmce_enabled::Bool
    message_compressed::Bool
    # Reused result vector for ws_decoder_process! — contents are valid only
    # until the next process! call on this decoder.
    frames_scratch::Vector{WsFrame{Vector{UInt8}}}
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
        0,
        false,
        UInt8(0),
        UInt8[],
        false,
        false,
        WsFrame{Vector{UInt8}}[],
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
    dec.payload_received = 0
    return nothing
end

# Pre-size the payload buffer to the exact frame length when the claimed length
# is sane; beyond this cap, grow with the arriving chunks (amortized) so a
# forged 8-byte length header cannot allocate unbounded memory up front.
const _WS_PAYLOAD_PREALLOC_CAP = 4 * 1024 * 1024

@inline function _ws_throw_protocol_error(message::AbstractString)
    throw(WebSocketProtocolError(String(message)))
end

@inline function _ws_throw_invalid_payload(message::AbstractString)
    throw(WebSocketInvalidPayloadError(String(message)))
end

function ws_decoder_process!(f::Union{Nothing,Function}, dec::WsDecoder, data::AbstractVector{UInt8}, datalen::Int=lastindex(data); on_frame_header=nothing)::Vector{WsFrame{Vector{UInt8}}}
    frames = dec.frames_scratch
    empty!(frames)
    pos = firstindex(data)
    while pos <= datalen
        if dec.state == WsDecoderState.OPCODE_BYTE
            b = data[pos]
            pos += 1
            dec.fin = (b & 0x80) != 0
            dec.rsv = ((b & 0x40) != 0, (b & 0x20) != 0, (b & 0x10) != 0)
            dec.opcode = b & 0x0f
            dec.opcode in (0x00, 0x01, 0x02, 0x08, 0x09, 0x0a) || _ws_throw_protocol_error("invalid websocket opcode")
            # RSV2/RSV3 are never valid (no negotiated extension uses them). RSV1
            # is the permessage-deflate per-message-compressed bit: valid only
            # when negotiated, and only on the first frame of a data message.
            (dec.rsv[2] || dec.rsv[3]) && _ws_throw_protocol_error("unexpected websocket RSV bits without negotiated extensions")
            dec.rsv[1] && !(dec.pmce_enabled && dec.opcode in (0x01, 0x02)) && _ws_throw_protocol_error("unexpected websocket RSV1 bit")
            is_control = ws_is_control_frame(dec.opcode)
            is_control && !dec.fin && _ws_throw_protocol_error("control frames must not be fragmented")
            if !is_control
                if dec.opcode == UInt8(WsOpcode.CONTINUATION)
                    (!dec.expecting_continuation || dec.fragment_opcode == UInt8(0)) && _ws_throw_protocol_error("unexpected continuation frame")
                else
                    dec.expecting_continuation && _ws_throw_protocol_error("unexpected new data frame while fragmented message is open")
                    empty!(dec.text_fragment_payload)
                    dec.fragment_opcode = dec.fin ? UInt8(0) : dec.opcode
                    # RSV1 on the first data frame marks the whole message compressed.
                    dec.message_compressed = dec.rsv[1]
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
            available = min(needed, datalen - pos + 1)
            @inbounds for k in 0:(available-1)
                push!(dec.length_cache, data[pos+k])
            end
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
            available = min(needed, datalen - pos + 1)
            @inbounds for k in 0:(available-1)
                push!(dec.key_cache, data[pos+k])
            end
            pos += available
            if length(dec.key_cache) == 4
                dec.masking_key = (dec.key_cache[1], dec.key_cache[2], dec.key_cache[3], dec.key_cache[4])
                dec.state = dec.payload_length > 0 ? WsDecoderState.PAYLOAD : WsDecoderState.DONE
            end
        elseif dec.state == WsDecoderState.PAYLOAD
            dec.payload_length > WS_MAX_PAYLOAD_LENGTH && _ws_throw_protocol_error("websocket payload length exceeds maximum")
            payload_length_int = Int(dec.payload_length)
            remaining = payload_length_int - dec.payload_received
            remaining < 0 && _ws_throw_protocol_error("websocket payload length underflow")
            available = min(remaining, datalen - pos + 1)
            if length(dec.payload_buf) < payload_length_int
                if payload_length_int <= _WS_PAYLOAD_PREALLOC_CAP
                    resize!(dec.payload_buf, payload_length_int)
                elseif length(dec.payload_buf) < dec.payload_received + available
                    resize!(dec.payload_buf, dec.payload_received + available)
                end
            end
            if available > 0
                if dec.masked
                    _ws_mask_into!(dec.payload_buf, dec.payload_received + 1, data, pos, available, dec.masking_key, dec.payload_received)
                else
                    copyto!(dec.payload_buf, dec.payload_received + 1, data, pos, available)
                end
                dec.payload_received += available
                pos += available
            end
            dec.payload_received == payload_length_int && (dec.state = WsDecoderState.DONE)
        end
        if dec.state == WsDecoderState.DONE
            if dec.opcode == UInt8(WsOpcode.CLOSE)
                ws_validate_close_payload(dec.payload_buf)
            elseif dec.opcode == UInt8(WsOpcode.TEXT)
                # Compressed text is validated upstream, after decompression.
                if dec.message_compressed
                    # nothing to validate here
                elseif dec.fin
                    isvalid(String, dec.payload_buf) || _ws_throw_invalid_payload("invalid UTF-8 text frame payload")
                else
                    append!(dec.text_fragment_payload, dec.payload_buf)
                end
            elseif dec.opcode == UInt8(WsOpcode.CONTINUATION)
                if dec.fragment_opcode == UInt8(WsOpcode.TEXT)
                    dec.message_compressed || append!(dec.text_fragment_payload, dec.payload_buf)
                    if dec.fin
                        if !dec.message_compressed && !isvalid(String, dec.text_fragment_payload)
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
            # Hand the accumulated buffer to the frame and swap in a fresh one:
            # the frame's payload must be caller-owned (it is delivered to user
            # code), and the swap avoids a payload-sized copy per frame.
            payload = dec.payload_buf
            dec.payload_buf = UInt8[]
            dec.payload_received = 0
            frame = WsFrame(
                dec.fin,
                dec.rsv,
                dec.opcode,
                dec.masked,
                dec.masking_key,
                dec.payload_length,
                payload,
            )
            push!(frames, frame)
            f === nothing || f(frame)
            _ws_decoder_reset!(dec)
        end
    end
    return frames
end

function ws_decoder_process!(dec::WsDecoder, data::AbstractVector{UInt8}, datalen::Int=lastindex(data); on_frame_header=nothing)::Vector{WsFrame{Vector{UInt8}}}
    return ws_decoder_process!(nothing, dec, data, datalen; on_frame_header=on_frame_header)
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
    # Outgoing bytes are encoded directly into `outgoing` (no per-frame buffer,
    # no concat copy). `out_lock` is a leaf lock guarding only buffer mutation —
    # it is never held across socket I/O, so the read task can queue PONG/CLOSE
    # replies while a writer is blocked in a socket write. Flushing swaps
    # `outgoing` with `outgoing_spare` (socket writes themselves stay serialized
    # by the connection's send lock, which all flush call sites hold).
    out_lock::ReentrantLock
    outgoing::Vector{UInt8}
    outgoing_spare::Vector{UInt8}
    max_incoming_payload_length::UInt64
    incoming_message_payload_total::UInt64
    # permessage-deflate state, or nothing when the extension is not negotiated.
    pmce::Union{Nothing,PMCEContext}
end

function WSConn(;
    is_client::Bool=true,
    max_incoming_payload_length::UInt64=UInt64(0),
    pmce::Union{Nothing,PMCEContext}=nothing,
)::WSConn
    decoder = ws_decoder_new()
    decoder.pmce_enabled = pmce !== nothing
    return WSConn(
        is_client,
        true,
        false,
        false,
        decoder,
        ReentrantLock(),
        UInt8[],
        UInt8[],
        max_incoming_payload_length,
        UInt64(0),
        pmce,
    )
end

# Encode `frame` appended onto `out` (header + payload in place): the single
# payload copy doubles as the masking pass, and capacity is retained across
# flushes, so steady-state sends allocate nothing here.
function _ws_append_frame!(out::Vector{UInt8}, frame::WsFrame)::Nothing
    header_size = 2
    if frame.payload_length >= 65536
        header_size += 8
    elseif frame.payload_length >= 126
        header_size += 2
    end
    frame.masked && (header_size += 4)
    old = length(out)
    resize!(out, old + header_size + Int(frame.payload_length))
    pos = old + 1
    b1 = frame.opcode & 0x0f
    frame.fin && (b1 |= 0x80)
    frame.rsv[1] && (b1 |= 0x40)
    frame.rsv[2] && (b1 |= 0x20)
    frame.rsv[3] && (b1 |= 0x10)
    @inbounds out[pos] = b1
    pos += 1
    b2 = UInt8(0)
    frame.masked && (b2 |= 0x80)
    if frame.payload_length < 126
        @inbounds out[pos] = b2 | UInt8(frame.payload_length)
        pos += 1
    elseif frame.payload_length <= 0xffff
        @inbounds out[pos] = b2 | UInt8(126)
        @inbounds out[pos+1] = UInt8((frame.payload_length >> 8) & 0xff)
        @inbounds out[pos+2] = UInt8(frame.payload_length & 0xff)
        pos += 3
    else
        @inbounds out[pos] = b2 | UInt8(127)
        pos += 1
        for i in 7:-1:0
            @inbounds out[pos] = UInt8((frame.payload_length >> (8 * i)) & 0xff)
            pos += 1
        end
    end
    if frame.masked
        @inbounds out[pos] = frame.masking_key[1]
        @inbounds out[pos+1] = frame.masking_key[2]
        @inbounds out[pos+2] = frame.masking_key[3]
        @inbounds out[pos+3] = frame.masking_key[4]
        pos += 4
    end
    if !isempty(frame.payload)
        if frame.masked
            _ws_mask_into!(out, pos, frame.payload, 1, Int(frame.payload_length), frame.masking_key, 0)
        else
            copyto!(out, pos, frame.payload, 1, Int(frame.payload_length))
        end
    end
    return nothing
end

function ws_send_frame!(ws::WSConn, opcode::UInt8, payload::AbstractVector{UInt8}; fin::Bool=true, rsv1::Bool=false)::Nothing
    ws.is_open || throw(ProtocolError("websocket connection is closed"))
    if ws_is_control_frame(opcode)
        !fin && throw(ArgumentError("control frames must not be fragmented"))
        length(payload) > 125 && throw(ArgumentError("control frame payloads must be <= 125 bytes"))
    end
    masking_key = if ws.is_client
        # RFC 6455 §5.3: the masking key must be unpredictable, so use a CSPRNG.
        key = ws_secure_random_bytes(4)
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
        rsv=(rsv1, false, false),
    )
    @lock ws.out_lock begin
        _ws_append_frame!(ws.outgoing, frame)
    end
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

# Frame-header guard for the configured-maximum path: a callable struct instead
# of a closure so the running total isn't a captured-and-reassigned local
# (which Julia would box, costing a heap Box plus dynamic loads per header).
mutable struct _WsMaxLengthGuard
    conn::WSConn
    running_total::UInt64
end

function (g::_WsMaxLengthGuard)(opcode::UInt8, fin::Bool, payload_length::UInt64)
    ws = g.conn
    if ws_is_data_frame(opcode)
        running_total = opcode == UInt8(WsOpcode.CONTINUATION) ? g.running_total : UInt64(0)
        if running_total > ws.max_incoming_payload_length || payload_length > (ws.max_incoming_payload_length - running_total)
            _ws_throw_protocol_error("incoming websocket payload exceeds configured maximum")
        end
        g.running_total = fin ? UInt64(0) : running_total + payload_length
    else
        payload_length > ws.max_incoming_payload_length && _ws_throw_protocol_error("incoming websocket control frame exceeds configured maximum")
    end
    return nothing
end

function ws_on_incoming_data!(f::Union{Nothing,Function}, ws::WSConn, data::AbstractVector{UInt8}, datalen::Int=lastindex(data))::Vector{WsFrame{Vector{UInt8}}}
    frames = if ws.max_incoming_payload_length > 0
        ws_decoder_process!(
            f,
            ws.decoder,
            data,
            datalen;
            on_frame_header=_WsMaxLengthGuard(ws, ws.incoming_message_payload_total),
        )
    else
        ws_decoder_process!(f, ws.decoder, data, datalen)
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

function ws_on_incoming_data!(ws::WSConn, data::AbstractVector{UInt8}, datalen::Int=lastindex(data))::Vector{WsFrame{Vector{UInt8}}}
    return ws_on_incoming_data!(nothing, ws, data, datalen)
end

# Take the pending outgoing bytes for writing. Returns the accumulation buffer
# itself (a swap, not a copy); it remains valid until the *next* take, which is
# safe because all flush/write call sites are serialized by the connection's
# send lock.
function ws_get_outgoing_data!(ws::WSConn)::Vector{UInt8}
    @lock ws.out_lock begin
        out = ws.outgoing
        spare = ws.outgoing_spare
        empty!(spare)
        ws.outgoing = spare
        ws.outgoing_spare = out
        return out
    end
end

function ws_random_handshake_key()::String
    # RFC 6455 §5.3 / §4.1: generate the Sec-WebSocket-Key nonce from a CSPRNG so
    # it shares the same unpredictable entropy source as the frame masking keys.
    return _base64encode(ws_secure_random_bytes(16))
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
