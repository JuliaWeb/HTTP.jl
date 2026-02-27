# HPACK header compression (RFC 7541)
# Port of aws-c-http/source/hpack.c, hpack_encoder.c, hpack_decoder.c

# ─── Constants ───

const HPACK_STATIC_TABLE_SIZE = 61
const HPACK_DYNAMIC_TABLE_INITIAL_SIZE = 4096       # max bytes
const HPACK_DYNAMIC_TABLE_INITIAL_ELEMENTS = 512    # buffer capacity
const HPACK_DYNAMIC_TABLE_MAX_SIZE = 16 * 1024 * 1024  # 16 MiB cap
const HPACK_ENTRY_OVERHEAD = 32  # RFC 7541 §4.1: name.len + value.len + 32

# ─── Huffman mode ───

@enumx HpackHuffmanMode::UInt8 begin
    SMALLEST = 0
    NEVER = 1
    ALWAYS = 2
end

# ─── Decode result type ───

@enumx HpackDecodeType::UInt8 begin
    ONGOING = 0
    HEADER_FIELD = 1
    DYNAMIC_TABLE_RESIZE = 2
end

# ─── Static table (RFC 7541 Appendix A, 1-indexed) ───

struct _StaticEntry
    name::String
    value::String
end

const HPACK_STATIC_TABLE = _StaticEntry[
    _StaticEntry(":authority", ""),
    _StaticEntry(":method", "GET"),
    _StaticEntry(":method", "POST"),
    _StaticEntry(":path", "/"),
    _StaticEntry(":path", "/index.html"),
    _StaticEntry(":scheme", "http"),
    _StaticEntry(":scheme", "https"),
    _StaticEntry(":status", "200"),
    _StaticEntry(":status", "204"),
    _StaticEntry(":status", "206"),
    _StaticEntry(":status", "304"),
    _StaticEntry(":status", "400"),
    _StaticEntry(":status", "404"),
    _StaticEntry(":status", "500"),
    _StaticEntry("accept-charset", ""),
    _StaticEntry("accept-encoding", "gzip,deflate"),
    _StaticEntry("accept-language", ""),
    _StaticEntry("accept-ranges", ""),
    _StaticEntry("accept", ""),
    _StaticEntry("access-control-allow-origin", ""),
    _StaticEntry("age", ""),
    _StaticEntry("allow", ""),
    _StaticEntry("authorization", ""),
    _StaticEntry("cache-control", ""),
    _StaticEntry("content-disposition", ""),
    _StaticEntry("content-encoding", ""),
    _StaticEntry("content-language", ""),
    _StaticEntry("content-length", ""),
    _StaticEntry("content-location", ""),
    _StaticEntry("content-range", ""),
    _StaticEntry("content-type", ""),
    _StaticEntry("cookie", ""),
    _StaticEntry("date", ""),
    _StaticEntry("etag", ""),
    _StaticEntry("expect", ""),
    _StaticEntry("expires", ""),
    _StaticEntry("from", ""),
    _StaticEntry("host", ""),
    _StaticEntry("if-match", ""),
    _StaticEntry("if-modified-since", ""),
    _StaticEntry("if-none-match", ""),
    _StaticEntry("if-range", ""),
    _StaticEntry("if-unmodified-since", ""),
    _StaticEntry("last-modified", ""),
    _StaticEntry("link", ""),
    _StaticEntry("location", ""),
    _StaticEntry("max-forwards", ""),
    _StaticEntry("proxy-authenticate", ""),
    _StaticEntry("proxy-authorization", ""),
    _StaticEntry("range", ""),
    _StaticEntry("referer", ""),
    _StaticEntry("refresh", ""),
    _StaticEntry("retry-after", ""),
    _StaticEntry("server", ""),
    _StaticEntry("set-cookie", ""),
    _StaticEntry("strict-transport-security", ""),
    _StaticEntry("transfer-encoding", ""),
    _StaticEntry("user-agent", ""),
    _StaticEntry("vary", ""),
    _StaticEntry("via", ""),
    _StaticEntry("www-authenticate", ""),
]

# ─── Dynamic table (ring buffer) ───

mutable struct HpackDynamicTable
    buffer::Vector{Tuple{String, String}}  # (name, value) ring buffer
    capacity::Int       # buffer length (number of slots)
    num_elements::Int   # current entry count
    index_0::Int        # 1-indexed position of newest entry
    size::Int           # total byte size (sum of name.len + value.len + 32)
    max_size::Int       # maximum allowed byte size
end

function _hpack_dynamic_table_new(max_size::Int=HPACK_DYNAMIC_TABLE_INITIAL_SIZE)
    cap = HPACK_DYNAMIC_TABLE_INITIAL_ELEMENTS
    buf = fill(("", ""), cap)
    return HpackDynamicTable(buf, cap, 0, 1, 0, max_size)
end

function _hpack_header_size(name::AbstractString, value::AbstractString)::Int
    return ncodeunits(name) + ncodeunits(value) + HPACK_ENTRY_OVERHEAD
end

# Get entry at dynamic table position (0-based from newest)
function _hpack_dynamic_get(dt::HpackDynamicTable, dynamic_idx::Int)::Union{Tuple{String,String}, Nothing}
    dynamic_idx < 0 && return nothing
    dynamic_idx >= dt.num_elements && return nothing
    buf_idx = mod1(dt.index_0 + dynamic_idx, dt.capacity)
    return dt.buffer[buf_idx]
end

# Evict oldest entries until size <= target
function _hpack_dynamic_shrink!(dt::HpackDynamicTable, target_size::Int)
    while dt.size > target_size && dt.num_elements > 0
        # Remove oldest entry (at index_0 + num_elements - 1)
        old_idx = mod1(dt.index_0 + dt.num_elements - 1, dt.capacity)
        name, value = dt.buffer[old_idx]
        dt.size -= _hpack_header_size(name, value)
        dt.num_elements -= 1
    end
end

# Insert header at front of dynamic table
function _hpack_dynamic_insert!(dt::HpackDynamicTable, name::String, value::String)::Int
    entry_size = _hpack_header_size(name, value)

    # RFC 7541 §4.4: if entry > max_size, clear entire table
    if entry_size > dt.max_size
        _hpack_dynamic_shrink!(dt, 0)
        return OP_SUCCESS
    end

    # Evict until there's room
    _hpack_dynamic_shrink!(dt, dt.max_size - entry_size)

    # Grow buffer if at capacity
    if dt.num_elements >= dt.capacity
        new_cap = max(dt.capacity * 3 ÷ 2, HPACK_DYNAMIC_TABLE_INITIAL_ELEMENTS)
        new_buf = fill(("", ""), new_cap)
        for i in 0:(dt.num_elements - 1)
            src = mod1(dt.index_0 + i, dt.capacity)
            new_buf[i + 1] = dt.buffer[src]
        end
        dt.buffer = new_buf
        dt.capacity = new_cap
        dt.index_0 = 1
    end

    # Decrement index_0 with wraparound
    dt.index_0 = dt.index_0 == 1 ? dt.capacity : dt.index_0 - 1
    dt.buffer[dt.index_0] = (name, value)
    dt.num_elements += 1
    dt.size += entry_size

    return OP_SUCCESS
end

# Resize dynamic table max size
function _hpack_dynamic_resize!(dt::HpackDynamicTable, new_max_size::Int)
    dt.max_size = new_max_size
    _hpack_dynamic_shrink!(dt, new_max_size)
end

# ─── HPACK context (combined static + dynamic table) ───

mutable struct HpackContext
    dynamic_table::HpackDynamicTable
end

HpackContext() = HpackContext(_hpack_dynamic_table_new())

function hpack_context_clean_up!(ctx::HpackContext)
    dt = ctx.dynamic_table
    dt.num_elements = 0
    dt.size = 0
end

"""
    hpack_get_header_size(name, value) -> Int

Compute HPACK header size: name.len + value.len + 32 (RFC 7541 §4.1).
"""
hpack_get_header_size(name::AbstractString, value::AbstractString)::Int =
    _hpack_header_size(name, value)

function hpack_get_dynamic_table_num_elements(ctx::HpackContext)::Int
    return ctx.dynamic_table.num_elements
end

function hpack_get_dynamic_table_max_size(ctx::HpackContext)::Int
    return ctx.dynamic_table.max_size
end

"""
    hpack_get_header(ctx, index) -> Union{Tuple{String,String}, Nothing}

Get header (name, value) by 1-based absolute index.
Indices 1-61 are the static table, 62+ are the dynamic table.
"""
function hpack_get_header(ctx::HpackContext, index::Int)::Union{Tuple{String,String}, Nothing}
    index <= 0 && return nothing

    if index <= HPACK_STATIC_TABLE_SIZE
        e = HPACK_STATIC_TABLE[index]
        return (e.name, e.value)
    end

    dynamic_idx = index - HPACK_STATIC_TABLE_SIZE - 1  # 0-based
    return _hpack_dynamic_get(ctx.dynamic_table, dynamic_idx)
end

"""
    hpack_find_index(ctx, name, value; search_dynamic=true) -> (index, has_value)

Search static and dynamic tables for a header.
Returns (0, false) if not found, or (index, has_value_match).
"""
function hpack_find_index(ctx::HpackContext, name::AbstractString, value::AbstractString;
                          search_dynamic::Bool=true)::Tuple{Int, Bool}
    best_index = 0
    best_has_value = false

    # Search static table
    for i in 1:HPACK_STATIC_TABLE_SIZE
        e = HPACK_STATIC_TABLE[i]
        if e.name == name
            if e.value == value && !isempty(value)
                return (i, true)  # exact match in static table — best possible
            end
            if best_index == 0
                best_index = i
                best_has_value = false
            end
        end
    end

    # Search dynamic table
    if search_dynamic
        dt = ctx.dynamic_table
        for d in 0:(dt.num_elements - 1)
            entry = _hpack_dynamic_get(dt, d)
            entry === nothing && continue
            ename, evalue = entry
            if ename == name
                abs_idx = HPACK_STATIC_TABLE_SIZE + 1 + d
                if evalue == value
                    return (abs_idx, true)  # exact match
                end
                if best_index == 0 || best_has_value == false
                    best_index = abs_idx
                    best_has_value = false
                end
            end
        end
    end

    return (best_index, best_has_value)
end

"""
    hpack_insert_header!(ctx, name, value) -> Int

Insert a header into the dynamic table.
"""
function hpack_insert_header!(ctx::HpackContext, name::String, value::String)::Int
    return _hpack_dynamic_insert!(ctx.dynamic_table, name, value)
end

"""
    hpack_resize_dynamic_table!(ctx, new_max_size)

Resize the dynamic table's maximum size, evicting entries as needed.
"""
function hpack_resize_dynamic_table!(ctx::HpackContext, new_max_size::Int)
    _hpack_dynamic_resize!(ctx.dynamic_table, new_max_size)
end

# ─── Integer encoding (RFC 7541 §5.1) ───

"""
    hpack_encode_integer(value, starting_bits, prefix_size) -> Vector{UInt8}

Encode an HPACK integer with the given prefix size (1-8 bits).
starting_bits contains the high bits of the first byte (above the prefix).
"""
function hpack_encode_integer(value::UInt64, starting_bits::UInt8, prefix_size::UInt8)::Vector{UInt8}
    prefix_mask = UInt8((1 << prefix_size) - 1)

    if value < prefix_mask
        return UInt8[starting_bits | UInt8(value)]
    end

    output = UInt8[starting_bits | prefix_mask]
    value -= prefix_mask

    while value >= 128
        push!(output, UInt8((value & 0x7f) | 0x80))
        value >>= 7
    end
    push!(output, UInt8(value))

    return output
end

# ─── Integer decoding (RFC 7541 §5.1) ───

@enumx _HpackIntegerState::UInt8 begin
    INIT = 0
    VALUE = 1
end

mutable struct HpackIntegerDecoder
    state::_HpackIntegerState.T
    accumulator::UInt64
    bit_count::UInt8
end

HpackIntegerDecoder() = HpackIntegerDecoder(_HpackIntegerState.INIT, 0, 0)

function _hpack_integer_decoder_reset!(dec::HpackIntegerDecoder)
    dec.state = _HpackIntegerState.INIT
    dec.accumulator = 0
    dec.bit_count = 0
end

"""
    hpack_decode_integer!(dec, data, pos, prefix_size) -> (status, value, complete)

Decode an HPACK integer. `pos` is 1-indexed and updated in-place.
Returns (OP_SUCCESS/OP_ERR, decoded_value, is_complete).
"""
function hpack_decode_integer!(dec::HpackIntegerDecoder, data::AbstractVector{UInt8},
                               pos::Base.RefValue{Int}, prefix_size::UInt8)::Tuple{Int, UInt64, Bool}
    prefix_mask = UInt64((1 << prefix_size) - 1)

    while pos[] <= length(data)
        byte = data[pos[]]

        if dec.state == _HpackIntegerState.INIT
            dec.accumulator = byte & prefix_mask
            pos[] += 1
            if dec.accumulator < prefix_mask
                return (OP_SUCCESS, dec.accumulator, true)
            end
            dec.state = _HpackIntegerState.VALUE
            dec.bit_count = 0
            continue
        end

        # VALUE state: continuation bytes
        pos[] += 1
        if dec.bit_count > 57
            _hpack_integer_decoder_reset!(dec)
            return (raise_error(ERROR_HTTP_PROTOCOL_ERROR), UInt64(0), false)
        end

        dec.accumulator += UInt64(byte & 0x7f) << dec.bit_count
        dec.bit_count += 7

        if (byte & 0x80) == 0
            value = dec.accumulator
            _hpack_integer_decoder_reset!(dec)
            return (OP_SUCCESS, value, true)
        end
    end

    return (OP_SUCCESS, UInt64(0), false)  # incomplete
end

# ─── String encoding (RFC 7541 §5.2) ───

"""
    hpack_encode_string(data, huffman_mode) -> Vector{UInt8}

Encode an HPACK string (length-prefixed, optionally Huffman-compressed).
"""
function hpack_encode_string(data::AbstractVector{UInt8};
                             huffman_mode::HpackHuffmanMode.T=HpackHuffmanMode.SMALLEST)::Vector{UInt8}
    use_huffman = false
    huffman_data = UInt8[]

    if huffman_mode == HpackHuffmanMode.ALWAYS
        use_huffman = true
    elseif huffman_mode == HpackHuffmanMode.SMALLEST
        huffman_data = hpack_huffman_encode(data)
        use_huffman = length(huffman_data) < length(data)
    end

    if use_huffman
        if isempty(huffman_data)
            huffman_data = hpack_huffman_encode(data)
        end
        h_bit = UInt8(0x80)
        len_bytes = hpack_encode_integer(UInt64(length(huffman_data)), h_bit, UInt8(7))
        return vcat(len_bytes, huffman_data)
    else
        len_bytes = hpack_encode_integer(UInt64(length(data)), UInt8(0), UInt8(7))
        return vcat(len_bytes, data)
    end
end

function hpack_encode_string(s::AbstractString; kwargs...)
    return hpack_encode_string(Vector{UInt8}(codeunits(String(s))); kwargs...)
end

# ─── String decoding (RFC 7541 §5.2) ───

@enumx _HpackStringState::UInt8 begin
    INIT = 0
    LENGTH = 1
    VALUE = 2
end

mutable struct HpackStringDecoder
    state::_HpackStringState.T
    use_huffman::Bool
    length::UInt64
    consumed::Int  # bytes of string data consumed so far
    int_decoder::HpackIntegerDecoder
end

HpackStringDecoder() = HpackStringDecoder(_HpackStringState.INIT, false, 0, 0, HpackIntegerDecoder())

function _hpack_string_decoder_reset!(dec::HpackStringDecoder)
    dec.state = _HpackStringState.INIT
    dec.use_huffman = false
    dec.length = 0
    dec.consumed = 0
    _hpack_integer_decoder_reset!(dec.int_decoder)
end

"""
    hpack_decode_string!(dec, data, pos; max_length) -> (status, output, complete)

Decode an HPACK string. Returns (status, decoded_bytes, is_complete).
"""
function hpack_decode_string!(dec::HpackStringDecoder, data::AbstractVector{UInt8},
                              pos::Base.RefValue{Int};
                              max_length::Int=typemax(Int))::Tuple{Int, Vector{UInt8}, Bool}
    output = UInt8[]

    while pos[] <= length(data)
        if dec.state == _HpackStringState.INIT
            dec.use_huffman = (data[pos[]] & 0x80) != 0
            _hpack_integer_decoder_reset!(dec.int_decoder)
            dec.state = _HpackStringState.LENGTH
            # Fall through to LENGTH (don't consume byte yet — integer decoder will)
        end

        if dec.state == _HpackStringState.LENGTH
            status, value, complete = hpack_decode_integer!(dec.int_decoder, data, pos, UInt8(7))
            status != OP_SUCCESS && return (status, output, false)
            !complete && return (OP_SUCCESS, output, false)

            dec.length = value
            if dec.length == 0
                _hpack_string_decoder_reset!(dec)
                return (OP_SUCCESS, output, true)
            end
            if Int(dec.length) > max_length && !dec.use_huffman
                _hpack_string_decoder_reset!(dec)
                return (raise_error(ERROR_HTTP_PROTOCOL_ERROR), output, false)
            end
            dec.state = _HpackStringState.VALUE
            continue
        end

        # VALUE state: consume string bytes
        available = length(data) - pos[] + 1
        needed = Int(dec.length) - dec.consumed
        to_read = min(available, needed)
        append!(output, @view data[pos[]:(pos[] + to_read - 1)])
        pos[] += to_read
        dec.consumed += to_read

        if dec.consumed >= Int(dec.length)
            # All bytes consumed
            if dec.use_huffman
                status, decoded = hpack_huffman_decode(output; max_output=max_length)
                _hpack_string_decoder_reset!(dec)
                status != OP_SUCCESS && return (status, decoded, false)
                return (OP_SUCCESS, decoded, true)
            else
                _hpack_string_decoder_reset!(dec)
                return (OP_SUCCESS, output, true)
            end
        end
    end

    return (OP_SUCCESS, output, false)  # incomplete
end

# ─── HPACK Encoder ───

mutable struct HpackEncoder
    context::HpackContext
    huffman_mode::HpackHuffmanMode.T
    max_table_size::Int  # local cap on dynamic table size

    # Dynamic table size update tracking (RFC 7541 §4.2)
    size_update_pending::Bool
    size_update_smallest::Int
    size_update_latest::Int
end

function hpack_encoder_init(; max_table_size::Int=HPACK_DYNAMIC_TABLE_INITIAL_SIZE)
    return HpackEncoder(
        HpackContext(),
        HpackHuffmanMode.SMALLEST,
        max_table_size,
        false, 0, 0,
    )
end

function hpack_encoder_clean_up!(enc::HpackEncoder)
    hpack_context_clean_up!(enc.context)
end

function hpack_encoder_set_huffman_mode!(enc::HpackEncoder, mode::HpackHuffmanMode.T)
    enc.huffman_mode = mode
end

function hpack_encoder_set_max_table_size!(enc::HpackEncoder, size::Int)
    enc.max_table_size = size
    # Apply to context if smaller than current
    if size < enc.context.dynamic_table.max_size
        hpack_resize_dynamic_table!(enc.context, size)
    end
end

"""
    hpack_encoder_update_max_table_size!(enc, setting_value)

Signal that peer sent a new SETTINGS_HEADER_TABLE_SIZE.
Actual size update is encoded in the next header block.
"""
function hpack_encoder_update_max_table_size!(enc::HpackEncoder, setting_value::UInt32)
    # Clamp to our maximum
    clamped = min(Int(setting_value), HPACK_DYNAMIC_TABLE_MAX_SIZE)
    # Clamp to local cap
    clamped = min(clamped, enc.max_table_size)

    if !enc.size_update_pending
        enc.size_update_pending = true
        enc.size_update_smallest = clamped
        enc.size_update_latest = clamped
    else
        enc.size_update_smallest = min(enc.size_update_smallest, clamped)
        enc.size_update_latest = clamped
    end
end

"""
    hpack_encode_header_block(enc, headers) -> (Int, Vector{UInt8})

Encode a complete header block. Returns (status, encoded_bytes).
"""
function hpack_encode_header_block(enc::HpackEncoder, headers::HttpHeaders)::Tuple{Int, Vector{UInt8}}
    output = UInt8[]

    # Emit pending dynamic table size updates (RFC 7541 §4.2)
    if enc.size_update_pending
        enc.size_update_pending = false

        # Emit smallest update (if different from latest)
        if enc.size_update_smallest != enc.size_update_latest
            append!(output, hpack_encode_integer(UInt64(enc.size_update_smallest), UInt8(0x20), UInt8(5)))
            hpack_resize_dynamic_table!(enc.context, enc.size_update_smallest)
        end

        # Emit latest update
        append!(output, hpack_encode_integer(UInt64(enc.size_update_latest), UInt8(0x20), UInt8(5)))
        hpack_resize_dynamic_table!(enc.context, enc.size_update_latest)
    end

    for h in headers.headers
        err = _hpack_encode_header!(enc, output, h)
        err != OP_SUCCESS && return (err, output)
    end

    return (OP_SUCCESS, output)
end

function _hpack_encode_header!(enc::HpackEncoder, output::Vector{UInt8}, header::HttpHeader)::Int
    name = header.name
    value = header.value
    compression = header.compression

    index, has_value = hpack_find_index(enc.context, name, value)

    if has_value && index > 0
        # Indexed Header Field (§6.1): 1-bit prefix, 7-bit index
        append!(output, hpack_encode_integer(UInt64(index), UInt8(0x80), UInt8(7)))
        return OP_SUCCESS
    end

    # Literal Header Field
    if compression == HttpHeaderCompression.USE_CACHE
        # With Incremental Indexing (§6.2.1): 01 prefix, 6-bit index
        prefix = UInt8(0x40)
        prefix_size = UInt8(6)
    elseif compression == HttpHeaderCompression.NO_FORWARD_CACHE
        # Never Indexed (§6.2.3): 0001 prefix, 4-bit index
        prefix = UInt8(0x10)
        prefix_size = UInt8(4)
    else
        # Without Indexing (§6.2.2): 0000 prefix, 4-bit index
        prefix = UInt8(0x00)
        prefix_size = UInt8(4)
    end

    if index > 0
        # Name is indexed
        append!(output, hpack_encode_integer(UInt64(index), prefix, prefix_size))
    else
        # Name is literal
        append!(output, hpack_encode_integer(UInt64(0), prefix, prefix_size))
        append!(output, hpack_encode_string(name; huffman_mode=enc.huffman_mode))
    end

    # Value is always literal
    append!(output, hpack_encode_string(value; huffman_mode=enc.huffman_mode))

    # Add to dynamic table if using cache
    if compression == HttpHeaderCompression.USE_CACHE
        hpack_insert_header!(enc.context, String(name), String(value))
    end

    return OP_SUCCESS
end

# ─── HPACK Decoder ───

@enumx _HpackEntryState::UInt8 begin
    INIT = 0
    INDEXED = 1
    LITERAL_BEGIN = 2
    LITERAL_NAME_STRING = 3
    LITERAL_VALUE_STRING = 4
    DYNAMIC_TABLE_RESIZE = 5
    COMPLETE = 6
end

struct HpackDecodeResult
    type::HpackDecodeType.T
    header_name::String
    header_value::String
    header_compression::HttpHeaderCompression.T
    dynamic_table_resize::Int
end

HpackDecodeResult() = HpackDecodeResult(HpackDecodeType.ONGOING, "", "", HttpHeaderCompression.USE_CACHE, 0)

function _hpack_header_result(name::String, value::String, compression::HttpHeaderCompression.T)
    return HpackDecodeResult(HpackDecodeType.HEADER_FIELD, name, value, compression, 0)
end

function _hpack_resize_result(size::Int)
    return HpackDecodeResult(HpackDecodeType.DYNAMIC_TABLE_RESIZE, "", "", HttpHeaderCompression.USE_CACHE, size)
end

mutable struct HpackDecoder
    context::HpackContext
    protocol_max_size::Int   # from SETTINGS_HEADER_TABLE_SIZE
    max_string_length::Int

    # State machine
    entry_state::_HpackEntryState.T
    int_decoder::HpackIntegerDecoder
    str_decoder::HpackStringDecoder

    # Entry progress
    compression::HttpHeaderCompression.T
    prefix_size::UInt8
    name_index::UInt64
    scratch::Vector{UInt8}     # accumulates name then value
    name_length::Int           # bytes of name in scratch
end

function hpack_decoder_init(; max_string_length::Int=typemax(Int))
    return HpackDecoder(
        HpackContext(),
        HPACK_DYNAMIC_TABLE_INITIAL_SIZE,
        max_string_length,
        _HpackEntryState.INIT,
        HpackIntegerDecoder(),
        HpackStringDecoder(),
        HttpHeaderCompression.USE_CACHE,
        UInt8(0), UInt64(0),
        UInt8[], 0,
    )
end

function hpack_decoder_clean_up!(dec::HpackDecoder)
    hpack_context_clean_up!(dec.context)
end

function hpack_decoder_update_max_table_size!(dec::HpackDecoder, setting_value::UInt32)
    clamped = min(Int(setting_value), HPACK_DYNAMIC_TABLE_MAX_SIZE)
    dec.protocol_max_size = clamped
end

function hpack_decoder_set_max_string_length!(dec::HpackDecoder, length::Int)
    dec.max_string_length = length
end

function _hpack_decoder_reset_entry!(dec::HpackDecoder)
    dec.entry_state = _HpackEntryState.INIT
    _hpack_integer_decoder_reset!(dec.int_decoder)
    _hpack_string_decoder_reset!(dec.str_decoder)
    dec.name_index = 0
    empty!(dec.scratch)
    dec.name_length = 0
end

"""
    hpack_decode!(dec, data, pos) -> (Int, HpackDecodeResult)

Decode the next entry from data starting at pos[]. Advances pos[].
Call repeatedly until all data is consumed.
Returns (status, result) where result.type indicates completion state.
"""
function hpack_decode!(dec::HpackDecoder, data::AbstractVector{UInt8},
                       pos::Base.RefValue{Int})::Tuple{Int, HpackDecodeResult}
    while pos[] <= length(data)
        if dec.entry_state == _HpackEntryState.INIT
            byte = data[pos[]]

            if (byte & 0x80) != 0
                # Indexed Header Field (§6.1): 1xxxxxxx
                dec.entry_state = _HpackEntryState.INDEXED
                dec.prefix_size = UInt8(7)
                _hpack_integer_decoder_reset!(dec.int_decoder)

            elseif (byte & 0xc0) == 0x40
                # Literal with Incremental Indexing (§6.2.1): 01xxxxxx
                dec.entry_state = _HpackEntryState.LITERAL_BEGIN
                dec.prefix_size = UInt8(6)
                dec.compression = HttpHeaderCompression.USE_CACHE
                _hpack_integer_decoder_reset!(dec.int_decoder)

            elseif (byte & 0xe0) == 0x20
                # Dynamic Table Size Update (§6.3): 001xxxxx
                dec.entry_state = _HpackEntryState.DYNAMIC_TABLE_RESIZE
                dec.prefix_size = UInt8(5)
                _hpack_integer_decoder_reset!(dec.int_decoder)

            elseif (byte & 0xf0) == 0x10
                # Literal Never Indexed (§6.2.3): 0001xxxx
                dec.entry_state = _HpackEntryState.LITERAL_BEGIN
                dec.prefix_size = UInt8(4)
                dec.compression = HttpHeaderCompression.NO_FORWARD_CACHE
                _hpack_integer_decoder_reset!(dec.int_decoder)

            else
                # Literal Without Indexing (§6.2.2): 0000xxxx
                dec.entry_state = _HpackEntryState.LITERAL_BEGIN
                dec.prefix_size = UInt8(4)
                dec.compression = HttpHeaderCompression.NO_CACHE
                _hpack_integer_decoder_reset!(dec.int_decoder)
            end
            # Don't consume byte — sub-decoder needs it
        end

        if dec.entry_state == _HpackEntryState.INDEXED
            status, value, complete = hpack_decode_integer!(dec.int_decoder, data, pos, dec.prefix_size)
            status != OP_SUCCESS && return (status, HpackDecodeResult())
            !complete && return (OP_SUCCESS, HpackDecodeResult())

            entry = hpack_get_header(dec.context, Int(value))
            if entry === nothing
                _hpack_decoder_reset_entry!(dec)
                return (raise_error(ERROR_HTTP_PROTOCOL_ERROR), HpackDecodeResult())
            end

            name, val = entry
            result = _hpack_header_result(name, val, HttpHeaderCompression.USE_CACHE)
            _hpack_decoder_reset_entry!(dec)
            return (OP_SUCCESS, result)
        end

        if dec.entry_state == _HpackEntryState.LITERAL_BEGIN
            status, value, complete = hpack_decode_integer!(dec.int_decoder, data, pos, dec.prefix_size)
            status != OP_SUCCESS && return (status, HpackDecodeResult())
            !complete && return (OP_SUCCESS, HpackDecodeResult())

            dec.name_index = value

            if value == 0
                # Name is a literal string
                dec.entry_state = _HpackEntryState.LITERAL_NAME_STRING
                _hpack_string_decoder_reset!(dec.str_decoder)
            else
                # Name from table
                entry = hpack_get_header(dec.context, Int(value))
                if entry === nothing
                    _hpack_decoder_reset_entry!(dec)
                    return (raise_error(ERROR_HTTP_PROTOCOL_ERROR), HpackDecodeResult())
                end
                name, _ = entry
                append!(dec.scratch, codeunits(name))
                dec.name_length = length(dec.scratch)
                dec.entry_state = _HpackEntryState.LITERAL_VALUE_STRING
                _hpack_string_decoder_reset!(dec.str_decoder)
            end
            continue
        end

        if dec.entry_state == _HpackEntryState.LITERAL_NAME_STRING
            status, str_data, complete = hpack_decode_string!(dec.str_decoder, data, pos;
                                                              max_length=dec.max_string_length)
            status != OP_SUCCESS && return (status, HpackDecodeResult())
            if !complete
                append!(dec.scratch, str_data)
                return (OP_SUCCESS, HpackDecodeResult())
            end

            append!(dec.scratch, str_data)
            dec.name_length = length(dec.scratch)
            dec.entry_state = _HpackEntryState.LITERAL_VALUE_STRING
            _hpack_string_decoder_reset!(dec.str_decoder)
            continue
        end

        if dec.entry_state == _HpackEntryState.LITERAL_VALUE_STRING
            status, str_data, complete = hpack_decode_string!(dec.str_decoder, data, pos;
                                                              max_length=dec.max_string_length)
            status != OP_SUCCESS && return (status, HpackDecodeResult())
            if !complete
                append!(dec.scratch, str_data)
                return (OP_SUCCESS, HpackDecodeResult())
            end

            append!(dec.scratch, str_data)
            name = String(dec.scratch[1:dec.name_length])
            value = String(dec.scratch[(dec.name_length + 1):end])
            compression = dec.compression

            # Insert into dynamic table if incremental indexing
            if compression == HttpHeaderCompression.USE_CACHE
                hpack_insert_header!(dec.context, name, value)
            end

            result = _hpack_header_result(name, value, compression)
            _hpack_decoder_reset_entry!(dec)
            return (OP_SUCCESS, result)
        end

        if dec.entry_state == _HpackEntryState.DYNAMIC_TABLE_RESIZE
            status, value, complete = hpack_decode_integer!(dec.int_decoder, data, pos, dec.prefix_size)
            status != OP_SUCCESS && return (status, HpackDecodeResult())
            !complete && return (OP_SUCCESS, HpackDecodeResult())

            new_size = Int(value)
            if new_size > dec.protocol_max_size
                _hpack_decoder_reset_entry!(dec)
                return (raise_error(ERROR_HTTP_PROTOCOL_ERROR), HpackDecodeResult())
            end

            hpack_resize_dynamic_table!(dec.context, new_size)
            result = _hpack_resize_result(new_size)
            _hpack_decoder_reset_entry!(dec)
            return (OP_SUCCESS, result)
        end
    end

    return (OP_SUCCESS, HpackDecodeResult())  # need more data
end
