# HTTP/2 frame model and frame (read/write) implementation.
const FRAME_DATA = UInt8(0x0)
const FRAME_HEADERS = UInt8(0x1)
const FRAME_PRIORITY = UInt8(0x2)
const FRAME_RST_STREAM = UInt8(0x3)
const FRAME_SETTINGS = UInt8(0x4)
const FRAME_PUSH_PROMISE = UInt8(0x5)
const FRAME_PING = UInt8(0x6)
const FRAME_GOAWAY = UInt8(0x7)
const FRAME_WINDOW_UPDATE = UInt8(0x8)
const FRAME_CONTINUATION = UInt8(0x9)

const FLAG_END_STREAM = UInt8(0x1)
const FLAG_END_HEADERS = UInt8(0x4)
const FLAG_ACK = UInt8(0x1)
const FLAG_PADDED = UInt8(0x8)
const _FLAG_HEADERS_PRIORITY = UInt8(0x20)
const _H2_MAX_FRAME_SIZE = 16_384

# SETTINGS parameter identifier for the per-stream initial receive window
# (RFC 7540 §6.5.2). Used when advertising a non-default flow-control window.
const _H2_SETTINGS_INITIAL_WINDOW_SIZE = UInt16(0x4)

# Protocol-default flow-control window (RFC 7540 §6.9.2) and the default
# per-stream receive buffer cap used when callers do not override them.
const _H2_DEFAULT_WINDOW_SIZE = 65_535
const _H2_DEFAULT_MAX_BUFFERED_BYTES = 256 * 1024

# Maximum legal flow-control window (RFC 7540 §6.9.1): 2^31 - 1.
const _H2_FLOW_CONTROL_MAX_WINDOW = Int64(0x7fff_ffff)

"""
    HTTP2Settings(; initial_window_size=65535, connection_window_size=65535)

HTTP/2 flow-control configuration shared by [`Server`](@ref), [`Client`](@ref),
and `connect_h2!`.

- `initial_window_size`: the per-stream receive window advertised via
  `SETTINGS_INITIAL_WINDOW_SIZE` (RFC 7540 §6.5.2).
- `connection_window_size`: the connection-level receive window. Values above the
  protocol default of 65535 are applied with an initial `WINDOW_UPDATE`.

Both default to the protocol default of 65535, leaving existing behavior
unchanged. Raising them improves single-stream throughput on links with
non-trivial latency, where the default 64 KiB window would otherwise cap a
transfer at roughly `window / RTT`. The per-stream receive buffer cap is derived
from `initial_window_size`, so it does not need to be configured separately.

`initial_window_size` may be set below the default to apply tighter per-stream
backpressure. `connection_window_size` must be at least the protocol default of
65535: the connection-level window starts at that value and can only be enlarged
with a `WINDOW_UPDATE`, so a smaller value cannot be advertised.
"""
struct HTTP2Settings
    initial_window_size::Int
    connection_window_size::Int
end

function HTTP2Settings(;
    initial_window_size::Integer=_H2_DEFAULT_WINDOW_SIZE,
    connection_window_size::Integer=_H2_DEFAULT_WINDOW_SIZE,
)
    1 <= initial_window_size <= _H2_FLOW_CONTROL_MAX_WINDOW ||
        throw(ArgumentError("initial_window_size must be in 1..$(_H2_FLOW_CONTROL_MAX_WINDOW)"))
    # The connection-level window starts at the protocol default and can only be
    # enlarged with a WINDOW_UPDATE, so it cannot be advertised below the default.
    _H2_DEFAULT_WINDOW_SIZE <= connection_window_size <= _H2_FLOW_CONTROL_MAX_WINDOW ||
        throw(ArgumentError("connection_window_size must be in $(_H2_DEFAULT_WINDOW_SIZE)..$(_H2_FLOW_CONTROL_MAX_WINDOW)"))
    return HTTP2Settings(Int(initial_window_size), Int(connection_window_size))
end

# Per-stream receive buffer cap derived from the advertised window. The buffer
# must hold a full advertised window before the application reads it (a peer may
# send up to the advertised window before the handler consumes any bytes), so it
# is the larger of the configured window and the default cap. This mirrors how
# `_h2_max_header_block_bytes` derives an internal limit rather than exposing it.
_h2_buffered_bytes(settings::HTTP2Settings) =
    max(settings.initial_window_size, _H2_DEFAULT_MAX_BUFFERED_BYTES)

"""
    FrameHeader

Generic HTTP/2 frame header (9-byte wire prefix).
"""
struct FrameHeader
    length::Int
    type::UInt8
    flags::UInt8
    stream_id::UInt32
end

"""
    AbstractFrame

Abstract supertype for concrete HTTP/2 wire frame representations.
"""
abstract type AbstractFrame end

struct DataFrame <: AbstractFrame
    stream_id::UInt32
    end_stream::Bool
    data::Vector{UInt8}
end

struct HeadersFrame <: AbstractFrame
    stream_id::UInt32
    end_stream::Bool
    end_headers::Bool
    header_block_fragment::Vector{UInt8}
end

struct PriorityFrame <: AbstractFrame
    stream_id::UInt32
    exclusive::Bool
    stream_dependency::UInt32
    weight::UInt8
end

struct RSTStreamFrame <: AbstractFrame
    stream_id::UInt32
    error_code::UInt32
end

struct SettingsFrame <: AbstractFrame
    ack::Bool
    settings::Vector{Pair{UInt16,UInt32}}
end

struct PushPromiseFrame <: AbstractFrame
    stream_id::UInt32
    promised_stream_id::UInt32
    end_headers::Bool
    header_block_fragment::Vector{UInt8}
end

struct PingFrame <: AbstractFrame
    ack::Bool
    opaque_data::NTuple{8,UInt8}
end

struct GoAwayFrame <: AbstractFrame
    last_stream_id::UInt32
    error_code::UInt32
    debug_data::Vector{UInt8}
end

struct WindowUpdateFrame <: AbstractFrame
    stream_id::UInt32
    window_size_increment::UInt32
end

struct ContinuationFrame <: AbstractFrame
    stream_id::UInt32
    end_headers::Bool
    header_block_fragment::Vector{UInt8}
end

struct UnknownFrame <: AbstractFrame
    header::FrameHeader
    payload::Vector{UInt8}
end

@inline function _read_exact_bytes!(io::IO, n::Int)::Vector{UInt8}
    n >= 0 || throw(ArgumentError("n must be >= 0"))
    n == 0 && return UInt8[]
    bytes = Vector{UInt8}(undef, n)
    readbytes = readbytes!(io, bytes, n)
    readbytes == n || throw(ParseError("unexpected EOF while reading HTTP/2 frame payload"))
    return bytes
end

@inline function _read_u32_be(bytes::Vector{UInt8}, index::Int)::UInt32
    return (UInt32(bytes[index]) << 24) |
           (UInt32(bytes[index+1]) << 16) |
           (UInt32(bytes[index+2]) << 8) |
           UInt32(bytes[index+3])
end

@inline function _write_u32_be!(out::Vector{UInt8}, value::UInt32)
    push!(out, UInt8((value >> 24) & 0xff))
    push!(out, UInt8((value >> 16) & 0xff))
    push!(out, UInt8((value >> 8) & 0xff))
    push!(out, UInt8(value & 0xff))
    return nothing
end

@inline function _encode_header_bytes(header::FrameHeader)::Vector{UInt8}
    header.length < 0 && throw(ArgumentError("HTTP/2 frame length must be >= 0"))
    header.length <= 0x00ff_ffff || throw(ArgumentError("HTTP/2 frame length must fit 24 bits"))
    bytes = UInt8[]
    push!(bytes, UInt8((header.length >> 16) & 0xff))
    push!(bytes, UInt8((header.length >> 8) & 0xff))
    push!(bytes, UInt8(header.length & 0xff))
    push!(bytes, header.type)
    push!(bytes, header.flags)
    _write_u32_be!(bytes, header.stream_id & 0x7fff_ffff)
    return bytes
end

function _read_frame_header!(io::IO)::FrameHeader
    header_bytes = _read_exact_bytes!(io, 9)
    length = (Int(header_bytes[1]) << 16) | (Int(header_bytes[2]) << 8) | Int(header_bytes[3])
    ftype = header_bytes[4]
    flags = header_bytes[5]
    stream_id = _read_u32_be(header_bytes, 6) & 0x7fff_ffff
    return FrameHeader(length, ftype, flags, stream_id)
end

function _parse_settings_payload(payload::Vector{UInt8})::Vector{Pair{UInt16,UInt32}}
    (length(payload) % 6 == 0) || throw(ParseError("HTTP/2 SETTINGS payload length must be a multiple of 6"))
    settings = Pair{UInt16,UInt32}[]
    index = 1
    while index <= length(payload)
        id = (UInt16(payload[index]) << 8) | UInt16(payload[index+1])
        value = _read_u32_be(payload, index + 2)
        push!(settings, id => value)
        index += 6
    end
    return settings
end

function _serialize_settings_payload(settings::Vector{Pair{UInt16,UInt32}})::Vector{UInt8}
    payload = UInt8[]
    for setting in settings
        id = setting.first
        value = setting.second
        push!(payload, UInt8((id >> 8) & 0xff))
        push!(payload, UInt8(id & 0xff))
        _write_u32_be!(payload, value)
    end
    return payload
end

function _split_padded_payload(payload::Vector{UInt8}, frame_name::AbstractString)::Tuple{Vector{UInt8},Int}
    isempty(payload) && throw(ParseError("HTTP/2 $(frame_name) padded payload must include pad length"))
    pad_length = Int(payload[1])
    1 + pad_length <= length(payload) || throw(ParseError("HTTP/2 $(frame_name) padding exceeds payload length"))
    data_end = length(payload) - pad_length
    return copy(@view(payload[2:data_end])), pad_length
end

function _parse_headers_fragment(payload::Vector{UInt8}, flags::UInt8)::Vector{UInt8}
    working = payload
    if (flags & FLAG_PADDED) != 0
        working, _ = _split_padded_payload(working, "HEADERS")
    end
    if (flags & _FLAG_HEADERS_PRIORITY) != 0
        length(working) >= 5 || throw(ParseError("HTTP/2 HEADERS priority payload must be at least 5 bytes"))
        return copy(@view(working[6:end]))
    end
    return working
end

function _parse_push_promise_payload(payload::Vector{UInt8}, flags::UInt8)::Tuple{UInt32,Vector{UInt8}}
    working = payload
    if (flags & FLAG_PADDED) != 0
        working, _ = _split_padded_payload(working, "PUSH_PROMISE")
    end
    length(working) >= 4 || throw(ParseError("HTTP/2 PUSH_PROMISE frame payload must be >= 4 bytes"))
    promised = _read_u32_be(working, 1) & 0x7fff_ffff
    fragment = length(working) == 4 ? UInt8[] : copy(@view(working[5:end]))
    return promised, fragment
end

@inline function _require_zero_stream_id(stream_id::UInt32, frame_name::AbstractString)
    stream_id == UInt32(0) || throw(ProtocolError("HTTP/2 $(frame_name) stream id must be zero"))
    return nothing
end

@inline function _require_nonzero_stream_id(stream_id::UInt32, frame_name::AbstractString)
    stream_id != UInt32(0) || throw(ProtocolError("HTTP/2 $(frame_name) stream id must be non-zero"))
    return nothing
end

"""
    read_frame!(io)

Read and decode one HTTP/2 frame from `io`.

Returns a concrete `AbstractFrame` subtype.

Throws:
- `ParseError` for malformed wire payloads
- `ProtocolError` for locally enforced invariants such as frame-size overflow
- `EOFError` or other I/O exceptions from the underlying stream
"""
function read_frame!(io::IO)::AbstractFrame
    header = _read_frame_header!(io)
    header.length <= _H2_MAX_FRAME_SIZE || throw(ProtocolError("HTTP/2 frame exceeds max_frame_size"))
    payload = _read_exact_bytes!(io, header.length)
    # This function intentionally validates only frame-local invariants. Stream-
    # level rules such as "HEADERS must precede DATA" live in the client/server
    # state machines above the framer.
    if header.type == FRAME_DATA
        _require_nonzero_stream_id(header.stream_id, "DATA")
        data = if (header.flags & FLAG_PADDED) != 0
            stripped, _ = _split_padded_payload(payload, "DATA")
            stripped
        else
            payload
        end
        return DataFrame(header.stream_id, (header.flags & FLAG_END_STREAM) != 0, data)
    end
    if header.type == FRAME_HEADERS
        _require_nonzero_stream_id(header.stream_id, "HEADERS")
        return HeadersFrame(
            header.stream_id,
            (header.flags & FLAG_END_STREAM) != 0,
            (header.flags & FLAG_END_HEADERS) != 0,
            _parse_headers_fragment(payload, header.flags),
        )
    end
    if header.type == FRAME_PRIORITY
        _require_nonzero_stream_id(header.stream_id, "PRIORITY")
        length(payload) == 5 || throw(ParseError("HTTP/2 PRIORITY frame payload must be 5 bytes"))
        dep = _read_u32_be(payload, 1)
        exclusive = (dep & 0x8000_0000) != 0
        stream_dependency = dep & 0x7fff_ffff
        weight = payload[5]
        return PriorityFrame(header.stream_id, exclusive, stream_dependency, weight)
    end
    if header.type == FRAME_RST_STREAM
        _require_nonzero_stream_id(header.stream_id, "RST_STREAM")
        length(payload) == 4 || throw(ParseError("HTTP/2 RST_STREAM frame payload must be 4 bytes"))
        return RSTStreamFrame(header.stream_id, _read_u32_be(payload, 1))
    end
    if header.type == FRAME_SETTINGS
        _require_zero_stream_id(header.stream_id, "SETTINGS")
        if (header.flags & FLAG_ACK) != 0
            isempty(payload) || throw(ParseError("HTTP/2 SETTINGS ACK frame must have empty payload"))
            return SettingsFrame(true, Pair{UInt16,UInt32}[])
        end
        return SettingsFrame(false, _parse_settings_payload(payload))
    end
    if header.type == FRAME_PUSH_PROMISE
        _require_nonzero_stream_id(header.stream_id, "PUSH_PROMISE")
        promised, fragment = _parse_push_promise_payload(payload, header.flags)
        promised != UInt32(0) || throw(ProtocolError("HTTP/2 PUSH_PROMISE promised stream id must be non-zero"))
        return PushPromiseFrame(header.stream_id, promised, (header.flags & FLAG_END_HEADERS) != 0, fragment)
    end
    if header.type == FRAME_PING
        _require_zero_stream_id(header.stream_id, "PING")
        length(payload) == 8 || throw(ParseError("HTTP/2 PING frame payload must be 8 bytes"))
        return PingFrame((header.flags & FLAG_ACK) != 0, ntuple(i -> payload[i], 8))
    end
    if header.type == FRAME_GOAWAY
        _require_zero_stream_id(header.stream_id, "GOAWAY")
        length(payload) >= 8 || throw(ParseError("HTTP/2 GOAWAY frame payload must be >= 8 bytes"))
        last_stream_id = _read_u32_be(payload, 1) & 0x7fff_ffff
        error_code = _read_u32_be(payload, 5)
        debug_data = payload[9:end]
        return GoAwayFrame(last_stream_id, error_code, debug_data)
    end
    if header.type == FRAME_WINDOW_UPDATE
        length(payload) == 4 || throw(ParseError("HTTP/2 WINDOW_UPDATE frame payload must be 4 bytes"))
        increment = _read_u32_be(payload, 1) & 0x7fff_ffff
        increment == 0 && throw(ProtocolError("HTTP/2 WINDOW_UPDATE increment must be > 0"))
        return WindowUpdateFrame(header.stream_id, increment)
    end
    if header.type == FRAME_CONTINUATION
        _require_nonzero_stream_id(header.stream_id, "CONTINUATION")
        return ContinuationFrame(header.stream_id, (header.flags & FLAG_END_HEADERS) != 0, payload)
    end
    return UnknownFrame(header, payload)
end

@inline function _serialize_frame(frame::AbstractFrame)::Tuple{FrameHeader,Vector{UInt8}}
    @nospecialize frame
    if frame isa DataFrame
        f = frame::DataFrame
        _require_nonzero_stream_id(f.stream_id, "DATA")
        flags = f.end_stream ? FLAG_END_STREAM : UInt8(0)
        payload = copy(f.data)
        return FrameHeader(length(payload), FRAME_DATA, flags, f.stream_id), payload
    end
    if frame isa HeadersFrame
        f = frame::HeadersFrame
        _require_nonzero_stream_id(f.stream_id, "HEADERS")
        flags = UInt8(0)
        f.end_stream && (flags |= FLAG_END_STREAM)
        f.end_headers && (flags |= FLAG_END_HEADERS)
        payload = copy(f.header_block_fragment)
        return FrameHeader(length(payload), FRAME_HEADERS, flags, f.stream_id), payload
    end
    if frame isa PriorityFrame
        f = frame::PriorityFrame
        _require_nonzero_stream_id(f.stream_id, "PRIORITY")
        dep = f.stream_dependency & 0x7fff_ffff
        f.exclusive && (dep |= 0x8000_0000)
        payload = UInt8[]
        _write_u32_be!(payload, dep)
        push!(payload, f.weight)
        return FrameHeader(length(payload), FRAME_PRIORITY, UInt8(0), f.stream_id), payload
    end
    if frame isa RSTStreamFrame
        f = frame::RSTStreamFrame
        _require_nonzero_stream_id(f.stream_id, "RST_STREAM")
        payload = UInt8[]
        _write_u32_be!(payload, f.error_code)
        return FrameHeader(length(payload), FRAME_RST_STREAM, UInt8(0), f.stream_id), payload
    end
    if frame isa SettingsFrame
        f = frame::SettingsFrame
        flags = f.ack ? FLAG_ACK : UInt8(0)
        payload = f.ack ? UInt8[] : _serialize_settings_payload(f.settings)
        return FrameHeader(length(payload), FRAME_SETTINGS, flags, UInt32(0)), payload
    end
    if frame isa PushPromiseFrame
        f = frame::PushPromiseFrame
        _require_nonzero_stream_id(f.stream_id, "PUSH_PROMISE")
        f.promised_stream_id != UInt32(0) || throw(ProtocolError("HTTP/2 PUSH_PROMISE promised stream id must be non-zero"))
        flags = f.end_headers ? FLAG_END_HEADERS : UInt8(0)
        payload = UInt8[]
        _write_u32_be!(payload, f.promised_stream_id & 0x7fff_ffff)
        append!(payload, f.header_block_fragment)
        return FrameHeader(length(payload), FRAME_PUSH_PROMISE, flags, f.stream_id), payload
    end
    if frame isa PingFrame
        f = frame::PingFrame
        flags = f.ack ? FLAG_ACK : UInt8(0)
        payload = UInt8[f.opaque_data...]
        return FrameHeader(8, FRAME_PING, flags, UInt32(0)), payload
    end
    if frame isa GoAwayFrame
        f = frame::GoAwayFrame
        payload = UInt8[]
        _write_u32_be!(payload, f.last_stream_id & 0x7fff_ffff)
        _write_u32_be!(payload, f.error_code)
        append!(payload, f.debug_data)
        return FrameHeader(length(payload), FRAME_GOAWAY, UInt8(0), UInt32(0)), payload
    end
    if frame isa WindowUpdateFrame
        f = frame::WindowUpdateFrame
        f.window_size_increment > 0 || throw(ProtocolError("HTTP/2 WINDOW_UPDATE increment must be > 0"))
        payload = UInt8[]
        _write_u32_be!(payload, f.window_size_increment & 0x7fff_ffff)
        return FrameHeader(4, FRAME_WINDOW_UPDATE, UInt8(0), f.stream_id), payload
    end
    if frame isa ContinuationFrame
        f = frame::ContinuationFrame
        _require_nonzero_stream_id(f.stream_id, "CONTINUATION")
        flags = f.end_headers ? FLAG_END_HEADERS : UInt8(0)
        payload = copy(f.header_block_fragment)
        return FrameHeader(length(payload), FRAME_CONTINUATION, flags, f.stream_id), payload
    end
    if frame isa UnknownFrame
        f = frame::UnknownFrame
        return f.header, copy(f.payload)
    end
    throw(ArgumentError("unsupported HTTP/2 frame type"))
end

"""
    write_frame!(io, frame)

Serialize and write one HTTP/2 frame to `io`.

Returns `nothing`. Throws `ProtocolError` or `ArgumentError` for frames that
cannot be represented legally, plus any exception raised by the underlying
`IO`.
"""
function write_frame!(io::IO, frame::AbstractFrame)
    header, payload = _serialize_frame(frame)
    header.length <= _H2_MAX_FRAME_SIZE || throw(ProtocolError("HTTP/2 frame exceeds max_frame_size"))
    write(io, _encode_header_bytes(header))
    isempty(payload) || write(io, payload)
    return nothing
end

function _header_block_frames(
    f::F,
    stream_id::UInt32,
    end_stream::Bool,
    header_block::Vector{UInt8},
    max_frame_size::Integer,
)::Nothing where {F}
    max_frame_size > 0 || throw(ArgumentError("max_frame_size must be > 0"))
    total = length(header_block)
    if total <= max_frame_size
        f(HeadersFrame(stream_id, end_stream, true, copy(header_block)))
        return nothing
    end
    offset = 1
    chunk_len = min(total, Int(max_frame_size))
    first_fragment = Vector{UInt8}(undef, chunk_len)
    copyto!(first_fragment, 1, header_block, offset, chunk_len)
    f(HeadersFrame(stream_id, end_stream, false, first_fragment))
    offset += chunk_len
    while offset <= total
        chunk_len = min(total - offset + 1, Int(max_frame_size))
        fragment = Vector{UInt8}(undef, chunk_len)
        copyto!(fragment, 1, header_block, offset, chunk_len)
        offset += chunk_len
        f(ContinuationFrame(stream_id, offset > total, fragment))
    end
    return nothing
end
