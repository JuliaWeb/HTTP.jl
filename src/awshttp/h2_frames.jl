# HTTP/2 Frames - Frame types, encoder, decoder
# Port of aws-c-http h2_frames.h, h2_frames.c, h2_decoder.h, h2_decoder.c

# ─── Frame type enum (RFC 7540 section 6) ───

@enumx H2FrameType::UInt8 begin
    DATA = 0x00
    HEADERS = 0x01
    PRIORITY = 0x02
    RST_STREAM = 0x03
    SETTINGS = 0x04
    PUSH_PROMISE = 0x05
    PING = 0x06
    GOAWAY = 0x07
    WINDOW_UPDATE = 0x08
    CONTINUATION = 0x09
    UNKNOWN = 0xFF
end

const _H2_FRAME_TYPE_STRINGS = Dict{H2FrameType.T, String}(
    H2FrameType.DATA => "DATA",
    H2FrameType.HEADERS => "HEADERS",
    H2FrameType.PRIORITY => "PRIORITY",
    H2FrameType.RST_STREAM => "RST_STREAM",
    H2FrameType.SETTINGS => "SETTINGS",
    H2FrameType.PUSH_PROMISE => "PUSH_PROMISE",
    H2FrameType.PING => "PING",
    H2FrameType.GOAWAY => "GOAWAY",
    H2FrameType.WINDOW_UPDATE => "WINDOW_UPDATE",
    H2FrameType.CONTINUATION => "CONTINUATION",
    H2FrameType.UNKNOWN => "UNKNOWN",
)

h2_frame_type_to_str(t::H2FrameType.T)::String = get(_H2_FRAME_TYPE_STRINGS, t, "UNKNOWN")

function _h2_frame_type_from_byte(b::UInt8)::H2FrameType.T
    b <= 0x09 && return H2FrameType.T(b)
    return H2FrameType.UNKNOWN
end

# ─── Frame flags (RFC 7540 section 6) ───

const H2_FRAME_F_ACK         = 0x01
const H2_FRAME_F_END_STREAM  = 0x01  # same bit, context-dependent
const H2_FRAME_F_END_HEADERS = 0x04
const H2_FRAME_F_PADDED      = 0x08
const H2_FRAME_F_PRIORITY    = 0x20

# Acceptable flags per frame type (unknown types: all flags ignored)
const _H2_ACCEPTABLE_FLAGS = Dict{H2FrameType.T, UInt8}(
    H2FrameType.DATA          => H2_FRAME_F_END_STREAM | H2_FRAME_F_PADDED,
    H2FrameType.HEADERS       => H2_FRAME_F_END_STREAM | H2_FRAME_F_END_HEADERS | H2_FRAME_F_PADDED | H2_FRAME_F_PRIORITY,
    H2FrameType.PRIORITY      => 0x00,
    H2FrameType.RST_STREAM    => 0x00,
    H2FrameType.SETTINGS      => H2_FRAME_F_ACK,
    H2FrameType.PUSH_PROMISE  => H2_FRAME_F_END_HEADERS | H2_FRAME_F_PADDED,
    H2FrameType.PING          => H2_FRAME_F_ACK,
    H2FrameType.GOAWAY        => 0x00,
    H2FrameType.WINDOW_UPDATE => 0x00,
    H2FrameType.CONTINUATION  => H2_FRAME_F_END_HEADERS,
    H2FrameType.UNKNOWN       => 0x00,
)

# ─── Frame constants ───

const H2_PAYLOAD_MAX      = 0x00FFFFFF   # 3 bytes max
const H2_WINDOW_UPDATE_MAX = 0x7FFFFFFF  # 31-bit max
const H2_STREAM_ID_MAX    = 0x7FFFFFFF   # 31-bit max
const H2_FRAME_PREFIX_SIZE = 9           # length(3) + type(1) + flags(1) + stream_id(4)
const H2_INIT_WINDOW_SIZE = 65535        # RFC 7540 initial window size
const H2_PING_DATA_SIZE   = 8           # PING opaque data size

const H2_CONNECTION_PREFACE_CLIENT = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

# ─── H2 error pair (aws_h2err) ───

struct H2Err
    h2_code::Http2ErrorCode.T
    aws_code::Int
end

const H2ERR_SUCCESS = H2Err(Http2ErrorCode.NO_ERROR, 0)

h2err_from_h2_code(code::Http2ErrorCode.T) = H2Err(code, ERROR_HTTP_PROTOCOL_ERROR)
h2err_from_aws_code(code::Int) = H2Err(Http2ErrorCode.INTERNAL_ERROR, code)
h2err_success(err::H2Err) = err.h2_code == Http2ErrorCode.NO_ERROR && err.aws_code == 0
h2err_failed(err::H2Err) = !h2err_success(err)

function h2_validate_stream_id(stream_id::UInt32)::Int
    if stream_id == 0 || stream_id > H2_STREAM_ID_MAX
        return raise_error(ERROR_INVALID_ARGUMENT)
    end
    return OP_SUCCESS
end

# ─── HTTP/2 settings (RFC 7540 section 6.5.2) ───

@enumx Http2SettingsId::UInt16 begin
    HEADER_TABLE_SIZE = 0x01
    ENABLE_PUSH = 0x02
    MAX_CONCURRENT_STREAMS = 0x03
    INITIAL_WINDOW_SIZE = 0x04
    MAX_FRAME_SIZE = 0x05
    MAX_HEADER_LIST_SIZE = 0x06
end

const HTTP2_SETTINGS_BEGIN_RANGE = UInt16(Http2SettingsId.HEADER_TABLE_SIZE)
const HTTP2_SETTINGS_END_RANGE = UInt16(Http2SettingsId.MAX_HEADER_LIST_SIZE) + UInt16(1)

struct Http2Setting
    id::Http2SettingsId.T
    value::UInt32
end

# Bounds: [min, max] per setting ID
const H2_SETTINGS_BOUNDS = Dict{Http2SettingsId.T, Tuple{UInt32, UInt32}}(
    Http2SettingsId.HEADER_TABLE_SIZE     => (UInt32(0), typemax(UInt32)),
    Http2SettingsId.ENABLE_PUSH           => (UInt32(0), UInt32(1)),
    Http2SettingsId.MAX_CONCURRENT_STREAMS => (UInt32(0), typemax(UInt32)),
    Http2SettingsId.INITIAL_WINDOW_SIZE   => (UInt32(0), UInt32(H2_WINDOW_UPDATE_MAX)),
    Http2SettingsId.MAX_FRAME_SIZE        => (UInt32(16384), UInt32(H2_PAYLOAD_MAX)),
    Http2SettingsId.MAX_HEADER_LIST_SIZE  => (UInt32(0), typemax(UInt32)),
)

# Initial values (RFC 7540 6.5.2)
const H2_SETTINGS_INITIAL = Dict{Http2SettingsId.T, UInt32}(
    Http2SettingsId.HEADER_TABLE_SIZE     => UInt32(4096),
    Http2SettingsId.ENABLE_PUSH           => UInt32(1),
    Http2SettingsId.MAX_CONCURRENT_STREAMS => typemax(UInt32),
    Http2SettingsId.INITIAL_WINDOW_SIZE   => UInt32(H2_INIT_WINDOW_SIZE),
    Http2SettingsId.MAX_FRAME_SIZE        => UInt32(16384),
    Http2SettingsId.MAX_HEADER_LIST_SIZE  => typemax(UInt32),
)

# Stream ID rules per frame type
@enumx _StreamIdRule::UInt8 begin
    REQUIRED = 0   # must be non-zero
    FORBIDDEN = 1  # must be zero
    EITHER = 2     # can be either
end

const _STREAM_ID_RULES = Dict{H2FrameType.T, _StreamIdRule.T}(
    H2FrameType.DATA          => _StreamIdRule.REQUIRED,
    H2FrameType.HEADERS       => _StreamIdRule.REQUIRED,
    H2FrameType.PRIORITY      => _StreamIdRule.REQUIRED,
    H2FrameType.RST_STREAM    => _StreamIdRule.REQUIRED,
    H2FrameType.SETTINGS      => _StreamIdRule.FORBIDDEN,
    H2FrameType.PUSH_PROMISE  => _StreamIdRule.REQUIRED,
    H2FrameType.PING          => _StreamIdRule.FORBIDDEN,
    H2FrameType.GOAWAY        => _StreamIdRule.FORBIDDEN,
    H2FrameType.WINDOW_UPDATE => _StreamIdRule.EITHER,
    H2FrameType.CONTINUATION  => _StreamIdRule.REQUIRED,
    H2FrameType.UNKNOWN       => _StreamIdRule.EITHER,
)

# ─── Frame prefix encoding/decoding ───

function _h2_write_frame_prefix!(buf::AbstractVector{UInt8}, pos::Int,
    payload_len::UInt32, frame_type::UInt8, flags::UInt8, stream_id::UInt32)::Int
    # Length: 3 bytes big-endian
    buf[pos]   = UInt8((payload_len >> 16) & 0xFF)
    buf[pos+1] = UInt8((payload_len >> 8) & 0xFF)
    buf[pos+2] = UInt8(payload_len & 0xFF)
    # Type: 1 byte
    buf[pos+3] = frame_type
    # Flags: 1 byte
    buf[pos+4] = flags
    # Stream ID: 4 bytes big-endian (reserved bit = 0)
    buf[pos+5] = UInt8((stream_id >> 24) & 0x7F)  # mask top bit
    buf[pos+6] = UInt8((stream_id >> 16) & 0xFF)
    buf[pos+7] = UInt8((stream_id >> 8) & 0xFF)
    buf[pos+8] = UInt8(stream_id & 0xFF)
    return pos + 9
end

function _h2_encode_frame_prefix(payload_len::UInt32, frame_type::UInt8,
    flags::UInt8, stream_id::UInt32)::Memory{UInt8}
    buf = Memory{UInt8}(undef, 9)
    _h2_write_frame_prefix!(buf, 1, payload_len, frame_type, flags, stream_id)
    return buf
end

struct _H2FramePrefix
    payload_len::UInt32
    frame_type::H2FrameType.T
    flags::UInt8
    stream_id::UInt32
end

function _h2_decode_frame_prefix(data::AbstractVector{UInt8}, pos::Int)::Tuple{_H2FramePrefix, Int}
    payload_len = (UInt32(data[pos]) << 16) | (UInt32(data[pos+1]) << 8) | UInt32(data[pos+2])
    frame_type = _h2_frame_type_from_byte(data[pos+3])
    flags = data[pos+4]
    stream_id = (UInt32(data[pos+5]) << 24) | (UInt32(data[pos+6]) << 16) |
                (UInt32(data[pos+7]) << 8) | UInt32(data[pos+8])
    stream_id &= 0x7FFFFFFF  # mask reserved bit
    return (_H2FramePrefix(payload_len, frame_type, flags, stream_id), pos + 9)
end

# ─── Priority settings encoding ───

function _h2_encode_priority(priority::Http2PrioritySettings)::Memory{UInt8}
    buf = Memory{UInt8}(undef, 5)
    top = priority.stream_dependency | (UInt32(priority.stream_dependency_exclusive) << 31)
    buf[1] = UInt8((top >> 24) & 0xFF)
    buf[2] = UInt8((top >> 16) & 0xFF)
    buf[3] = UInt8((top >> 8) & 0xFF)
    buf[4] = UInt8(top & 0xFF)
    buf[5] = UInt8(priority.weight & 0xFF)
    return buf
end

function _h2_decode_priority(data::AbstractVector{UInt8}, pos::Int)::Tuple{Http2PrioritySettings, Int}
    top = (UInt32(data[pos]) << 24) | (UInt32(data[pos+1]) << 16) |
          (UInt32(data[pos+2]) << 8) | UInt32(data[pos+3])
    exclusive = (top & 0x80000000) != 0
    dep = top & 0x7FFFFFFF
    weight = UInt16(data[pos+4])
    return (Http2PrioritySettings(dep, exclusive, weight), pos + 5)
end

# ─── Settings encoding for HTTP Upgrade header ───

function h2_encode_http2_settings_header(settings::Vector{Http2Setting})::Tuple{Int, Vector{UInt8}}
    # Encode settings to binary (6 bytes each)
    binary = Vector{UInt8}(undef, 6 * length(settings))
    pos = 1
    for s in settings
        id_val = UInt16(s.id)
        if id_val < HTTP2_SETTINGS_BEGIN_RANGE || id_val >= HTTP2_SETTINGS_END_RANGE
            return (raise_error(ERROR_INVALID_ARGUMENT), UInt8[])
        end
        bounds = H2_SETTINGS_BOUNDS[s.id]
        if s.value < bounds[1] || s.value > bounds[2]
            return (raise_error(ERROR_INVALID_ARGUMENT), UInt8[])
        end
        binary[pos]   = UInt8((id_val >> 8) & 0xFF)
        binary[pos+1] = UInt8(id_val & 0xFF)
        binary[pos+2] = UInt8((s.value >> 24) & 0xFF)
        binary[pos+3] = UInt8((s.value >> 16) & 0xFF)
        binary[pos+4] = UInt8((s.value >> 8) & 0xFF)
        binary[pos+5] = UInt8(s.value & 0xFF)
        pos += 6
    end
    # Base64-URL encode (no padding)
    encoded = base64url_encode(binary)
    return (OP_SUCCESS, encoded)
end

function h2_decode_http2_settings_header(header_value::AbstractVector{UInt8})::Tuple{Int, Vector{Http2Setting}}
    # Base64-URL decode
    binary = base64url_decode(header_value)
    if binary === nothing
        return (raise_error(ERROR_INVALID_ARGUMENT), Http2Setting[])
    end
    if length(binary) % 6 != 0
        return (raise_error(ERROR_INVALID_ARGUMENT), Http2Setting[])
    end
    n = length(binary) ÷ 6
    settings = Http2Setting[]
    pos = 1
    for _ in 1:n
        id_val = (UInt16(binary[pos]) << 8) | UInt16(binary[pos+1])
        value = (UInt32(binary[pos+2]) << 24) | (UInt32(binary[pos+3]) << 16) |
                (UInt32(binary[pos+4]) << 8) | UInt32(binary[pos+5])
        pos += 6
        if id_val >= HTTP2_SETTINGS_BEGIN_RANGE && id_val < HTTP2_SETTINGS_END_RANGE
            sid = Http2SettingsId.T(id_val)
            bounds = H2_SETTINGS_BOUNDS[sid]
            if value < bounds[1] || value > bounds[2]
                return (raise_error(ERROR_INVALID_ARGUMENT), Http2Setting[])
            end
            push!(settings, Http2Setting(sid, value))
        end
        # Skip unknown setting IDs
    end
    return (OP_SUCCESS, settings)
end

# Base64-URL encoding/decoding helpers
function base64url_encode(data::AbstractVector{UInt8})::Vector{UInt8}
    encoded = base64encode(data)
    # Convert to URL-safe: + → -, / → _, remove =
    result = UInt8[]
    for c in encoded
        if c == UInt8('+')
            push!(result, UInt8('-'))
        elseif c == UInt8('/')
            push!(result, UInt8('_'))
        elseif c == UInt8('=')
            # skip padding
        else
            push!(result, c)
        end
    end
    return result
end

function base64url_decode(data::AbstractVector{UInt8})::Union{Nothing, Vector{UInt8}}
    # Convert from URL-safe back to standard base64
    std = UInt8[]
    for c in data
        if c == UInt8('-')
            push!(std, UInt8('+'))
        elseif c == UInt8('_')
            push!(std, UInt8('/'))
        else
            push!(std, c)
        end
    end
    # Add padding
    while length(std) % 4 != 0
        push!(std, UInt8('='))
    end
    try
        return base64decode(String(copy(std)))
    catch
        return nothing
    end
end

using Base64

# ─── Frame encoder ───

mutable struct H2FrameEncoder
    hpack::HpackEncoder
    max_frame_size::UInt32
    has_errored::Bool
end

function h2_frame_encoder_new()::H2FrameEncoder
    return H2FrameEncoder(
        hpack_encoder_init(),
        UInt32(16384),  # initial MAX_FRAME_SIZE
        false,
    )
end

function h2_frame_encoder_set_setting_header_table_size!(encoder::H2FrameEncoder, size::UInt32)
    hpack_encoder_update_max_table_size!(encoder.hpack, size)
end

function h2_frame_encoder_set_setting_max_frame_size!(encoder::H2FrameEncoder, size::UInt32)
    encoder.max_frame_size = size
end

# ─── Frame constructors (encode immediately for simple frames) ───

# Encode a HEADERS frame (may produce CONTINUATION frames if block exceeds max frame size)
function h2_encode_headers(encoder::H2FrameEncoder, stream_id::UInt32,
    headers::HttpHeaders;
    end_stream::Bool=false,
    priority::Union{Nothing, Http2PrioritySettings}=nothing,
    pad_length::UInt8=0x00)::Tuple{Int, Memory{UInt8}}

    if encoder.has_errored
        return (raise_error(ERROR_HTTP_PROTOCOL_ERROR), Memory{UInt8}(undef, 0))
    end

    # HPACK-encode the header block
    status, header_block = hpack_encode_header_block(encoder.hpack, headers)
    if status != OP_SUCCESS
        encoder.has_errored = true
        return (status, Memory{UInt8}(undef, 0))
    end

    # Build flags for first frame
    flags = UInt8(0)
    if end_stream
        flags |= H2_FRAME_F_END_STREAM
    end
    if priority !== nothing
        flags |= H2_FRAME_F_PRIORITY
    end
    if pad_length > 0
        flags |= H2_FRAME_F_PADDED
    end

    # Calculate overhead in first frame
    overhead = 0
    if pad_length > 0
        overhead += 1  # pad length byte
    end
    if priority !== nothing
        overhead += 5  # priority block
    end
    overhead += Int(pad_length)  # padding itself

    max_payload = Int(encoder.max_frame_size)
    max_block_in_first = max_payload - overhead

    output = UInt8[]

    if length(header_block) <= max_block_in_first
        # Single HEADERS frame
        flags |= H2_FRAME_F_END_HEADERS
        payload_len = UInt32(overhead + length(header_block) - Int(pad_length) + Int(pad_length))
        # payload = pad_len_byte(opt) + priority(opt) + header_block + padding(opt)
        actual_payload_len = overhead + length(header_block)
        prefix = _h2_encode_frame_prefix(UInt32(actual_payload_len), UInt8(H2FrameType.HEADERS), flags, stream_id)
        append!(output, prefix)
        if pad_length > 0
            push!(output, pad_length)
        end
        if priority !== nothing
            append!(output, _h2_encode_priority(priority))
        end
        append!(output, header_block)
        if pad_length > 0
            append!(output, zeros(UInt8, Int(pad_length)))
        end
    else
        # First HEADERS frame (no END_HEADERS)
        block_in_first = max(0, max_block_in_first)
        actual_payload_len = overhead + block_in_first
        prefix = _h2_encode_frame_prefix(UInt32(actual_payload_len), UInt8(H2FrameType.HEADERS), flags, stream_id)
        append!(output, prefix)
        if pad_length > 0
            push!(output, pad_length)
        end
        if priority !== nothing
            append!(output, _h2_encode_priority(priority))
        end
        if block_in_first > 0
            append!(output, @view header_block[1:block_in_first])
        end
        if pad_length > 0
            append!(output, zeros(UInt8, Int(pad_length)))
        end

        # CONTINUATION frames for remainder
        block_pos = block_in_first + 1
        while block_pos <= length(header_block)
            remaining = length(header_block) - block_pos + 1
            chunk_size = min(remaining, max_payload)
            cont_flags = UInt8(0)
            if block_pos + chunk_size - 1 >= length(header_block)
                cont_flags |= H2_FRAME_F_END_HEADERS
            end
            cont_prefix = _h2_encode_frame_prefix(UInt32(chunk_size), UInt8(H2FrameType.CONTINUATION), cont_flags, stream_id)
            append!(output, cont_prefix)
            append!(output, @view header_block[block_pos:block_pos+chunk_size-1])
            block_pos += chunk_size
        end
    end

    # Freeze: built as Vector (variable-size HPACK), convert to Memory
    result = Memory{UInt8}(undef, length(output))
    copyto!(result, 1, output, 1, length(output))
    return (OP_SUCCESS, result)
end

# Encode a PRIORITY frame
function h2_encode_priority_frame(stream_id::UInt32, priority::Http2PrioritySettings)::Tuple{Int, Memory{UInt8}}
    if stream_id == 0
        return (raise_error(ERROR_INVALID_ARGUMENT), Memory{UInt8}(undef, 0))
    end
    buf = Memory{UInt8}(undef, 14)  # 9 prefix + 5 priority
    _h2_write_frame_prefix!(buf, 1, UInt32(5), UInt8(H2FrameType.PRIORITY), 0x00, stream_id)
    priority_data = _h2_encode_priority(priority)
    copyto!(buf, 10, priority_data, 1, 5)
    return (OP_SUCCESS, buf)
end

# Encode a RST_STREAM frame
function h2_encode_rst_stream(stream_id::UInt32, error_code::UInt32)::Tuple{Int, Memory{UInt8}}
    if stream_id == 0
        return (raise_error(ERROR_INVALID_ARGUMENT), Memory{UInt8}(undef, 0))
    end
    buf = Memory{UInt8}(undef, 13)
    _h2_write_frame_prefix!(buf, 1, UInt32(4), UInt8(H2FrameType.RST_STREAM), 0x00, stream_id)
    buf[10] = UInt8((error_code >> 24) & 0xFF)
    buf[11] = UInt8((error_code >> 16) & 0xFF)
    buf[12] = UInt8((error_code >> 8) & 0xFF)
    buf[13] = UInt8(error_code & 0xFF)
    return (OP_SUCCESS, buf)
end

# Encode a SETTINGS frame
function h2_encode_settings(settings::Vector{Http2Setting}; ack::Bool=false)::Tuple{Int, Memory{UInt8}}
    if ack
        # ACK frame: empty payload
        prefix = _h2_encode_frame_prefix(UInt32(0), UInt8(H2FrameType.SETTINGS), H2_FRAME_F_ACK, UInt32(0))
        return (OP_SUCCESS, prefix)
    end
    payload_len = 6 * length(settings)
    buf = Memory{UInt8}(undef, 9 + payload_len)
    _h2_write_frame_prefix!(buf, 1, UInt32(payload_len), UInt8(H2FrameType.SETTINGS), 0x00, UInt32(0))
    pos = 10
    for s in settings
        id_val = UInt16(s.id)
        buf[pos]   = UInt8((id_val >> 8) & 0xFF)
        buf[pos+1] = UInt8(id_val & 0xFF)
        buf[pos+2] = UInt8((s.value >> 24) & 0xFF)
        buf[pos+3] = UInt8((s.value >> 16) & 0xFF)
        buf[pos+4] = UInt8((s.value >> 8) & 0xFF)
        buf[pos+5] = UInt8(s.value & 0xFF)
        pos += 6
    end
    return (OP_SUCCESS, buf)
end

# Encode a PUSH_PROMISE frame
function h2_encode_push_promise(encoder::H2FrameEncoder, stream_id::UInt32,
    promised_stream_id::UInt32, headers::HttpHeaders;
    pad_length::UInt8=0x00)::Tuple{Int, Memory{UInt8}}

    if encoder.has_errored
        return (raise_error(ERROR_HTTP_PROTOCOL_ERROR), Memory{UInt8}(undef, 0))
    end
    if stream_id == 0
        return (raise_error(ERROR_INVALID_ARGUMENT), Memory{UInt8}(undef, 0))
    end

    status, header_block = hpack_encode_header_block(encoder.hpack, headers)
    if status != OP_SUCCESS
        encoder.has_errored = true
        return (status, Memory{UInt8}(undef, 0))
    end

    flags = UInt8(0)
    if pad_length > 0
        flags |= H2_FRAME_F_PADDED
    end

    # Overhead: pad_len(1,opt) + promised_stream_id(4) + padding(opt)
    overhead = 4  # promised stream ID
    if pad_length > 0
        overhead += 1  # pad length byte
    end
    overhead += Int(pad_length)  # padding

    max_payload = Int(encoder.max_frame_size)
    max_block_in_first = max_payload - overhead

    output = UInt8[]

    if length(header_block) <= max_block_in_first
        flags |= H2_FRAME_F_END_HEADERS
        actual_payload_len = overhead + length(header_block)
        prefix = _h2_encode_frame_prefix(UInt32(actual_payload_len), UInt8(H2FrameType.PUSH_PROMISE), flags, stream_id)
        append!(output, prefix)
        if pad_length > 0
            push!(output, pad_length)
        end
        # Promised stream ID (4 bytes, reserved bit 0)
        push!(output, UInt8((promised_stream_id >> 24) & 0x7F))
        push!(output, UInt8((promised_stream_id >> 16) & 0xFF))
        push!(output, UInt8((promised_stream_id >> 8) & 0xFF))
        push!(output, UInt8(promised_stream_id & 0xFF))
        append!(output, header_block)
        if pad_length > 0
            append!(output, zeros(UInt8, Int(pad_length)))
        end
    else
        # Fragment across PUSH_PROMISE + CONTINUATION frames
        block_in_first = max(0, max_block_in_first)
        actual_payload_len = overhead + block_in_first
        prefix = _h2_encode_frame_prefix(UInt32(actual_payload_len), UInt8(H2FrameType.PUSH_PROMISE), flags, stream_id)
        append!(output, prefix)
        if pad_length > 0
            push!(output, pad_length)
        end
        push!(output, UInt8((promised_stream_id >> 24) & 0x7F))
        push!(output, UInt8((promised_stream_id >> 16) & 0xFF))
        push!(output, UInt8((promised_stream_id >> 8) & 0xFF))
        push!(output, UInt8(promised_stream_id & 0xFF))
        if block_in_first > 0
            append!(output, @view header_block[1:block_in_first])
        end
        if pad_length > 0
            append!(output, zeros(UInt8, Int(pad_length)))
        end

        block_pos = block_in_first + 1
        while block_pos <= length(header_block)
            remaining = length(header_block) - block_pos + 1
            chunk_size = min(remaining, max_payload)
            cont_flags = UInt8(0)
            if block_pos + chunk_size - 1 >= length(header_block)
                cont_flags |= H2_FRAME_F_END_HEADERS
            end
            cont_prefix = _h2_encode_frame_prefix(UInt32(chunk_size), UInt8(H2FrameType.CONTINUATION), cont_flags, stream_id)
            append!(output, cont_prefix)
            append!(output, @view header_block[block_pos:block_pos+chunk_size-1])
            block_pos += chunk_size
        end
    end

    # Freeze: built as Vector (variable-size HPACK), convert to Memory
    result = Memory{UInt8}(undef, length(output))
    copyto!(result, 1, output, 1, length(output))
    return (OP_SUCCESS, result)
end

# Encode a PING frame
function h2_encode_ping(opaque_data::AbstractVector{UInt8}; ack::Bool=false)::Tuple{Int, Memory{UInt8}}
    if length(opaque_data) != H2_PING_DATA_SIZE
        return (raise_error(ERROR_INVALID_ARGUMENT), Memory{UInt8}(undef, 0))
    end
    flags = ack ? H2_FRAME_F_ACK : UInt8(0)
    buf = Memory{UInt8}(undef, 9 + H2_PING_DATA_SIZE)
    _h2_write_frame_prefix!(buf, 1, UInt32(H2_PING_DATA_SIZE), UInt8(H2FrameType.PING), flags, UInt32(0))
    copyto!(buf, 10, opaque_data, 1, H2_PING_DATA_SIZE)
    return (OP_SUCCESS, buf)
end

# Encode a GOAWAY frame
function h2_encode_goaway(last_stream_id::UInt32, error_code::UInt32;
    debug_data::AbstractVector{UInt8}=UInt8[])::Tuple{Int, Memory{UInt8}}

    # Truncate debug data if too large for one frame
    max_debug = H2_PAYLOAD_MAX - 8  # 8 bytes for last_stream_id + error_code
    debug_len = min(length(debug_data), max_debug)
    payload_len = 8 + debug_len
    buf = Memory{UInt8}(undef, 9 + payload_len)
    _h2_write_frame_prefix!(buf, 1, UInt32(payload_len), UInt8(H2FrameType.GOAWAY), 0x00, UInt32(0))
    # Last-Stream-ID (31 bits)
    buf[10] = UInt8((last_stream_id >> 24) & 0x7F)
    buf[11] = UInt8((last_stream_id >> 16) & 0xFF)
    buf[12] = UInt8((last_stream_id >> 8) & 0xFF)
    buf[13] = UInt8(last_stream_id & 0xFF)
    # Error code (32 bits)
    buf[14] = UInt8((error_code >> 24) & 0xFF)
    buf[15] = UInt8((error_code >> 16) & 0xFF)
    buf[16] = UInt8((error_code >> 8) & 0xFF)
    buf[17] = UInt8(error_code & 0xFF)
    # Debug data
    if debug_len > 0
        copyto!(buf, 18, debug_data, 1, debug_len)
    end
    return (OP_SUCCESS, buf)
end

# Encode a WINDOW_UPDATE frame
function h2_encode_window_update(stream_id::UInt32, window_increment::UInt32)::Tuple{Int, Memory{UInt8}}
    if window_increment > H2_WINDOW_UPDATE_MAX
        return (raise_error(ERROR_INVALID_ARGUMENT), Memory{UInt8}(undef, 0))
    end
    buf = Memory{UInt8}(undef, 13)
    _h2_write_frame_prefix!(buf, 1, UInt32(4), UInt8(H2FrameType.WINDOW_UPDATE), 0x00, stream_id)
    # Window increment (31 bits, reserved bit 0)
    buf[10] = UInt8((window_increment >> 24) & 0x7F)
    buf[11] = UInt8((window_increment >> 16) & 0xFF)
    buf[12] = UInt8((window_increment >> 8) & 0xFF)
    buf[13] = UInt8(window_increment & 0xFF)
    return (OP_SUCCESS, buf)
end

# Encode a DATA frame (without body stream — for simple payloads)
function h2_encode_data(stream_id::UInt32, data::AbstractVector{UInt8};
    end_stream::Bool=false, pad_length::UInt8=0x00)::Tuple{Int, Memory{UInt8}}

    if stream_id == 0
        return (raise_error(ERROR_INVALID_ARGUMENT), Memory{UInt8}(undef, 0))
    end
    flags = UInt8(0)
    if end_stream
        flags |= H2_FRAME_F_END_STREAM
    end
    if pad_length > 0
        flags |= H2_FRAME_F_PADDED
    end
    overhead = pad_length > 0 ? 1 + Int(pad_length) : 0
    payload_len = UInt32(overhead + length(data))
    buf = Memory{UInt8}(undef, 9 + Int(payload_len))
    _h2_write_frame_prefix!(buf, 1, payload_len, UInt8(H2FrameType.DATA), flags, stream_id)
    pos = 10
    if pad_length > 0
        buf[pos] = pad_length
        pos += 1
    end
    if !isempty(data)
        copyto!(buf, pos, data, 1, length(data))
        pos += length(data)
    end
    if pad_length > 0
        for i in 1:Int(pad_length)
            buf[pos] = 0x00
            pos += 1
        end
    end
    return (OP_SUCCESS, buf)
end

# ─── Frame decoder ───

# Decoder callback interface
abstract type H2DecoderCallbacks end

# Decoded frame info returned from decoder
struct H2DecodedFrame
    frame_type::H2FrameType.T
    stream_id::UInt32
    flags::UInt8

    # Frame-specific data (only relevant fields filled per frame type)
    # DATA
    data::Memory{UInt8}
    end_stream::Bool

    # HEADERS
    headers::Vector{HttpHeader}
    header_block_type::HttpHeaderBlock.T
    priority::Union{Nothing, Http2PrioritySettings}

    # RST_STREAM
    error_code::UInt32

    # SETTINGS
    settings::Vector{Http2Setting}
    ack::Bool

    # PUSH_PROMISE
    promised_stream_id::UInt32

    # PING
    opaque_data::Memory{UInt8}

    # GOAWAY
    last_stream_id::UInt32
    goaway_error_code::UInt32
    debug_data::Memory{UInt8}

    # WINDOW_UPDATE
    window_increment::UInt32
end

# Default constructor
function H2DecodedFrame(;
    frame_type::H2FrameType.T=H2FrameType.UNKNOWN,
    stream_id::UInt32=UInt32(0),
    flags::UInt8=0x00,
    data::Memory{UInt8}=Memory{UInt8}(undef, 0),
    end_stream::Bool=false,
    headers::Vector{HttpHeader}=HttpHeader[],
    header_block_type::HttpHeaderBlock.T=HttpHeaderBlock.MAIN,
    priority::Union{Nothing, Http2PrioritySettings}=nothing,
    error_code::UInt32=UInt32(0),
    settings::Vector{Http2Setting}=Http2Setting[],
    ack::Bool=false,
    promised_stream_id::UInt32=UInt32(0),
    opaque_data::Memory{UInt8}=Memory{UInt8}(undef, 0),
    last_stream_id::UInt32=UInt32(0),
    goaway_error_code::UInt32=UInt32(0),
    debug_data::Memory{UInt8}=Memory{UInt8}(undef, 0),
    window_increment::UInt32=UInt32(0))
    return H2DecodedFrame(frame_type, stream_id, flags, data, end_stream,
        headers, header_block_type, priority, error_code, settings, ack,
        promised_stream_id, opaque_data, last_stream_id, goaway_error_code,
        debug_data, window_increment)
end

@enumx _H2DecoderState::UInt8 begin
    CONNECTION_PREFACE = 0
    PREFIX = 1
    PAYLOAD = 2
    PADDING = 3
    COMPLETE = 4
end

mutable struct H2Decoder
    hpack::HpackDecoder
    is_server::Bool
    max_frame_size::UInt32
    max_header_list_size::UInt32
    connection_preface_complete::Bool
    has_errored::Bool

    # Header block in progress
    header_block_stream_id::UInt32  # 0 if none
    header_block_is_push_promise::Bool
    header_block_ends_stream::Bool
    header_block_data::Vector{UInt8}  # accumulated header block bytes
    header_block_promised_stream_id::UInt32
    header_block_priority::Union{Nothing, Http2PrioritySettings}
end

function h2_decoder_new(; is_server::Bool=true)::H2Decoder
    return H2Decoder(
        hpack_decoder_init(),
        is_server,
        UInt32(16384),       # initial max frame size
        typemax(UInt32),     # max header list size
        false,               # connection preface not complete
        false,
        UInt32(0), false, false, UInt8[], UInt32(0), nothing,
    )
end

function h2_decoder_set_setting_header_table_size!(decoder::H2Decoder, size::UInt32)
    hpack_decoder_update_max_table_size!(decoder.hpack, size)
end

function h2_decoder_set_setting_max_frame_size!(decoder::H2Decoder, size::UInt32)
    decoder.max_frame_size = size
end

"""
    h2_decode_frame(decoder, data, pos) -> (H2Err, H2DecodedFrame, new_pos)

Decode a single complete frame from data starting at pos.
Returns the decoded frame and the position after the frame.
If not enough data, returns H2ERR_SUCCESS with frame_type=UNKNOWN and same pos.
"""
function h2_decode_frame(decoder::H2Decoder, data::AbstractVector{UInt8}, pos::Int)::Tuple{H2Err, H2DecodedFrame, Int}
    if decoder.has_errored
        return (h2err_from_aws_code(ERROR_HTTP_PROTOCOL_ERROR), H2DecodedFrame(), pos)
    end

    start_pos = pos
    remaining = length(data) - pos + 1

    # Handle connection preface for server-side decoder
    if !decoder.connection_preface_complete && decoder.is_server
        preface_len = length(H2_CONNECTION_PREFACE_CLIENT)
        if remaining < preface_len
            return (H2ERR_SUCCESS, H2DecodedFrame(), pos)
        end
        if @view(data[pos:pos+preface_len-1]) != H2_CONNECTION_PREFACE_CLIENT
            decoder.has_errored = true
            return (h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR), H2DecodedFrame(), pos)
        end
        pos += preface_len
        remaining -= preface_len
        # Connection preface validated, but still need first SETTINGS frame
    end

    # Need at least frame prefix
    if remaining < H2_FRAME_PREFIX_SIZE
        return (H2ERR_SUCCESS, H2DecodedFrame(), start_pos)
    end

    # Parse frame prefix
    prefix, pos = _h2_decode_frame_prefix(data, pos)
    remaining = length(data) - pos + 1

    # Validate payload size
    if prefix.payload_len > decoder.max_frame_size
        decoder.has_errored = true
        return (h2err_from_h2_code(Http2ErrorCode.FRAME_SIZE_ERROR), H2DecodedFrame(), start_pos)
    end

    # Need full payload
    if remaining < Int(prefix.payload_len)
        return (H2ERR_SUCCESS, H2DecodedFrame(), start_pos)
    end

    # Mask flags to acceptable set
    acceptable = get(_H2_ACCEPTABLE_FLAGS, prefix.frame_type, UInt8(0))
    flags = prefix.flags & acceptable

    # Validate stream ID
    rule = get(_STREAM_ID_RULES, prefix.frame_type, _StreamIdRule.EITHER)
    if prefix.stream_id != 0 && rule == _StreamIdRule.FORBIDDEN
        decoder.has_errored = true
        return (h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR), H2DecodedFrame(), start_pos)
    end
    if prefix.stream_id == 0 && rule == _StreamIdRule.REQUIRED
        decoder.has_errored = true
        return (h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR), H2DecodedFrame(), start_pos)
    end

    # Connection preface: first frame must be SETTINGS (no ACK)
    if !decoder.connection_preface_complete
        if prefix.frame_type != H2FrameType.SETTINGS || (flags & H2_FRAME_F_ACK) != 0
            decoder.has_errored = true
            return (h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR), H2DecodedFrame(), start_pos)
        end
        decoder.connection_preface_complete = true
    end

    # Check CONTINUATION sequence rules
    if decoder.header_block_stream_id != 0
        # Header block in progress — only CONTINUATION on same stream is allowed
        if prefix.frame_type != H2FrameType.CONTINUATION || prefix.stream_id != decoder.header_block_stream_id
            decoder.has_errored = true
            return (h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR), H2DecodedFrame(), start_pos)
        end
    elseif prefix.frame_type == H2FrameType.CONTINUATION
        # CONTINUATION without preceding HEADERS/PUSH_PROMISE
        decoder.has_errored = true
        return (h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR), H2DecodedFrame(), start_pos)
    end

    # Extract payload
    payload_start = pos
    payload_end = pos + Int(prefix.payload_len) - 1
    next_pos = payload_end + 1

    # Decode based on frame type
    err, frame = _h2_decode_frame_payload(decoder, prefix, flags, data, payload_start, payload_end)

    if h2err_failed(err)
        decoder.has_errored = true
        return (err, H2DecodedFrame(), start_pos)
    end

    return (H2ERR_SUCCESS, frame, next_pos)
end

function _h2_decode_frame_payload(decoder::H2Decoder, prefix::_H2FramePrefix, flags::UInt8,
    data::AbstractVector{UInt8}, payload_start::Int, payload_end::Int)::Tuple{H2Err, H2DecodedFrame}

    frame_type = prefix.frame_type
    stream_id = prefix.stream_id
    payload_len = Int(prefix.payload_len)

    # Handle padding
    pad_length = UInt8(0)
    content_start = payload_start
    content_end = payload_end

    is_padded = (flags & H2_FRAME_F_PADDED) != 0
    if is_padded && payload_len > 0
        pad_length = data[payload_start]
        content_start += 1
        reduce = 1 + Int(pad_length)
        if reduce > payload_len
            return (h2err_from_h2_code(Http2ErrorCode.PROTOCOL_ERROR), H2DecodedFrame())
        end
        content_end = payload_end - Int(pad_length)
    end

    content_len = max(0, content_end - content_start + 1)

    if frame_type == H2FrameType.DATA
        return _decode_data_frame(stream_id, flags, data, content_start, content_end, content_len)
    elseif frame_type == H2FrameType.HEADERS
        return _decode_headers_frame(decoder, stream_id, flags, data, content_start, content_end, content_len)
    elseif frame_type == H2FrameType.PRIORITY
        return _decode_priority_frame(stream_id, data, content_start, content_end, payload_len)
    elseif frame_type == H2FrameType.RST_STREAM
        return _decode_rst_stream_frame(stream_id, data, content_start, payload_len)
    elseif frame_type == H2FrameType.SETTINGS
        return _decode_settings_frame(decoder, flags, data, content_start, payload_len)
    elseif frame_type == H2FrameType.PUSH_PROMISE
        return _decode_push_promise_frame(decoder, stream_id, flags, data, content_start, content_end, content_len)
    elseif frame_type == H2FrameType.PING
        return _decode_ping_frame(flags, data, content_start, payload_len)
    elseif frame_type == H2FrameType.GOAWAY
        return _decode_goaway_frame(data, content_start, payload_len)
    elseif frame_type == H2FrameType.WINDOW_UPDATE
        return _decode_window_update_frame(stream_id, data, content_start, payload_len)
    elseif frame_type == H2FrameType.CONTINUATION
        return _decode_continuation_frame(decoder, stream_id, flags, data, content_start, content_end, content_len)
    else
        # Unknown frame type — skip
        return (H2ERR_SUCCESS, H2DecodedFrame(frame_type=H2FrameType.UNKNOWN, stream_id=stream_id, flags=flags))
    end
end

function _decode_data_frame(stream_id::UInt32, flags::UInt8,
    data::AbstractVector{UInt8}, content_start::Int, content_end::Int, content_len::Int)::Tuple{H2Err, H2DecodedFrame}
    end_stream = (flags & H2_FRAME_F_END_STREAM) != 0
    body = if content_len > 0
        m = Memory{UInt8}(undef, content_len)
        copyto!(m, 1, data, content_start, content_len)
        m
    else
        Memory{UInt8}(undef, 0)
    end
    return (H2ERR_SUCCESS, H2DecodedFrame(
        frame_type=H2FrameType.DATA, stream_id=stream_id, flags=flags,
        data=body, end_stream=end_stream))
end

function _decode_headers_frame(decoder::H2Decoder, stream_id::UInt32, flags::UInt8,
    data::AbstractVector{UInt8}, content_start::Int, content_end::Int, content_len::Int)::Tuple{H2Err, H2DecodedFrame}

    pos = content_start
    priority = nothing

    # Parse priority block if present
    has_priority = (flags & H2_FRAME_F_PRIORITY) != 0
    if has_priority
        if content_len < 5
            return (h2err_from_h2_code(Http2ErrorCode.FRAME_SIZE_ERROR), H2DecodedFrame())
        end
        priority, pos = _h2_decode_priority(data, pos)
    end

    end_headers = (flags & H2_FRAME_F_END_HEADERS) != 0
    end_stream = (flags & H2_FRAME_F_END_STREAM) != 0

    # Extract header block fragment
    block_len = content_end - pos + 1
    block_fragment = block_len > 0 ? Vector{UInt8}(data[pos:content_end]) : UInt8[]

    if end_headers
        # Complete header block — decode HPACK
        return _finish_header_block(decoder, stream_id, flags, block_fragment,
            end_stream, priority, false, UInt32(0))
    else
        # Start header block, wait for CONTINUATION
        decoder.header_block_stream_id = stream_id
        decoder.header_block_is_push_promise = false
        decoder.header_block_ends_stream = end_stream
        decoder.header_block_data = block_fragment
        decoder.header_block_priority = priority
        # Return incomplete — caller should feed more data
        return (H2ERR_SUCCESS, H2DecodedFrame(
            frame_type=H2FrameType.HEADERS, stream_id=stream_id, flags=flags,
            end_stream=end_stream, priority=priority))
    end
end

function _decode_continuation_frame(decoder::H2Decoder, stream_id::UInt32, flags::UInt8,
    data::AbstractVector{UInt8}, content_start::Int, content_end::Int, content_len::Int)::Tuple{H2Err, H2DecodedFrame}

    # Append to accumulated header block
    if content_len > 0
        append!(decoder.header_block_data, @view data[content_start:content_end])
    end

    end_headers = (flags & H2_FRAME_F_END_HEADERS) != 0
    if end_headers
        # Complete header block
        is_pp = decoder.header_block_is_push_promise
        promised = decoder.header_block_promised_stream_id
        end_stream = decoder.header_block_ends_stream
        priority = decoder.header_block_priority
        block_data = decoder.header_block_data
        # Reset header block state
        decoder.header_block_stream_id = UInt32(0)
        decoder.header_block_data = UInt8[]
        decoder.header_block_priority = nothing

        return _finish_header_block(decoder, stream_id, flags, block_data,
            end_stream, priority, is_pp, promised)
    end

    # Still accumulating — return continuation indicator
    return (H2ERR_SUCCESS, H2DecodedFrame(
        frame_type=H2FrameType.CONTINUATION, stream_id=stream_id, flags=flags))
end

function _finish_header_block(decoder::H2Decoder, stream_id::UInt32, flags::UInt8,
    block_data::Vector{UInt8}, end_stream::Bool,
    priority::Union{Nothing, Http2PrioritySettings},
    is_push_promise::Bool, promised_stream_id::UInt32)::Tuple{H2Err, H2DecodedFrame}

    # Reset header block tracking
    decoder.header_block_stream_id = UInt32(0)

    # HPACK decode
    headers = HttpHeader[]
    pos_ref = Ref(1)
    while pos_ref[] <= length(block_data)
        status, result = hpack_decode!(decoder.hpack, block_data, pos_ref)
        if status != OP_SUCCESS
            return (h2err_from_h2_code(Http2ErrorCode.COMPRESSION_ERROR), H2DecodedFrame())
        end
        if result.type == HpackDecodeType.HEADER_FIELD
            push!(headers, HttpHeader(result.header_name, result.header_value, result.header_compression))
        elseif result.type == HpackDecodeType.DYNAMIC_TABLE_RESIZE
            # pos advanced by decoder
        else
            # ONGOING — shouldn't happen with complete block
            break
        end
    end

    frame_type = is_push_promise ? H2FrameType.PUSH_PROMISE : H2FrameType.HEADERS
    return (H2ERR_SUCCESS, H2DecodedFrame(
        frame_type=frame_type, stream_id=stream_id, flags=flags,
        headers=headers, end_stream=end_stream, priority=priority,
        header_block_type=HttpHeaderBlock.MAIN,
        promised_stream_id=promised_stream_id))
end

function _decode_priority_frame(stream_id::UInt32,
    data::AbstractVector{UInt8}, content_start::Int, content_end::Int, payload_len::Int)::Tuple{H2Err, H2DecodedFrame}
    if payload_len != 5
        return (h2err_from_h2_code(Http2ErrorCode.FRAME_SIZE_ERROR), H2DecodedFrame())
    end
    priority, _ = _h2_decode_priority(data, content_start)
    return (H2ERR_SUCCESS, H2DecodedFrame(
        frame_type=H2FrameType.PRIORITY, stream_id=stream_id,
        priority=priority))
end

function _decode_rst_stream_frame(stream_id::UInt32,
    data::AbstractVector{UInt8}, content_start::Int, payload_len::Int)::Tuple{H2Err, H2DecodedFrame}
    if payload_len != 4
        return (h2err_from_h2_code(Http2ErrorCode.FRAME_SIZE_ERROR), H2DecodedFrame())
    end
    error_code = (UInt32(data[content_start]) << 24) | (UInt32(data[content_start+1]) << 16) |
                 (UInt32(data[content_start+2]) << 8) | UInt32(data[content_start+3])
    return (H2ERR_SUCCESS, H2DecodedFrame(
        frame_type=H2FrameType.RST_STREAM, stream_id=stream_id,
        error_code=error_code))
end

function _decode_settings_frame(decoder::H2Decoder, flags::UInt8,
    data::AbstractVector{UInt8}, content_start::Int, payload_len::Int)::Tuple{H2Err, H2DecodedFrame}

    is_ack = (flags & H2_FRAME_F_ACK) != 0
    if is_ack
        if payload_len != 0
            return (h2err_from_h2_code(Http2ErrorCode.FRAME_SIZE_ERROR), H2DecodedFrame())
        end
        return (H2ERR_SUCCESS, H2DecodedFrame(
            frame_type=H2FrameType.SETTINGS, ack=true))
    end

    if payload_len % 6 != 0
        return (h2err_from_h2_code(Http2ErrorCode.FRAME_SIZE_ERROR), H2DecodedFrame())
    end

    n = payload_len ÷ 6
    settings = Http2Setting[]
    pos = content_start
    for _ in 1:n
        id_val = (UInt16(data[pos]) << 8) | UInt16(data[pos+1])
        value = (UInt32(data[pos+2]) << 24) | (UInt32(data[pos+3]) << 16) |
                (UInt32(data[pos+4]) << 8) | UInt32(data[pos+5])
        pos += 6

        # Validate known settings
        if id_val >= HTTP2_SETTINGS_BEGIN_RANGE && id_val < HTTP2_SETTINGS_END_RANGE
            sid = Http2SettingsId.T(id_val)
            bounds = H2_SETTINGS_BOUNDS[sid]
            if value < bounds[1] || value > bounds[2]
                # INITIAL_WINDOW_SIZE → FLOW_CONTROL_ERROR, others → PROTOCOL_ERROR
                err_code = sid == Http2SettingsId.INITIAL_WINDOW_SIZE ?
                    Http2ErrorCode.FLOW_CONTROL_ERROR : Http2ErrorCode.PROTOCOL_ERROR
                return (h2err_from_h2_code(err_code), H2DecodedFrame())
            end
            push!(settings, Http2Setting(sid, value))
        end
        # Unknown setting IDs are ignored
    end

    return (H2ERR_SUCCESS, H2DecodedFrame(
        frame_type=H2FrameType.SETTINGS, settings=settings))
end

function _decode_push_promise_frame(decoder::H2Decoder, stream_id::UInt32, flags::UInt8,
    data::AbstractVector{UInt8}, content_start::Int, content_end::Int, content_len::Int)::Tuple{H2Err, H2DecodedFrame}

    if content_len < 4
        return (h2err_from_h2_code(Http2ErrorCode.FRAME_SIZE_ERROR), H2DecodedFrame())
    end

    pos = content_start
    promised = (UInt32(data[pos]) << 24) | (UInt32(data[pos+1]) << 16) |
               (UInt32(data[pos+2]) << 8) | UInt32(data[pos+3])
    promised &= 0x7FFFFFFF  # mask reserved bit
    pos += 4

    end_headers = (flags & H2_FRAME_F_END_HEADERS) != 0
    block_len = content_end - pos + 1
    block_fragment = block_len > 0 ? Vector{UInt8}(data[pos:content_end]) : UInt8[]

    if end_headers
        return _finish_header_block(decoder, stream_id, flags, block_fragment,
            false, nothing, true, promised)
    else
        decoder.header_block_stream_id = stream_id
        decoder.header_block_is_push_promise = true
        decoder.header_block_ends_stream = false
        decoder.header_block_data = block_fragment
        decoder.header_block_promised_stream_id = promised
        decoder.header_block_priority = nothing
        return (H2ERR_SUCCESS, H2DecodedFrame(
            frame_type=H2FrameType.PUSH_PROMISE, stream_id=stream_id, flags=flags,
            promised_stream_id=promised))
    end
end

function _decode_ping_frame(flags::UInt8,
    data::AbstractVector{UInt8}, content_start::Int, payload_len::Int)::Tuple{H2Err, H2DecodedFrame}
    if payload_len != H2_PING_DATA_SIZE
        return (h2err_from_h2_code(Http2ErrorCode.FRAME_SIZE_ERROR), H2DecodedFrame())
    end
    opaque = Memory{UInt8}(undef, H2_PING_DATA_SIZE)
    copyto!(opaque, 1, data, content_start, H2_PING_DATA_SIZE)
    is_ack = (flags & H2_FRAME_F_ACK) != 0
    return (H2ERR_SUCCESS, H2DecodedFrame(
        frame_type=H2FrameType.PING, opaque_data=opaque, ack=is_ack))
end

function _decode_goaway_frame(
    data::AbstractVector{UInt8}, content_start::Int, payload_len::Int)::Tuple{H2Err, H2DecodedFrame}
    if payload_len < 8
        return (h2err_from_h2_code(Http2ErrorCode.FRAME_SIZE_ERROR), H2DecodedFrame())
    end
    pos = content_start
    last_stream = (UInt32(data[pos]) << 24) | (UInt32(data[pos+1]) << 16) |
                  (UInt32(data[pos+2]) << 8) | UInt32(data[pos+3])
    last_stream &= 0x7FFFFFFF
    pos += 4
    error_code = (UInt32(data[pos]) << 24) | (UInt32(data[pos+1]) << 16) |
                 (UInt32(data[pos+2]) << 8) | UInt32(data[pos+3])
    pos += 4
    debug_len = payload_len - 8
    debug = if debug_len > 0
        m = Memory{UInt8}(undef, debug_len)
        copyto!(m, 1, data, pos, debug_len)
        m
    else
        Memory{UInt8}(undef, 0)
    end
    return (H2ERR_SUCCESS, H2DecodedFrame(
        frame_type=H2FrameType.GOAWAY, last_stream_id=last_stream,
        goaway_error_code=error_code, debug_data=debug))
end

function _decode_window_update_frame(stream_id::UInt32,
    data::AbstractVector{UInt8}, content_start::Int, payload_len::Int)::Tuple{H2Err, H2DecodedFrame}
    if payload_len != 4
        return (h2err_from_h2_code(Http2ErrorCode.FRAME_SIZE_ERROR), H2DecodedFrame())
    end
    increment = (UInt32(data[content_start]) << 24) | (UInt32(data[content_start+1]) << 16) |
                (UInt32(data[content_start+2]) << 8) | UInt32(data[content_start+3])
    increment &= 0x7FFFFFFF  # mask reserved bit
    return (H2ERR_SUCCESS, H2DecodedFrame(
        frame_type=H2FrameType.WINDOW_UPDATE, stream_id=stream_id,
        window_increment=increment))
end
