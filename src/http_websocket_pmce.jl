# WebSocket permessage-deflate (RFC 7692).
#
# Per-message DEFLATE compression for WebSocket data frames. The wire format is
# raw DEFLATE (RFC 1951, no zlib/gzip wrapper) terminated with a Z_SYNC_FLUSH
# whose trailing empty block (0x00 0x00 0xff 0xff) is stripped by the sender and
# re-appended by the receiver (RFC 7692 §7.2). The DEFLATE sliding window may be
# carried across messages ("context takeover") or reset per message
# ("no_context_takeover"), per the negotiated parameters.
#
# We drive zlib directly (Zlib_jll): the high-level CodecZlib transcode API
# cannot express Z_SYNC_FLUSH and force-resets the window on every call, neither
# of which is compatible with RFC 7692.

using Zlib_jll: libz

# z_stream, mirroring zlib's layout (see zlib.h). Field order/types are ABI; a
# round-trip test guards against drift.
mutable struct _ZStream
    next_in::Ptr{UInt8}
    avail_in::Cuint
    total_in::Culong
    next_out::Ptr{UInt8}
    avail_out::Cuint
    total_out::Culong
    msg::Ptr{UInt8}
    state::Ptr{Cvoid}
    zalloc::Ptr{Cvoid}
    zfree::Ptr{Cvoid}
    opaque::Ptr{Cvoid}
    data_type::Cint
    adler::Culong
    reserved::Culong
end
_ZStream() = _ZStream(C_NULL, 0, 0, C_NULL, 0, 0, C_NULL, C_NULL, C_NULL, C_NULL, C_NULL, 0, 0, 0)

const _Z_OK = Cint(0)
const _Z_STREAM_END = Cint(1)
const _Z_BUF_ERROR = Cint(-5)
const _Z_NO_FLUSH = Cint(0)
const _Z_SYNC_FLUSH = Cint(2)
const _Z_DEFLATED = Cint(8)
const _PMCE_TRAILER = UInt8[0x00, 0x00, 0xff, 0xff]

_zlib_version() = unsafe_string(ccall((:zlibVersion, libz), Ptr{UInt8}, ()))

# Negative windowBits selects raw DEFLATE (no header/checksum), exactly what
# RFC 7692 requires. memLevel 8 / strategy 0 are zlib defaults.
_deflate_init!(z::_ZStream, level::Integer, windowbits::Integer) =
    ccall((:deflateInit2_, libz), Cint,
        (Ref{_ZStream}, Cint, Cint, Cint, Cint, Cint, Cstring, Cint),
        z, level, _Z_DEFLATED, -windowbits, 8, 0, _zlib_version(), sizeof(_ZStream))
_deflate!(z::_ZStream, flush::Integer) = ccall((:deflate, libz), Cint, (Ref{_ZStream}, Cint), z, flush)
_deflate_reset!(z::_ZStream) = ccall((:deflateReset, libz), Cint, (Ref{_ZStream},), z)
_deflate_end!(z::_ZStream) = ccall((:deflateEnd, libz), Cint, (Ref{_ZStream},), z)
_inflate_init!(z::_ZStream, windowbits::Integer) =
    ccall((:inflateInit2_, libz), Cint, (Ref{_ZStream}, Cint, Cstring, Cint),
        z, -windowbits, _zlib_version(), sizeof(_ZStream))
_inflate!(z::_ZStream, flush::Integer) = ccall((:inflate, libz), Cint, (Ref{_ZStream}, Cint), z, flush)
_inflate_reset!(z::_ZStream) = ccall((:inflateReset, libz), Cint, (Ref{_ZStream},), z)
_inflate_end!(z::_ZStream) = ccall((:inflateEnd, libz), Cint, (Ref{_ZStream},), z)

# Negotiated permessage-deflate parameters (RFC 7692 §7.1). Window bits are the
# zlib-usable range 9..15 (a peer offering 8 is rejected during negotiation).
struct PMCEParams
    server_no_context_takeover::Bool
    client_no_context_takeover::Bool
    server_max_window_bits::Int
    client_max_window_bits::Int
end

# Per-connection compression state. `deflater` compresses our outgoing messages,
# `inflater` decompresses the peer's. `*_no_takeover` reset the corresponding
# window after each message. Decompression always uses a 15-bit window (a
# superset of any window the peer may have used), so only the deflater honors a
# negotiated window-bits limit.
mutable struct PMCEContext
    deflater::_ZStream
    inflater::_ZStream
    deflate_no_takeover::Bool
    inflate_no_takeover::Bool
end

function PMCEContext(params::PMCEParams, is_client::Bool)
    deflate_bits = is_client ? params.client_max_window_bits : params.server_max_window_bits
    deflate_no_takeover = is_client ? params.client_no_context_takeover : params.server_no_context_takeover
    inflate_no_takeover = is_client ? params.server_no_context_takeover : params.client_no_context_takeover
    deflater = _ZStream()
    _deflate_init!(deflater, -1, deflate_bits) == _Z_OK || error("permessage-deflate: deflateInit2 failed")
    inflater = _ZStream()
    _inflate_init!(inflater, 15) == _Z_OK || begin
        _deflate_end!(deflater)
        error("permessage-deflate: inflateInit2 failed")
    end
    ctx = PMCEContext(deflater, inflater, deflate_no_takeover, inflate_no_takeover)
    finalizer(_pmce_close!, ctx)
    return ctx
end

function _pmce_close!(ctx::PMCEContext)
    _deflate_end!(ctx.deflater)
    _inflate_end!(ctx.inflater)
    return nothing
end

# Compress one message: DEFLATE + Z_SYNC_FLUSH, then strip the 0x00 0x00 0xff
# 0xff tail. An empty payload (or one whose flush emits nothing) is transmitted
# as a single 0x00 byte (RFC 7692 §7.2.3.6).
function pmce_compress!(ctx::PMCEContext, payload::AbstractVector{UInt8})::Vector{UInt8}
    z = ctx.deflater
    out = UInt8[]
    inbuf = payload isa Vector{UInt8} ? payload : collect(payload)
    buf = Vector{UInt8}(undef, max(64, length(inbuf) + 64))
    GC.@preserve inbuf buf begin
        z.next_in = pointer(inbuf)
        z.avail_in = length(inbuf) % Cuint
        while true
            z.next_out = pointer(buf)
            z.avail_out = length(buf) % Cuint
            _deflate!(z, _Z_SYNC_FLUSH) == Cint(-2) && error("permessage-deflate: deflate stream error")
            produced = length(buf) - Int(z.avail_out)
            produced > 0 && append!(out, @view buf[1:produced])
            z.avail_out != 0 && break
        end
    end
    if length(out) >= 4 && @view(out[end-3:end]) == _PMCE_TRAILER
        resize!(out, length(out) - 4)
    end
    ctx.deflate_no_takeover && _deflate_reset!(z)
    return isempty(out) ? UInt8[0x00] : out
end

# Decompress one message: re-append the 0x00 0x00 0xff 0xff tail and INFLATE.
# `max_size` bounds the inflated output to guard against decompression bombs
# (a tiny compressed frame can inflate to gigabytes). Throws a
# WebSocketProtocolError on malformed input or on exceeding `max_size`; the
# caller maps that to a protocol close.
function pmce_decompress!(ctx::PMCEContext, payload::AbstractVector{UInt8}; max_size::Int=typemax(Int))::Vector{UInt8}
    z = ctx.inflater
    input = Vector{UInt8}(undef, length(payload) + 4)
    @inbounds for i in eachindex(payload)
        input[i] = payload[i]
    end
    @inbounds for i in 1:4
        input[length(payload)+i] = _PMCE_TRAILER[i]
    end
    out = UInt8[]
    buf = Vector{UInt8}(undef, max(256, 4 * length(input) + 256))
    GC.@preserve input buf begin
        z.next_in = pointer(input)
        z.avail_in = length(input) % Cuint
        while true
            z.next_out = pointer(buf)
            z.avail_out = length(buf) % Cuint
            code = _inflate!(z, _Z_SYNC_FLUSH)
            (code == _Z_OK || code == _Z_BUF_ERROR || code == _Z_STREAM_END) ||
                throw(WebSocketProtocolError("permessage-deflate: invalid compressed data"))
            produced = length(buf) - Int(z.avail_out)
            if produced > 0
                length(out) + produced > max_size &&
                    throw(WebSocketProtocolError("permessage-deflate: decompressed message exceeds maximum"))
                append!(out, @view buf[1:produced])
            end
            (z.avail_in == 0 && z.avail_out != 0) && break
            code == _Z_BUF_ERROR && break
        end
    end
    ctx.inflate_no_takeover && _inflate_reset!(z)
    return out
end

# ── extension-header negotiation (RFC 7692 §7.1, §9) ─────────────────────────

# Parse a Sec-WebSocket-Extensions value into [(name, params)] where params maps
# each parameter to its value (or "" for valueless flags). Tolerant of OWS.
function _pmce_parse_extension_header(value::AbstractString)::Vector{Tuple{String,Dict{String,String}}}
    offers = Tuple{String,Dict{String,String}}[]
    for offer in eachsplit(value, ',')
        parts = collect(eachsplit(offer, ';'))
        isempty(parts) && continue
        name = strip(parts[1])
        isempty(name) && continue
        params = Dict{String,String}()
        for p in @view parts[2:end]
            kv = split(strip(p), '='; limit=2)
            key = strip(kv[1])
            isempty(key) && continue
            params[lowercase(String(key))] = length(kv) == 2 ? strip(kv[2], ['"', ' ']) : ""
        end
        push!(offers, (lowercase(String(name)), params))
    end
    return offers
end

_pmce_parse_window_bits(s::AbstractString)::Union{Nothing,Int} = begin
    n = tryparse(Int, s)
    (n === nothing || n < 8 || n > 15) ? nothing : n
end

# Client offer string. The default (`permessage-deflate; client_max_window_bits`)
# matches what browsers send: context takeover both ways, default windows, and a
# signal that the server may cap our window.
function _pmce_client_offer_header(;
    server_no_context_takeover::Bool=false,
    client_no_context_takeover::Bool=false,
    server_max_window_bits::Union{Nothing,Int}=nothing,
    client_max_window_bits::Union{Nothing,Int}=15,
)::String
    io = IOBuffer()
    print(io, "permessage-deflate")
    server_no_context_takeover && print(io, "; server_no_context_takeover")
    client_no_context_takeover && print(io, "; client_no_context_takeover")
    server_max_window_bits === nothing || print(io, "; server_max_window_bits=", server_max_window_bits)
    # offered valueless so the server may pick a cap up to 15
    client_max_window_bits === nothing || print(io, "; client_max_window_bits")
    return String(take!(io))
end

# Server side: choose a permessage-deflate offer to accept. Returns the
# negotiated params plus the response header to echo, or nothing to decline.
function _pmce_server_negotiate(request_header::Union{Nothing,AbstractString})::Union{Nothing,Tuple{PMCEParams,String}}
    request_header === nothing && return nothing
    for (name, params) in _pmce_parse_extension_header(request_header)
        name == "permessage-deflate" || continue
        # reject offers carrying unknown parameters (RFC 7692 §7.1)
        all(k -> k in ("server_no_context_takeover", "client_no_context_takeover",
                       "server_max_window_bits", "client_max_window_bits"), keys(params)) || continue
        s_now = haskey(params, "server_no_context_takeover")
        c_now = haskey(params, "client_no_context_takeover")
        # window bits: a valueless client_max_window_bits is the client signalling
        # support; an explicit value constrains the relevant window.
        s_bits = 15
        if haskey(params, "server_max_window_bits")
            b = _pmce_parse_window_bits(params["server_max_window_bits"])
            (b === nothing || b < 9) && continue   # 8 is unsupported by zlib deflate
            s_bits = b
        end
        c_bits = 15
        if haskey(params, "client_max_window_bits") && !isempty(params["client_max_window_bits"])
            b = _pmce_parse_window_bits(params["client_max_window_bits"])
            (b === nothing || b < 9) && continue
            c_bits = b
        end
        accepted = PMCEParams(s_now, c_now, s_bits, c_bits)
        io = IOBuffer()
        print(io, "permessage-deflate")
        s_now && print(io, "; server_no_context_takeover")
        c_now && print(io, "; client_no_context_takeover")
        s_bits == 15 || print(io, "; server_max_window_bits=", s_bits)
        c_bits == 15 || print(io, "; client_max_window_bits=", c_bits)
        return accepted, String(take!(io))
    end
    return nothing
end

# Client side: interpret the server's accepted permessage-deflate response.
# Returns the negotiated params, or throws if the server's response is malformed
# or includes a parameter we cannot satisfy (the connection must then fail).
function _pmce_client_accept(response_header::Union{Nothing,AbstractString})::Union{Nothing,PMCEParams}
    response_header === nothing && return nothing
    offers = _pmce_parse_extension_header(response_header)
    isempty(offers) && return nothing
    pmce = filter(o -> o[1] == "permessage-deflate", offers)
    isempty(pmce) && throw(WebSocketProtocolError("server accepted an unsupported websocket extension"))
    length(pmce) == 1 || throw(WebSocketProtocolError("server accepted permessage-deflate more than once"))
    params = pmce[1][2]
    all(k -> k in ("server_no_context_takeover", "client_no_context_takeover",
                   "server_max_window_bits", "client_max_window_bits"), keys(params)) ||
        throw(WebSocketProtocolError("server sent an unknown permessage-deflate parameter"))
    s_bits = 15
    if haskey(params, "server_max_window_bits")
        b = _pmce_parse_window_bits(params["server_max_window_bits"])
        (b === nothing || b < 9) && throw(WebSocketProtocolError("invalid server_max_window_bits"))
        s_bits = b
    end
    c_bits = 15
    if haskey(params, "client_max_window_bits")
        if !isempty(params["client_max_window_bits"])
            b = _pmce_parse_window_bits(params["client_max_window_bits"])
            (b === nothing || b < 9) && throw(WebSocketProtocolError("invalid client_max_window_bits"))
            c_bits = b
        end
    end
    return PMCEParams(
        haskey(params, "server_no_context_takeover"),
        haskey(params, "client_no_context_takeover"),
        s_bits, c_bits,
    )
end

# Server convenience used by both the upgrade-response builder (to echo the
# accepted header) and the session (to build the context): returns the
# negotiated params + response header, or nothing when compression is disabled
# or no offer is acceptable. Deterministic, so the two callers can invoke it
# independently rather than threading state through the Response.
function _pmce_negotiate_for_request(request_header::Union{Nothing,AbstractString}, compress::Bool)::Union{Nothing,Tuple{PMCEParams,String}}
    compress || return nothing
    return _pmce_server_negotiate(request_header)
end
