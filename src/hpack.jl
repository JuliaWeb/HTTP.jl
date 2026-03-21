# HPACK implementation for HTTP/2 header compression/decompression.
"""
    HeaderField

One HPACK header field entry.

Fields:
- `name`: lower-level header name exactly as encoded/decoded
- `value`: header value
- `sensitive`: when `true`, the encoder avoids dynamic-table indexing so the
  value is not retained in compression state
"""
struct HeaderField
    name::String
    value::String
    sensitive::Bool
end

struct DynamicTableEntry
    name::String
    value::String
    size::Int
end

"""
    DynamicTable(max_size=4096)

Mutable HPACK dynamic table for recently indexed header fields.

The table follows RFC 7541's size accounting rules (`32 + |name| + |value|` per
entry) and evicts from the end when the size limit is lowered or new indexed
entries would overflow capacity.
"""
mutable struct DynamicTable
    entries::Vector{DynamicTableEntry}
    max_size::Int
    current_size::Int
end

"""
    Encoder(; max_table_size=4096)

Stateful HPACK encoder that tracks peer-visible dynamic table updates.

This object is stateful: successive calls to `encode_header_block` reuse the
same dynamic table and may emit table-size update instructions before the next
header block.
"""
mutable struct Encoder
    table::DynamicTable
    min_table_size::Int
    max_table_size_limit::Int
    table_size_update::Bool
end

"""
    Decoder(; max_table_size=4096)

Stateful HPACK decoder that tracks peer dynamic table state across header
blocks.
"""
mutable struct Decoder
    table::DynamicTable
end

const _STATIC_TABLE = HeaderField[
    HeaderField(":authority", "", false),
    HeaderField(":method", "GET", false),
    HeaderField(":method", "POST", false),
    HeaderField(":path", "/", false),
    HeaderField(":path", "/index.html", false),
    HeaderField(":scheme", "http", false),
    HeaderField(":scheme", "https", false),
    HeaderField(":status", "200", false),
    HeaderField(":status", "204", false),
    HeaderField(":status", "206", false),
    HeaderField(":status", "304", false),
    HeaderField(":status", "400", false),
    HeaderField(":status", "404", false),
    HeaderField(":status", "500", false),
    HeaderField("accept-charset", "", false),
    HeaderField("accept-encoding", "gzip, deflate", false),
    HeaderField("accept-language", "", false),
    HeaderField("accept-ranges", "", false),
    HeaderField("accept", "", false),
    HeaderField("access-control-allow-origin", "", false),
    HeaderField("age", "", false),
    HeaderField("allow", "", false),
    HeaderField("authorization", "", false),
    HeaderField("cache-control", "", false),
    HeaderField("content-disposition", "", false),
    HeaderField("content-encoding", "", false),
    HeaderField("content-language", "", false),
    HeaderField("content-length", "", false),
    HeaderField("content-location", "", false),
    HeaderField("content-range", "", false),
    HeaderField("content-type", "", false),
    HeaderField("cookie", "", false),
    HeaderField("date", "", false),
    HeaderField("etag", "", false),
    HeaderField("expect", "", false),
    HeaderField("expires", "", false),
    HeaderField("from", "", false),
    HeaderField("host", "", false),
    HeaderField("if-match", "", false),
    HeaderField("if-modified-since", "", false),
    HeaderField("if-none-match", "", false),
    HeaderField("if-range", "", false),
    HeaderField("if-unmodified-since", "", false),
    HeaderField("last-modified", "", false),
    HeaderField("link", "", false),
    HeaderField("location", "", false),
    HeaderField("max-forwards", "", false),
    HeaderField("proxy-authenticate", "", false),
    HeaderField("proxy-authorization", "", false),
    HeaderField("range", "", false),
    HeaderField("referer", "", false),
    HeaderField("refresh", "", false),
    HeaderField("retry-after", "", false),
    HeaderField("server", "", false),
    HeaderField("set-cookie", "", false),
    HeaderField("strict-transport-security", "", false),
    HeaderField("transfer-encoding", "", false),
    HeaderField("user-agent", "", false),
    HeaderField("vary", "", false),
    HeaderField("via", "", false),
    HeaderField("www-authenticate", "", false),
]

const _HUFFMAN_CODES = UInt32[
    0x1ff8,
    0x7fffd8,
    0xfffffe2,
    0xfffffe3,
    0xfffffe4,
    0xfffffe5,
    0xfffffe6,
    0xfffffe7,
    0xfffffe8,
    0xffffea,
    0x3ffffffc,
    0xfffffe9,
    0xfffffea,
    0x3ffffffd,
    0xfffffeb,
    0xfffffec,
    0xfffffed,
    0xfffffee,
    0xfffffef,
    0xffffff0,
    0xffffff1,
    0xffffff2,
    0x3ffffffe,
    0xffffff3,
    0xffffff4,
    0xffffff5,
    0xffffff6,
    0xffffff7,
    0xffffff8,
    0xffffff9,
    0xffffffa,
    0xffffffb,
    0x14,
    0x3f8,
    0x3f9,
    0xffa,
    0x1ff9,
    0x15,
    0xf8,
    0x7fa,
    0x3fa,
    0x3fb,
    0xf9,
    0x7fb,
    0xfa,
    0x16,
    0x17,
    0x18,
    0x0,
    0x1,
    0x2,
    0x19,
    0x1a,
    0x1b,
    0x1c,
    0x1d,
    0x1e,
    0x1f,
    0x5c,
    0xfb,
    0x7ffc,
    0x20,
    0xffb,
    0x3fc,
    0x1ffa,
    0x21,
    0x5d,
    0x5e,
    0x5f,
    0x60,
    0x61,
    0x62,
    0x63,
    0x64,
    0x65,
    0x66,
    0x67,
    0x68,
    0x69,
    0x6a,
    0x6b,
    0x6c,
    0x6d,
    0x6e,
    0x6f,
    0x70,
    0x71,
    0x72,
    0xfc,
    0x73,
    0xfd,
    0x1ffb,
    0x7fff0,
    0x1ffc,
    0x3ffc,
    0x22,
    0x7ffd,
    0x3,
    0x23,
    0x4,
    0x24,
    0x5,
    0x25,
    0x26,
    0x27,
    0x6,
    0x74,
    0x75,
    0x28,
    0x29,
    0x2a,
    0x7,
    0x2b,
    0x76,
    0x2c,
    0x8,
    0x9,
    0x2d,
    0x77,
    0x78,
    0x79,
    0x7a,
    0x7b,
    0x7ffe,
    0x7fc,
    0x3ffd,
    0x1ffd,
    0xffffffc,
    0xfffe6,
    0x3fffd2,
    0xfffe7,
    0xfffe8,
    0x3fffd3,
    0x3fffd4,
    0x3fffd5,
    0x7fffd9,
    0x3fffd6,
    0x7fffda,
    0x7fffdb,
    0x7fffdc,
    0x7fffdd,
    0x7fffde,
    0xffffeb,
    0x7fffdf,
    0xffffec,
    0xffffed,
    0x3fffd7,
    0x7fffe0,
    0xffffee,
    0x7fffe1,
    0x7fffe2,
    0x7fffe3,
    0x7fffe4,
    0x1fffdc,
    0x3fffd8,
    0x7fffe5,
    0x3fffd9,
    0x7fffe6,
    0x7fffe7,
    0xffffef,
    0x3fffda,
    0x1fffdd,
    0xfffe9,
    0x3fffdb,
    0x3fffdc,
    0x7fffe8,
    0x7fffe9,
    0x1fffde,
    0x7fffea,
    0x3fffdd,
    0x3fffde,
    0xfffff0,
    0x1fffdf,
    0x3fffdf,
    0x7fffeb,
    0x7fffec,
    0x1fffe0,
    0x1fffe1,
    0x3fffe0,
    0x1fffe2,
    0x7fffed,
    0x3fffe1,
    0x7fffee,
    0x7fffef,
    0xfffea,
    0x3fffe2,
    0x3fffe3,
    0x3fffe4,
    0x7ffff0,
    0x3fffe5,
    0x3fffe6,
    0x7ffff1,
    0x3ffffe0,
    0x3ffffe1,
    0xfffeb,
    0x7fff1,
    0x3fffe7,
    0x7ffff2,
    0x3fffe8,
    0x1ffffec,
    0x3ffffe2,
    0x3ffffe3,
    0x3ffffe4,
    0x7ffffde,
    0x7ffffdf,
    0x3ffffe5,
    0xfffff1,
    0x1ffffed,
    0x7fff2,
    0x1fffe3,
    0x3ffffe6,
    0x7ffffe0,
    0x7ffffe1,
    0x3ffffe7,
    0x7ffffe2,
    0xfffff2,
    0x1fffe4,
    0x1fffe5,
    0x3ffffe8,
    0x3ffffe9,
    0xffffffd,
    0x7ffffe3,
    0x7ffffe4,
    0x7ffffe5,
    0xfffec,
    0xfffff3,
    0xfffed,
    0x1fffe6,
    0x3fffe9,
    0x1fffe7,
    0x1fffe8,
    0x7ffff3,
    0x3fffea,
    0x3fffeb,
    0x1ffffee,
    0x1ffffef,
    0xfffff4,
    0xfffff5,
    0x3ffffea,
    0x7ffff4,
    0x3ffffeb,
    0x7ffffe6,
    0x3ffffec,
    0x3ffffed,
    0x7ffffe7,
    0x7ffffe8,
    0x7ffffe9,
    0x7ffffea,
    0x7ffffeb,
    0xffffffe,
    0x7ffffec,
    0x7ffffed,
    0x7ffffee,
    0x7ffffef,
    0x7fffff0,
    0x3ffffee,
]

const _HUFFMAN_CODE_LEN = UInt8[
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28,
    28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    6, 10, 10, 12, 13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6,
    5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8, 15, 6, 12, 10,
    13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14, 6,
    15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5,
    6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7, 15, 11, 14, 13, 28,
    20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
    24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
    22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23,
    21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
    26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25,
    19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27,
    20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
    26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26,
]

mutable struct _HuffmanNode
    children::Union{Nothing,Vector{Int32}}
    code_len::UInt8
    sym::Int16
end

@inline function _new_huffman_internal_node()::_HuffmanNode
    return _HuffmanNode(fill(Int32(0), 256), UInt8(0), Int16(-1))
end

@inline function _new_huffman_leaf_node(sym::Int16, code_len::UInt8)::_HuffmanNode
    return _HuffmanNode(nothing, code_len, sym)
end

function _build_huffman_tree()::Vector{_HuffmanNode}
    length(_HUFFMAN_CODES) == 256 || throw(ProtocolError("unexpected HPACK Huffman table size"))
    length(_HUFFMAN_CODE_LEN) == 256 || throw(ProtocolError("unexpected HPACK Huffman length table size"))
    nodes = _HuffmanNode[_new_huffman_internal_node()]
    # Build a 256-way decode trie for fast byte-at-a-time Huffman decoding.
    for sym in Int16(0):Int16(255)
        code = _HUFFMAN_CODES[Int(sym)+1]
        code_len = Int(_HUFFMAN_CODE_LEN[Int(sym)+1])
        cur = Int32(1)
        while code_len > 8
            code_len -= 8
            idx = Int((code >> code_len) & UInt32(0xff)) + 1
            children = nodes[Int(cur)].children
            children === nothing && throw(ProtocolError("invalid HPACK Huffman tree state"))
            child = children[idx]
            if child == 0
                push!(nodes, _new_huffman_internal_node())
                child = Int32(length(nodes))
                children[idx] = child
            end
            cur = child
        end
        shift = 8 - code_len
        start = Int((code << shift) & UInt32(0xff))
        count = Int(1 << shift)
        push!(nodes, _new_huffman_leaf_node(sym, UInt8(code_len)))
        leaf = Int32(length(nodes))
        children = nodes[Int(cur)].children
        children === nothing && throw(ProtocolError("invalid HPACK Huffman tree state"))
        for i in start:(start+count-1)
            children[i+1] = leaf
        end
    end
    return nodes
end

const _HUFFMAN_TREE = _build_huffman_tree()

@inline function _huffman_encoded_length(value::String)::Int
    nbits = 0
    for b in codeunits(value)
        nbits += Int(_HUFFMAN_CODE_LEN[Int(b)+1])
    end
    return (nbits + 7) >>> 3
end

function _append_huffman_string!(out::Vector{UInt8}, value::String)
    bitbuf = UInt64(0)
    bitcount = 0
    for b in codeunits(value)
        code = UInt64(_HUFFMAN_CODES[Int(b)+1])
        clen = Int(_HUFFMAN_CODE_LEN[Int(b)+1])
        bitbuf = (bitbuf << clen) | code
        bitcount += clen
        while bitcount >= 8
            push!(out, UInt8((bitbuf >> (bitcount - 8)) & UInt64(0xff)))
            bitcount -= 8
            if bitcount == 0
                bitbuf = UInt64(0)
            else
                bitbuf &= (UInt64(1) << bitcount) - 1
            end
        end
    end
    if bitcount > 0
        pad = 8 - bitcount
        bitbuf = (bitbuf << pad) | ((UInt64(1) << pad) - 1)
        push!(out, UInt8(bitbuf & UInt64(0xff)))
    end
    return nothing
end

function _decode_huffman_string(bytes::Vector{UInt8})::String
    nodes = _HUFFMAN_TREE
    root = Int32(1)
    n = root
    cur = UInt64(0)
    cbits = 0
    sbits = 0
    out = UInt8[]
    sizehint!(out, length(bytes))
    for b in bytes
        cur = (cur << 8) | UInt64(b)
        cbits += 8
        sbits += 8
        while cbits >= 8
            node = nodes[Int(n)]
            children = node.children
            children === nothing && throw(ParseError("invalid HPACK Huffman-encoded data"))
            idx = Int((cur >> (cbits - 8)) & UInt64(0xff)) + 1
            next = children[idx]
            next == 0 && throw(ParseError("invalid HPACK Huffman-encoded data"))
            next_node = nodes[Int(next)]
            if next_node.children === nothing
                push!(out, UInt8(next_node.sym))
                cbits -= Int(next_node.code_len)
                n = root
                sbits = cbits
            else
                cbits -= 8
                n = next
            end
        end
    end
    # Consume remaining prefix bits that still map to complete symbols.
    while cbits > 0
        node = nodes[Int(n)]
        children = node.children
        children === nothing && throw(ParseError("invalid HPACK Huffman-encoded data"))
        idx = Int((cur << (8 - cbits)) & UInt64(0xff)) + 1
        next = children[idx]
        next == 0 && throw(ParseError("invalid HPACK Huffman-encoded data"))
        next_node = nodes[Int(next)]
        if next_node.children !== nothing || Int(next_node.code_len) > cbits
            break
        end
        push!(out, UInt8(next_node.sym))
        cbits -= Int(next_node.code_len)
        n = root
        sbits = cbits
    end
    sbits > 7 && throw(ParseError("invalid HPACK Huffman-encoded data"))
    # RFC 7541 §5.2: trailing bits must be a prefix of EOS (all ones).
    if cbits > 0
        mask = (UInt64(1) << cbits) - 1
        (cur & mask) == mask || throw(ParseError("invalid HPACK Huffman-encoded data"))
    end
    return String(out)
end

@inline function _entry_size(name::String, value::String)::Int
    return 32 + ncodeunits(name) + ncodeunits(value)
end

function DynamicTable(max_size::Integer=4096)
    max_size >= 0 || throw(ArgumentError("dynamic table max_size must be >= 0"))
    return DynamicTable(DynamicTableEntry[], Int(max_size), 0)
end

"""
    Encoder(; max_table_size=4096)

Create an HPACK encoder with a bounded dynamic table.
"""
function Encoder(; max_table_size::Integer=4096)
    max_table_size >= 0 || throw(ArgumentError("dynamic table max_size must be >= 0"))
    size = Int(max_table_size)
    return Encoder(DynamicTable(size), typemax(Int), size, false)
end

"""
    Decoder(; max_table_size=4096)

Create an HPACK decoder with a bounded dynamic table.
"""
function Decoder(; max_table_size::Integer=4096)
    return Decoder(DynamicTable(max_table_size))
end

"""
    set_max_dynamic_table_size!(table_or_codec, max_size)

Resize dynamic table capacity and evict old entries as needed.
"""
function set_max_dynamic_table_size!(table::DynamicTable, max_size::Integer)
    max_size >= 0 || throw(ArgumentError("dynamic table max_size must be >= 0"))
    table.max_size = Int(max_size)
    while table.current_size > table.max_size && !isempty(table.entries)
        evicted = pop!(table.entries)
        table.current_size -= evicted.size
    end
    return nothing
end

function set_max_dynamic_table_size!(encoder::Encoder, max_size::Integer)
    max_size >= 0 || throw(ArgumentError("dynamic table max_size must be >= 0"))
    bounded = min(Int(max_size), encoder.max_table_size_limit)
    if bounded < encoder.min_table_size
        encoder.min_table_size = bounded
    end
    encoder.table_size_update = true
    set_max_dynamic_table_size!(encoder.table, bounded)
    return nothing
end

function set_max_dynamic_table_size_limit!(encoder::Encoder, max_size::Integer)
    max_size >= 0 || throw(ArgumentError("dynamic table max_size must be >= 0"))
    encoder.max_table_size_limit = Int(max_size)
    if encoder.table.max_size > encoder.max_table_size_limit
        encoder.table_size_update = true
        set_max_dynamic_table_size!(encoder.table, encoder.max_table_size_limit)
    end
    return nothing
end

function set_max_dynamic_table_size!(decoder::Decoder, max_size::Integer)
    set_max_dynamic_table_size!(decoder.table, max_size)
    return nothing
end

function _add_dynamic_entry!(table::DynamicTable, name::String, value::String)
    size = _entry_size(name, value)
    if size > table.max_size
        empty!(table.entries)
        table.current_size = 0
        return nothing
    end
    while table.current_size + size > table.max_size && !isempty(table.entries)
        evicted = pop!(table.entries)
        table.current_size -= evicted.size
    end
    pushfirst!(table.entries, DynamicTableEntry(name, value, size))
    table.current_size += size
    return nothing
end

function _table_get(table::DynamicTable, index::Int)::HeaderField
    if index <= length(_STATIC_TABLE)
        return _STATIC_TABLE[index]
    end
    dynamic_index = index - length(_STATIC_TABLE)
    (dynamic_index < 1 || dynamic_index > length(table.entries)) && throw(ProtocolError("HPACK index out of range"))
    entry = table.entries[dynamic_index]
    return HeaderField(entry.name, entry.value, false)
end

function _find_exact_index(table::DynamicTable, name::String, value::String)::Int
    for i in 1:length(_STATIC_TABLE)
        entry = _STATIC_TABLE[i]
        if entry.name == name && entry.value == value
            return i
        end
    end
    for i in 1:length(table.entries)
        entry = table.entries[i]
        if entry.name == name && entry.value == value
            return length(_STATIC_TABLE) + i
        end
    end
    return 0
end

function _find_name_index(table::DynamicTable, name::String)::Int
    for i in 1:length(_STATIC_TABLE)
        entry = _STATIC_TABLE[i]
        entry.name == name && return i
    end
    for i in 1:length(table.entries)
        entry = table.entries[i]
        entry.name == name && return length(_STATIC_TABLE) + i
    end
    return 0
end

function _encode_integer!(out::Vector{UInt8}, value::Int, prefix_bits::Int, prefix_mask::UInt8)
    value >= 0 || throw(ArgumentError("HPACK integer must be >= 0"))
    max_prefix = (1 << prefix_bits) - 1
    if value < max_prefix
        push!(out, prefix_mask | UInt8(value))
        return nothing
    end
    push!(out, prefix_mask | UInt8(max_prefix))
    n = value - max_prefix
    while n >= 128
        push!(out, UInt8((n & 0x7f) | 0x80))
        n >>>= 7
    end
    push!(out, UInt8(n))
    return nothing
end

function _decode_integer(data::Vector{UInt8}, index::Int, prefix_bits::Int)::Tuple{Int,Int}
    index <= length(data) || throw(ParseError("HPACK integer decode out of bounds"))
    max_prefix = (1 << prefix_bits) - 1
    value = Int(data[index] & UInt8(max_prefix))
    index += 1
    if value < max_prefix
        return value, index
    end
    shift = 0
    while true
        index <= length(data) || throw(ParseError("HPACK integer continuation overflow"))
        b = data[index]
        index += 1
        value += Int(b & 0x7f) << shift
        (b & 0x80) == 0 && return value, index
        shift += 7
        shift <= 56 || throw(ParseError("HPACK integer too large"))
    end
end

function _encode_string!(out::Vector{UInt8}, value::String)
    raw_len = ncodeunits(value)
    huff_len = _huffman_encoded_length(value)
    # Only choose Huffman when it produces a strictly smaller payload. This
    # keeps encode/decode behavior predictable and avoids paying the CPU cost
    # for ties.
    if huff_len < raw_len
        _encode_integer!(out, huff_len, 7, 0x80)
        _append_huffman_string!(out, value)
        return nothing
    end
    _encode_integer!(out, raw_len, 7, 0x00)
    append!(out, codeunits(value))
    return nothing
end

function _decode_string(data::Vector{UInt8}, index::Int)::Tuple{String,Int}
    index <= length(data) || throw(ParseError("HPACK string decode out of bounds"))
    huffman = (data[index] & 0x80) != 0
    len, index = _decode_integer(data, index, 7)
    end_index = index + len - 1
    end_index <= length(data) || throw(ParseError("HPACK string length exceeds payload"))
    bytes = data[index:end_index]
    if huffman
        return _decode_huffman_string(bytes), end_index + 1
    end
    return String(bytes), end_index + 1
end

function _encode_literal_with_indexing!(out::Vector{UInt8}, table::DynamicTable, name::String, value::String)
    name_index = _find_name_index(table, name)
    if name_index > 0
        _encode_integer!(out, name_index, 6, 0x40)
    else
        _encode_integer!(out, 0, 6, 0x40)
        _encode_string!(out, name)
    end
    _encode_string!(out, value)
    _add_dynamic_entry!(table, name, value)
    return nothing
end

@inline function _encode_literal_type_byte(indexing::Bool, sensitive::Bool)::UInt8
    if sensitive
        return 0x10
    end
    if indexing
        return 0x40
    end
    return 0x00
end

function _encode_literal_new_name!(
    out::Vector{UInt8},
    name::String,
    value::String,
    indexing::Bool,
    sensitive::Bool,
)
    push!(out, _encode_literal_type_byte(indexing, sensitive))
    _encode_string!(out, name)
    _encode_string!(out, value)
    return nothing
end

function _encode_literal_indexed_name!(
    out::Vector{UInt8},
    name_index::Int,
    value::String,
    indexing::Bool,
    sensitive::Bool,
)
    if indexing
        _encode_integer!(out, name_index, 6, 0x40)
    else
        _encode_integer!(out, name_index, 4, _encode_literal_type_byte(false, sensitive))
    end
    _encode_string!(out, value)
    return nothing
end

@inline function _should_index_header(encoder::Encoder, header::HeaderField)::Bool
    header.sensitive && return false
    return _entry_size(header.name, header.value) <= encoder.table.max_size
end

function _emit_table_size_updates!(out::Vector{UInt8}, encoder::Encoder)
    if !encoder.table_size_update
        return nothing
    end
    encoder.table_size_update = false
    if encoder.min_table_size < encoder.table.max_size
        _encode_integer!(out, encoder.min_table_size, 5, 0x20)
    end
    encoder.min_table_size = typemax(Int)
    _encode_integer!(out, encoder.table.max_size, 5, 0x20)
    return nothing
end

function _encode_indexed!(out::Vector{UInt8}, index::Int)
    _encode_integer!(out, index, 7, 0x80)
    return nothing
end

"""
    encode_header_block(encoder, headers)

Encode HPACK header fields into one HPACK header block fragment.

The returned `Vector{UInt8}` is suitable for a single HEADERS/CONTINUATION
fragment sequence. The encoder's dynamic table may be mutated as a side effect.
Throws `ArgumentError` for invalid sizing inputs and `ProtocolError` if an
indexed lookup becomes inconsistent.
"""
function encode_header_block(encoder::Encoder, headers::Vector{HeaderField})::Vector{UInt8}
    out = UInt8[]
    _emit_table_size_updates!(out, encoder)
    for header in headers
        # Prefer the most compact representation available: exact indexed
        # match, indexed-name literal with optional insertion, then literal
        # new-name forms.
        exact = _find_exact_index(encoder.table, header.name, header.value)
        if exact > 0
            _encode_indexed!(out, exact)
            continue
        end
        indexing = _should_index_header(encoder, header)
        if indexing
            _encode_literal_with_indexing!(out, encoder.table, header.name, header.value)
            continue
        end
        name_index = _find_name_index(encoder.table, header.name)
        if name_index == 0
            _encode_literal_new_name!(out, header.name, header.value, false, header.sensitive)
        else
            _encode_literal_indexed_name!(out, name_index, header.value, false, header.sensitive)
        end
    end
    return out
end

function _decode_literal!(
    decoder::Decoder,
    data::Vector{UInt8},
    index::Int,
    prefix_bits::Int,
    should_index::Bool,
    sensitive::Bool,
)::Tuple{HeaderField,Int}
    name_index, index = _decode_integer(data, index, prefix_bits)
    name = if name_index == 0
        decoded_name, next_index = _decode_string(data, index)
        index = next_index
        decoded_name
    else
        _table_get(decoder.table, name_index).name
    end
    value, index = _decode_string(data, index)
    should_index && _add_dynamic_entry!(decoder.table, name, value)
    return HeaderField(name, value, sensitive), index
end

"""
    decode_header_block(decoder, block)

Decode one HPACK header block fragment into a `Vector{HeaderField}`.

The decoder's dynamic table is updated as encoded instructions are processed.
Throws `ParseError` for malformed integer/string encodings and `ProtocolError`
for invalid indexing semantics.
"""
function decode_header_block(decoder::Decoder, block::Vector{UInt8})::Vector{HeaderField}
    headers = HeaderField[]
    index = 1
    saw_header_field = false
    while index <= length(block)
        b = block[index]
        if (b & 0x80) != 0
            idx, index = _decode_integer(block, index, 7)
            push!(headers, _table_get(decoder.table, idx))
            saw_header_field = true
            continue
        end
        if (b & 0x40) != 0
            header, index = _decode_literal!(decoder, block, index, 6, true, false)
            push!(headers, header)
            saw_header_field = true
            continue
        end
        if (b & 0x20) != 0
            saw_header_field && throw(ParseError("HPACK dynamic table size update must appear before header fields"))
            size, index = _decode_integer(block, index, 5)
            set_max_dynamic_table_size!(decoder, size)
            continue
        end
        if (b & 0x10) != 0
            header, index = _decode_literal!(decoder, block, index, 4, false, true)
            push!(headers, header)
            saw_header_field = true
            continue
        end
        should_index = false
        header, index = _decode_literal!(decoder, block, index, 4, should_index, false)
        push!(headers, header)
        saw_header_field = true
    end
    return headers
end
