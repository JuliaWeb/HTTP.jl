# HTTP/3 framing (RFC 9114 Section 7), stream types, settings, and error
# codes, over QUIC variable-length integers (RFC 9000 Section 16). Readers
# take any `IO`, in practice a `Reseau.QUIC.Stream`.

const _H3_FRAME_DATA = UInt64(0x00)
const _H3_FRAME_HEADERS = UInt64(0x01)
const _H3_FRAME_CANCEL_PUSH = UInt64(0x03)
const _H3_FRAME_SETTINGS = UInt64(0x04)
const _H3_FRAME_PUSH_PROMISE = UInt64(0x05)
const _H3_FRAME_GOAWAY = UInt64(0x07)
const _H3_FRAME_MAX_PUSH_ID = UInt64(0x0d)

# Frame types HTTP/2 used that HTTP/3 reserves (Section 7.2.8).
_h3_is_http2_frame_type(t::UInt64)::Bool = t == 0x02 || t == 0x06 || t == 0x08 || t == 0x09

const _H3_STREAM_CONTROL = UInt64(0x00)
const _H3_STREAM_PUSH = UInt64(0x01)
const _H3_STREAM_QPACK_ENCODER = UInt64(0x02)
const _H3_STREAM_QPACK_DECODER = UInt64(0x03)

const _H3_SETTING_QPACK_MAX_TABLE_CAPACITY = UInt64(0x01)
const _H3_SETTING_MAX_FIELD_SECTION_SIZE = UInt64(0x06)
const _H3_SETTING_QPACK_BLOCKED_STREAMS = UInt64(0x07)

const _H3_NO_ERROR = UInt64(0x100)
const _H3_GENERAL_PROTOCOL_ERROR = UInt64(0x101)
const _H3_INTERNAL_ERROR = UInt64(0x102)
const _H3_STREAM_CREATION_ERROR = UInt64(0x103)
const _H3_CLOSED_CRITICAL_STREAM = UInt64(0x104)
const _H3_FRAME_UNEXPECTED = UInt64(0x105)
const _H3_FRAME_ERROR = UInt64(0x106)
const _H3_EXCESSIVE_LOAD = UInt64(0x107)
const _H3_ID_ERROR = UInt64(0x108)
const _H3_SETTINGS_ERROR = UInt64(0x109)
const _H3_MISSING_SETTINGS = UInt64(0x10a)
const _H3_REQUEST_REJECTED = UInt64(0x10b)
const _H3_REQUEST_CANCELLED = UInt64(0x10c)
const _H3_REQUEST_INCOMPLETE = UInt64(0x10d)
const _H3_MESSAGE_ERROR = UInt64(0x10e)
const _H3_CONNECT_ERROR = UInt64(0x10f)
const _H3_VERSION_FALLBACK = UInt64(0x110)
const _QPACK_DECOMPRESSION_FAILED = UInt64(0x200)
const _QPACK_ENCODER_STREAM_ERROR = UInt64(0x201)
const _QPACK_DECODER_STREAM_ERROR = UInt64(0x202)

const _H3_ERROR_NAMES = Dict{UInt64,String}(
    0x100 => "H3_NO_ERROR",
    0x101 => "H3_GENERAL_PROTOCOL_ERROR",
    0x102 => "H3_INTERNAL_ERROR",
    0x103 => "H3_STREAM_CREATION_ERROR",
    0x104 => "H3_CLOSED_CRITICAL_STREAM",
    0x105 => "H3_FRAME_UNEXPECTED",
    0x106 => "H3_FRAME_ERROR",
    0x107 => "H3_EXCESSIVE_LOAD",
    0x108 => "H3_ID_ERROR",
    0x109 => "H3_SETTINGS_ERROR",
    0x10a => "H3_MISSING_SETTINGS",
    0x10b => "H3_REQUEST_REJECTED",
    0x10c => "H3_REQUEST_CANCELLED",
    0x10d => "H3_REQUEST_INCOMPLETE",
    0x10e => "H3_MESSAGE_ERROR",
    0x10f => "H3_CONNECT_ERROR",
    0x110 => "H3_VERSION_FALLBACK",
    0x200 => "QPACK_DECOMPRESSION_FAILED",
    0x201 => "QPACK_ENCODER_STREAM_ERROR",
    0x202 => "QPACK_DECODER_STREAM_ERROR",
)

_h3_error_name(code::UInt64)::String = get(() -> string("0x", string(code; base=16)), _H3_ERROR_NAMES, code)

"""
    _H3Error(code, message)

An HTTP/3 protocol violation found while reading: `code` is the HTTP/3 error
code to close the connection (or reset the stream) with.
"""
struct _H3Error <: Exception
    code::UInt64
    message::String
end

"""
    _H3StreamError(code, message[, kind])

A violation confined to one request stream: the stream is reset, and reading
stopped, with HTTP/3 error `code`, and the request fails with a
`ProtocolError` of `kind`; the connection goes on.
"""
struct _H3StreamError <: Exception
    code::UInt64
    message::String
    kind::_ProtocolErrorCode
end

_H3StreamError(code::UInt64, message::AbstractString) = _H3StreamError(code, String(message), _PROTOCOL_ERROR_GENERIC)

function Base.showerror(io::IO, err::_H3Error)
    print(io, "HTTP/3 error ", _h3_error_name(err.code), ": ", err.message)
    return nothing
end

# Variable-length integers.

const _H3_MAX_VARINT = (UInt64(1) << 62) - 1

function _h3_append_varint!(out::Vector{UInt8}, v::UInt64)::Nothing
    if v < 0x40
        push!(out, UInt8(v))
    elseif v < 0x4000
        push!(out, UInt8(0x40 | (v >> 8)), UInt8(v & 0xff))
    elseif v < 0x40000000
        push!(out, UInt8(0x80 | (v >> 24)), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
    elseif v <= _H3_MAX_VARINT
        push!(out, UInt8(0xc0 | (v >> 56)))
        for shift in 48:-8:0
            push!(out, UInt8((v >> shift) & 0xff))
        end
    else
        throw(ArgumentError("QUIC variable-length integers are below 2^62"))
    end
    return nothing
end

"""
    _h3_decode_varint(bytes, i) -> (value, next_index) or nothing

Decode the integer at `bytes[i]`, or `nothing` when it is cut short.
"""
function _h3_decode_varint(bytes::AbstractVector{UInt8}, i::Int)::Union{Nothing,Tuple{UInt64,Int}}
    i <= length(bytes) || return nothing
    first = bytes[i]
    len = 1 << (first >> 6)
    i + len - 1 <= length(bytes) || return nothing
    v = UInt64(first & 0x3f)
    for k in 1:(len - 1)
        v = (v << 8) | bytes[i + k]
    end
    return v, i + len
end

"""
    _h3_read_varint(io) -> UInt64 or nothing

Read an integer from `io`; `nothing` when `io` ends before it starts.
Ending inside it is H3_FRAME_ERROR.
"""
function _h3_read_varint(io::IO)::Union{Nothing,UInt64}
    eof(io) && return nothing
    first = read(io, UInt8)
    len = 1 << (first >> 6)
    v = UInt64(first & 0x3f)
    for _ in 2:len
        eof(io) && throw(_H3Error(_H3_FRAME_ERROR, "stream ended inside a variable-length integer"))
        v = (v << 8) | read(io, UInt8)
    end
    return v
end

# Frames.

function _h3_append_frame!(out::Vector{UInt8}, type::UInt64, payload::AbstractVector{UInt8})::Nothing
    _h3_append_varint!(out, type)
    _h3_append_varint!(out, UInt64(length(payload)))
    append!(out, payload)
    return nothing
end

_h3_append_frame!(out::Vector{UInt8}, type::Integer, payload::AbstractVector{UInt8}) =
    _h3_append_frame!(out, UInt64(type), payload)

# Reserved frame, stream, and setting types: 0x1f * N + 0x21 (Section 7.2.8).
_h3_is_reserved_type(t::UInt64)::Bool = t >= 0x21 && (t - 0x21) % 0x1f == 0

"""
    _h3_read_frame_header(io) -> (type, length) or nothing

Read a frame's type and length; `nothing` when `io` ends cleanly between
frames.
"""
function _h3_read_frame_header(io::IO)::Union{Nothing,Tuple{UInt64,Int64}}
    type = _h3_read_varint(io)
    type === nothing && return nothing
    len = _h3_read_varint(io)
    len === nothing && throw(_H3Error(_H3_FRAME_ERROR, "stream ended inside a frame header"))
    return type, Int64(len)
end

"""
    _h3_read_payload(io, len, limit) -> Vector{UInt8}

Read a `len`-byte frame payload, refusing one over `limit` bytes with
H3_EXCESSIVE_LOAD.
"""
function _h3_read_payload(io::IO, len::Int64, limit::Int)::Vector{UInt8}
    len <= limit || throw(_H3Error(_H3_EXCESSIVE_LOAD, "HTTP/3 frame of $(len) bytes exceeds the limit of $(limit)"))
    payload = read(io, Int(len))
    length(payload) == len || throw(_H3Error(_H3_FRAME_ERROR, "stream ended inside a frame"))
    return payload
end

function _h3_skip!(io::IO, len::Int64)::Nothing
    remaining = len
    while remaining > 0
        chunk = read(io, Int(min(remaining, 64 * 1024)))
        isempty(chunk) && throw(_H3Error(_H3_FRAME_ERROR, "stream ended inside a frame"))
        remaining -= length(chunk)
    end
    return nothing
end

# SETTINGS and GOAWAY payloads.

function _h3_encode_settings(settings::Vector{Pair{UInt64,UInt64}})::Vector{UInt8}
    out = UInt8[]
    for (id, value) in settings
        _h3_append_varint!(out, id)
        _h3_append_varint!(out, value)
    end
    return out
end

"""
    _h3_decode_settings(payload) -> Vector{Pair{UInt64,UInt64}}

Decode a SETTINGS payload, unknown identifiers included. A repeated
identifier, or one HTTP/2 defined (Section 7.2.4.1), is H3_SETTINGS_ERROR.
"""
function _h3_decode_settings(payload::Vector{UInt8})::Vector{Pair{UInt64,UInt64}}
    settings = Pair{UInt64,UInt64}[]
    i = 1
    while i <= length(payload)
        id_next = _h3_decode_varint(payload, i)
        id_next === nothing && throw(_H3Error(_H3_FRAME_ERROR, "truncated SETTINGS frame"))
        id, i = id_next
        value_next = _h3_decode_varint(payload, i)
        value_next === nothing && throw(_H3Error(_H3_FRAME_ERROR, "truncated SETTINGS frame"))
        value, i = value_next
        0x02 <= id <= 0x05 &&
            throw(_H3Error(_H3_SETTINGS_ERROR, "HTTP/2 setting 0x$(string(id; base=16)) in HTTP/3 SETTINGS"))
        any(p -> p.first == id, settings) &&
            throw(_H3Error(_H3_SETTINGS_ERROR, "setting 0x$(string(id; base=16)) appears twice"))
        push!(settings, id => value)
    end
    return settings
end

function _h3_decode_goaway(payload::Vector{UInt8})::UInt64
    decoded = _h3_decode_varint(payload, 1)
    (decoded === nothing || decoded[2] != length(payload) + 1) &&
        throw(_H3Error(_H3_FRAME_ERROR, "malformed GOAWAY frame"))
    return decoded[1]
end
