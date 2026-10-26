# QPACK field section coding for HTTP/3 (RFC 9204), with the static table
# only. HTTP/3 connections here advertise a dynamic table capacity of 0, so
# the encoder never inserts into a dynamic table and the decoder treats a
# reference to one as an error (Section 2.2.3). That needs no encoder or
# decoder stream state and is fully interoperable. Integers and Huffman
# strings use the HPACK primitives in hpack.jl, with QPACK's prefixes.

# Appendix A, indexed from 0 on the wire.
const _QPACK_STATIC_TABLE = Tuple{String,String}[
    (":authority", ""),
    (":path", "/"),
    ("age", "0"),
    ("content-disposition", ""),
    ("content-length", "0"),
    ("cookie", ""),
    ("date", ""),
    ("etag", ""),
    ("if-modified-since", ""),
    ("if-none-match", ""),
    ("last-modified", ""),
    ("link", ""),
    ("location", ""),
    ("referer", ""),
    ("set-cookie", ""),
    (":method", "CONNECT"),
    (":method", "DELETE"),
    (":method", "GET"),
    (":method", "HEAD"),
    (":method", "OPTIONS"),
    (":method", "POST"),
    (":method", "PUT"),
    (":scheme", "http"),
    (":scheme", "https"),
    (":status", "103"),
    (":status", "200"),
    (":status", "304"),
    (":status", "404"),
    (":status", "503"),
    ("accept", "*/*"),
    ("accept", "application/dns-message"),
    ("accept-encoding", "gzip, deflate, br"),
    ("accept-ranges", "bytes"),
    ("access-control-allow-headers", "cache-control"),
    ("access-control-allow-headers", "content-type"),
    ("access-control-allow-origin", "*"),
    ("cache-control", "max-age=0"),
    ("cache-control", "max-age=2592000"),
    ("cache-control", "max-age=604800"),
    ("cache-control", "no-cache"),
    ("cache-control", "no-store"),
    ("cache-control", "public, max-age=31536000"),
    ("content-encoding", "br"),
    ("content-encoding", "gzip"),
    ("content-type", "application/dns-message"),
    ("content-type", "application/javascript"),
    ("content-type", "application/json"),
    ("content-type", "application/x-www-form-urlencoded"),
    ("content-type", "image/gif"),
    ("content-type", "image/jpeg"),
    ("content-type", "image/png"),
    ("content-type", "text/css"),
    ("content-type", "text/html; charset=utf-8"),
    ("content-type", "text/plain"),
    ("content-type", "text/plain;charset=utf-8"),
    ("range", "bytes=0-"),
    ("strict-transport-security", "max-age=31536000"),
    ("strict-transport-security", "max-age=31536000; includesubdomains"),
    ("strict-transport-security", "max-age=31536000; includesubdomains; preload"),
    ("vary", "accept-encoding"),
    ("vary", "origin"),
    ("x-content-type-options", "nosniff"),
    ("x-xss-protection", "1; mode=block"),
    (":status", "100"),
    (":status", "204"),
    (":status", "206"),
    (":status", "302"),
    (":status", "400"),
    (":status", "403"),
    (":status", "421"),
    (":status", "425"),
    (":status", "500"),
    ("accept-language", ""),
    ("access-control-allow-credentials", "FALSE"),
    ("access-control-allow-credentials", "TRUE"),
    ("access-control-allow-headers", "*"),
    ("access-control-allow-methods", "get"),
    ("access-control-allow-methods", "get, post, options"),
    ("access-control-allow-methods", "options"),
    ("access-control-expose-headers", "content-length"),
    ("access-control-request-headers", "content-type"),
    ("access-control-request-method", "get"),
    ("access-control-request-method", "post"),
    ("alt-svc", "clear"),
    ("authorization", ""),
    ("content-security-policy", "script-src 'none'; object-src 'none'; base-uri 'none'"),
    ("early-data", "1"),
    ("expect-ct", ""),
    ("forwarded", ""),
    ("if-range", ""),
    ("origin", ""),
    ("purpose", "prefetch"),
    ("server", ""),
    ("timing-allow-origin", "*"),
    ("upgrade-insecure-requests", "1"),
    ("user-agent", ""),
    ("x-forwarded-for", ""),
    ("x-frame-options", "deny"),
    ("x-frame-options", "sameorigin"),
]

const _QPACK_STATIC_EXACT = let
    d = Dict{Tuple{String,String},Int}()
    for (i, entry) in enumerate(_QPACK_STATIC_TABLE)
        haskey(d, entry) || (d[entry] = i - 1)
    end
    d
end

const _QPACK_STATIC_NAME = let
    d = Dict{String,Int}()
    for (i, (name, _)) in enumerate(_QPACK_STATIC_TABLE)
        haskey(d, name) || (d[name] = i - 1)
    end
    d
end

# A string literal whose length has an `prefix_bits`-bit prefix, with the
# Huffman flag just above it and `flags` above that (Section 4.1.2).
function _qpack_encode_string!(out::Vector{UInt8}, value::String, prefix_bits::Int, flags::UInt8)
    raw_len = ncodeunits(value)
    huff_len = _huffman_encoded_length(value)
    if huff_len < raw_len
        _encode_integer!(out, huff_len, prefix_bits, flags | UInt8(1 << prefix_bits))
        _append_huffman_string!(out, value)
    else
        _encode_integer!(out, raw_len, prefix_bits, flags)
        append!(out, codeunits(value))
    end
    return nothing
end

"""
    _qpack_encode(fields) -> Vector{UInt8}

Encode a field section: the prefix for Required Insert Count 0 and Base 0,
then each field as a static indexed field line when name and value are in
the static table, as a literal with a static name reference when the name
is, and as a literal with a literal name otherwise (Section 4.5). Sensitive
fields set the N bit so intermediaries do not index them.
"""
function _qpack_encode(fields::Vector{HeaderField})::Vector{UInt8}
    out = UInt8[0x00, 0x00]
    for field in fields
        exact = get(_QPACK_STATIC_EXACT, (field.name, field.value), -1)
        if exact >= 0
            _encode_integer!(out, exact, 6, 0xc0)
            continue
        end
        name_index = get(_QPACK_STATIC_NAME, field.name, -1)
        if name_index >= 0
            _encode_integer!(out, name_index, 4, field.sensitive ? 0x70 : 0x50)
        else
            _qpack_encode_string!(out, field.name, 3, field.sensitive ? 0x30 : 0x20)
        end
        _qpack_encode_string!(out, field.value, 7, 0x00)
    end
    return out
end

function _qpack_static_entry(index::Int)::Tuple{String,String}
    index < length(_QPACK_STATIC_TABLE) || throw(ProtocolError("QPACK static table index $(index) out of range"))
    return _QPACK_STATIC_TABLE[index+1]
end

function _qpack_decode_string(block::Vector{UInt8}, index::Int, prefix_bits::Int, max_len::Int)::Tuple{String,Int}
    index <= length(block) || throw(ProtocolError("QPACK string literal is truncated"))
    huffman = (block[index] & UInt8(1 << prefix_bits)) != 0
    len, index = _decode_integer(block, index, prefix_bits)
    max_len > 0 && len > max_len && throw(ProtocolError("QPACK field section exceeds the size limit"))
    stop = index + len - 1
    stop <= length(block) || throw(ProtocolError("QPACK string literal is truncated"))
    bytes = block[index:stop]
    value = huffman ? _decode_huffman_string(bytes, max_len) : String(bytes)
    return value, stop + 1
end

"""
    _qpack_decode(block; max_size = 0) -> Vector{HeaderField}

Decode a field section encoded without a dynamic table. `max_size` (0 for no
limit) bounds the section's size, counting each field as its name and value
lengths plus 32 (RFC 9114 Section 4.2.2). Throws `ProtocolError` for
malformed input or a dynamic table reference; HTTP/3 treats either as
QPACK_DECOMPRESSION_FAILED.
"""
function _qpack_decode(block::Vector{UInt8}; max_size::Int=0)::Vector{HeaderField}
    try
        return _qpack_decode_lines(block, max_size)
    catch err
        err isa ParseError && throw(ProtocolError(string("QPACK: ", err.message)))
        rethrow()
    end
end

function _qpack_decode_lines(block::Vector{UInt8}, max_size::Int)::Vector{HeaderField}
    length(block) >= 2 || throw(ProtocolError("QPACK field section prefix is truncated"))
    required_insert_count, index = _decode_integer(block, 1, 8)
    required_insert_count == 0 || throw(ProtocolError("QPACK field section references the dynamic table"))
    index <= length(block) || throw(ProtocolError("QPACK field section prefix is truncated"))
    # With Required Insert Count 0, a negative Base can reference nothing.
    (block[index] & 0x80) == 0 || throw(ProtocolError("QPACK field section has a negative Base"))
    _, index = _decode_integer(block, index, 7)
    fields = HeaderField[]
    total = 0
    while index <= length(block)
        b = block[index]
        if (b & 0x80) != 0
            (b & 0x40) != 0 || throw(ProtocolError("QPACK field line references the dynamic table"))
            entry, index = _decode_integer(block, index, 6)
            name, value = _qpack_static_entry(entry)
        elseif (b & 0x40) != 0
            (b & 0x10) != 0 || throw(ProtocolError("QPACK field line references the dynamic table"))
            entry, index = _decode_integer(block, index, 4)
            name = _qpack_static_entry(entry)[1]
            value, index = _qpack_decode_string(block, index, 7, max_size)
        elseif (b & 0x20) != 0
            name, index = _qpack_decode_string(block, index, 3, max_size)
            value, index = _qpack_decode_string(block, index, 7, max_size)
        else
            # Post-base forms always reference the dynamic table.
            throw(ProtocolError("QPACK field line references the dynamic table"))
        end
        total += ncodeunits(name) + ncodeunits(value) + 32
        max_size > 0 && total > max_size && throw(ProtocolError("QPACK field section exceeds the size limit"))
        push!(fields, HeaderField(name, value, false))
    end
    return fields
end
