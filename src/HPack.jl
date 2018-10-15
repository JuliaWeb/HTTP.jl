"""
Lazy Parsing and String comparison for
[RFC7541](https://tools.ietf.org/html/rfc7541)
"HPACK Header Compression for HTTP/2".

Copyright (c) 2018, Sam O'Connor

huffmandata.jl and hp_huffman_encode created by Wei Tang:
Copyright (c) 2016: Wei Tang, MIT "Expat" License:
https://github.com/sorpaas/HPack.jl/blob/master/LICENSE.md
"""
module HPack

include("Nibbles.jl")

abstract type DecodingError <: Exception end

struct IntegerDecodingError <: DecodingError end
struct FieldBoundsError <: DecodingError end
struct IndexBoundsError <: DecodingError end
struct TableUpdateError <: DecodingError end

function Base.show(io::IO, ::IntegerDecodingError)
    println(io, """
        HPack.IntegerDecodingError()
            Encoded integer length exceeds Implementation Limit (~ 2097278).
            See: https://tools.ietf.org/html/rfc7541#section-7.4
        """)
end

function Base.show(io::IO, ::FieldBoundsError)
    println(io, """
        HPack.FieldBoundsError()
            Encoded field length exceeds Header Block size.
        """)
end

function Base.show(io::IO, ::IndexBoundsError)
    println(io, """
        HPack.IndexBoundsError()
            Encoded field index exceeds Dynamic Table size.
        """)
end

function Base.show(io::IO, ::TableUpdateError)
    println(io, """
        HPack.TableUpdateError()
            This dynamic table size update MUST occur at the beginning of the
            first header block following the change to the dynamic table size.
            https://tools.ietf.org/html/rfc7541#section-4.2
        """)
end

# Integers

"""
Decode integer at index `i` in `buf` with prefix `mask`.
Return the index of next byte in `buf` and the decoded value.

> An integer is represented in two parts: a prefix that fills the
> current octet and an optional list of octets that are used if the
> integer value does not fit within the prefix.  The number of bits of
> the prefix (called N) is a parameter of the integer representation.

> If the integer value is small enough, i.e., strictly less than 2^N-1,
> it is encoded within the N-bit prefix.

https://tools.ietf.org/html/rfc7541#section-5.1
"""
function hp_integer(buf::Array{UInt8}, i::UInt, mask::UInt8)::Tuple{UInt,UInt}

    v = @inbounds UInt(buf[i]) & mask
    i += 1
    if v >= mask
        c = @inbounds buf[i]
        i += 1
        v += UInt(c & 0b01111111)
        if c & 0b10000000 != 0

            c = @inbounds buf[i]
            i += 1
            v += UInt(c & 0b01111111) << (1 * 7)
            if c & 0b10000000 != 0

                c = @inbounds buf[i]
                i += 1
                v += UInt(c & 0b01111111) << (2 * 7)
                if c & 0b10000000 != 0
                    throw(IntegerDecodingError())
                end
            end
        end
    end
    return i, v
end

hp_integer(buf, i, mask) = hp_integer(buf, UInt(i), mask)

#=
function hp_integer_nexti(buf::Array{UInt8}, i::UInt,
                          mask::UInt8, flags::UInt8)::UInt

    if flags & mask == mask
        flags = @inbounds v[i += 1]
        while flags & 0b10000000 != 0
            flags = @inbounds v[i += 1]
        end
    end
    i += 1
    if i > length(buf) + 1                         # Allow next i to be one past
        throw(IntegerDecodingError())              # the end of the buffer.
    end
    return i
end
=#


# Huffman Encoded Strings

include("huffmandata.jl")

struct Huffman
    nibbles::typeof(Iterators.Stateful(Nibbles.Iterator(UInt8[])))
end

Huffman(bytes::AbstractVector{UInt8}, i, j) =
    Huffman(Iterators.Stateful(Nibbles.Iterator(bytes, i, j)))

Base.eltype(::Type{Huffman}) = UInt8

Base.IteratorSize(::Type{Huffman}) = Base.SizeUnknown()

function Base.iterate(s::Huffman, state::UInt = UInt(0))
    for n in s.nibbles
        state::UInt, flags, c = HUFFMAN_DECODE_TABLE[(state << 4) + n + 1, :]
        if flags & 0x04 != 0
            return nothing
        elseif flags & 0x02 != 0
            return c, state
        end
    end
    return nothing
end


function hp_huffman_encode(data)
    out = IOBuffer()
    current::UInt64 = 0
    n = 0

    for i = 1:length(data)
        b = data[i] & 0xFF
        nbits = HUFFMAN_SYMBOL_TABLE[b + 1, 1]
        code = HUFFMAN_SYMBOL_TABLE[b + 1, 2]

        current <<= nbits
        current |= code
        n += nbits

        while n >= 8
            n -= 8
            write(out, UInt8(current >>> n))
            current = current & ~(current >>> n << n)
        end
    end

    if n > 0
        current <<= (8 - n)
        current |= (0xFF >>> n)
        write(out, UInt8(current))
    end

    return take!(out)
end



# HPack Strings

"""
`HPackString` fields:
 - `bytes`: reference a HPACK header block.
 - `i`: index of the start of a string literal in the header block.

> Header field names and header field values can be represented as
> string literals.  A string literal is encoded as a sequence of
> octets, either by directly encoding the string literal's octets or by
> using a Huffman code (see [HUFFMAN]).
>
>   0   1   2   3   4   5   6   7
> +---+---+---+---+---+---+---+---+
> | H |    String Length (7+)     |
> +---+---------------------------+
> |  String Data (Length octets)  |
> +-------------------------------+
>
> String Data:  The encoded data of the string literal.  If H is '0',
>    then the encoded data is the raw octets of the string literal.  If
>    H is '1', then the encoded data is the Huffman encoding of the
>    string literal.

https://tools.ietf.org/html/rfc7541#section-5.2
"""
struct HPackString
    bytes::Vector{UInt8}
    i::UInt
end

@inline HPackString(s::HPackString) = HPackString(s.bytes, s.i)

HPackString() = HPackString("")

@inline HPackString(bytes::Vector{UInt8}, i::Integer=1) =
    HPackString(bytes, UInt(i))

function HPackString(s)
    @assert length(s) < 127
    buf = IOBuffer()
    write(buf, UInt8(length(s)))
    write(buf, s)
    HPackString(take!(buf), 1)
end

@inline function hp_string_nexti(buf::Array{UInt8}, i::UInt)
    j, l = hp_string_length(buf, i)
    return j + l
end

@inline hp_ishuffman(s::HPackString) = hp_ishuffman(@inbounds s.bytes[s.i])

@inline hp_ishuffman(flags::UInt8) = flags & 0b10000000 != 0

@inline function hp_string_length(bytes, i)::Tuple{UInt,UInt}
    i, l = hp_integer(bytes, i, 0b01111111)
    if i + l > length(bytes) + 1                   # Allow next i to be one past
        throw(FieldBoundsError())                  # the end of the buffer.
    end
    return i, l
end

@inline hp_string_length(s::HPackString)::Tuple{UInt,UInt} =
    hp_string_length(s.bytes, s.i)

Base.length(s::HPackString) =
    hp_ishuffman(s) ? (l = 0; for c in s l += 1 end; l) : hp_string_length(s)[2]

Base.eltype(::Type{HPackString}) = UInt8

Base.IteratorSize(::Type{HPackString}) = Base.SizeUnknown()

const StrItrState = Tuple{Union{Huffman, UInt}, UInt}
const StrItrReturn = Union{Nothing, Tuple{UInt8, StrItrState}}

@inline function Base.iterate(s::HPackString)::StrItrReturn
    i, l = hp_string_length(s)
    max = i + l - 1
    if hp_ishuffman(s)
        h = Huffman(s.bytes, i, max)
        return hp_iterate_huffman(h, UInt(0))
    else
        return hp_iterate_ascii(s.bytes, max, i)
    end
end

@inline function hp_iterate_huffman(h::Huffman, i::UInt)::StrItrReturn
    hstate = iterate(h, i)
    if hstate == nothing
        return nothing
    end
    c, i = hstate
    return c, (h, i)
end

@inline function hp_iterate_ascii(bytes, max::UInt, i::UInt)::StrItrReturn
    if i > max
        return nothing
    end
    return (@inbounds bytes[i], (max, i+1))
end

@inline function Base.iterate(s::HPackString, state::StrItrState)::StrItrReturn
    huf_or_max, i = state
    return huf_or_max isa Huffman ? hp_iterate_huffman(huf_or_max, i) :
                                    hp_iterate_ascii(s.bytes, huf_or_max, i)
end


# Conversion to Base.String

"""
Copy raw ASCII bytes into new String.
Collect decoded Huffman bytes into new String.
"""
function Base.convert(::Type{String}, s::HPackString)
    if hp_ishuffman(s)
        return String(collect(s))
    else
        i, l = hp_string_length(s)
        buf = Base.StringVector(l)
        unsafe_copyto!(buf, 1, s.bytes, i, l)
        return String(buf)
    end
end

Base.string(s::HPackString) = convert(String, s)
Base.print(io::IO, s::HPackString) = print(io, string(s))
Base.show(io::IO, s::HPackString) = show(io, string(s))


# String Comparison

import Base.==

==(a::HPackString, b::HPackString) = hp_cmp_hpack_hpack(a, b)
==(a::HPackString, b) = hp_cmp(a, b)
==(a, b::HPackString) = hp_cmp(b, a)

function hp_cmp_hpack_hpack(a::HPackString, b::HPackString)

    if hp_ishuffman(a) != hp_ishuffman(b)
        return hp_cmp(a, b)
    end

    if @inbounds a.bytes[a.i] != b.bytes[b.i]
        return false
    end
    ai, al = hp_string_length(a)
    bi, bl = hp_string_length(b)
    if al != bl
        return false
    end
    return Base._memcmp(pointer(a.bytes, ai),
                        pointer(b.bytes, bi), al) == 0
end

const StringLike = Union{String, SubString{String}}

function hp_cmp(a::HPackString, b::StringLike)
    if hp_ishuffman(a)
        return hp_cmp(a, codeunits(b))
    end
    ai, al = hp_string_length(a)
    if al != length(b)
        return false
    end
    return Base._memcmp(pointer(a.bytes, ai),
                        pointer(b), al) == 0
end

function hp_cmp(a, b)
    ai = Iterators.Stateful(a)
    bi = Iterators.Stateful(b)
    for (i, j) in zip(ai, bi)
        if i != j
            return false
        end
    end
    return isempty(ai) && isempty(bi)
end

hp_cmp(a::HPackString, b::AbstractString) = hp_cmp(a, (UInt(c) for c in b))


# Connection State

mutable struct HPackSession
    names::Vector{HPackString}
    values::Vector{HPackString}
    max_table_size::UInt
    table_size::UInt
end

function Base.show(io::IO, s::HPackSession)
    println(io, "HPackSession with Table Size $(s.table_size):")
    i = hp_static_max + 1
    for (n, v) in zip(s.names, s.values)
        println(io, "    [$i] $n: $v")
        i += 1
    end
    println(io, "")
end

HPackSession() = HPackSession([],[],default_max_table_size,0)

#https://tools.ietf.org/html/rfc7540#section-6.5.2
const default_max_table_size = 4096

function set_max_table_size(s::HPackSession, n)
    s.max_table_size = n
    purge(s)
end

function purge(s::HPackSession)
    return #FIXME can't purge stuff that old lazy blocks may refer to.
    while s.table_size > s.max_table_size
        s.table_size -= hp_field_size(s, lastindex(s.names))
        pop!(s)
    end
end

function Base.pop!(s::HPackSession)
    pop!(s.names)
    pop!(s.values)
end

"""
The size of an entry is the sum of its name's length in octets (as
defined in Section 5.2), its value's length in octets, and 32.
https://tools.ietf.org/html/rfc7541#section-4.1
"""
hp_field_size(s, i) = hp_string_length(s.names[i])[2] +
                      hp_string_length(s.values[i])[2] +
                      32
# Note: implemented as the non huffman decoded length.
# More efficient than decoding and probably has no
# impact other than slightly fewer evictions than normal.
# See https://github.com/http2/http2-spec/issues/767
# Strict decoded length version is:
# hp_field_size(field) = length(field.first) +
#                        length(field.second) +
#                        32


const table_index_flag = UInt(1) << 63
is_tableindex(i) = i > table_index_flag
is_dynamicindex(i) = i > (table_index_flag | hp_static_max)

@noinline function Base.pushfirst!(s::HPackSession, bytes,
                         namei::UInt, valuei::UInt, offset::UInt)

    name = is_tableindex(namei) ? get_name(s, namei, offset) :
                                  HPackString(bytes, namei)

    value = is_tableindex(valuei) ? get_value(s, valuei, offset) :
                                    HPackString(bytes, valuei)
    pushfirst!(s.names, name)
    pushfirst!(s.values, value)

    s.table_size += hp_field_size(s, 1)
    purge(s)
end

Base.lastindex(s::HPackSession) = hp_static_max + lastindex(s.names)

function get_name(s::HPackSession, i::UInt, offset::UInt=0)::HPackString
    i &= ~table_index_flag
    if i + offset > lastindex(s)
        throw(IndexBoundsError())
    end
    return i <= hp_static_max ? hp_static_names[i] :
                                s.names[i + offset - hp_static_max]
end

function get_value(s::HPackSession, i::UInt, offset::UInt=0)::HPackString
    i &= ~table_index_flag
    if i + offset > lastindex(s)
        throw(IndexBoundsError())
    end
    return i <= hp_static_max ? hp_static_values[i] :
                                s.values[i + offset - hp_static_max]
end

# Header Fields

mutable struct HPackBlock
    session::HPackSession
    bytes::Vector{UInt8}
    i::UInt
    cursor::UInt
    offset::UInt
end

                                     # FIXME
                                     # Copy of HPackString might allow iteration
                                     # loop optimisation to eliminate struct?
@inline get_name(b::HPackBlock, i::UInt, offset::UInt)::HPackString =
    is_tableindex(i) ? HPackString(get_name(b.session, i, offset)) :
                       HPackString(b.bytes, i)

@inline get_value(b::HPackBlock, i::UInt, offset::UInt)::HPackString =
    is_tableindex(i) ? HPackString(get_value(b.session, i, offset)) :
                       HPackString(b.bytes, i)

HPackBlock(session, bytes, i) = HPackBlock(session, bytes, i, 0, 0)

Base.getproperty(h::HPackBlock, s::Symbol) =
    s === :authority  ? h[":authority"]  :
    s === :method     ? h[":method"]     :
    s === :path       ? h[":path"]       :
    s === :scheme     ? h[":scheme"]     :
    s === :status     ? h[":status"]     :
                        getfield(h, s)

function Base.getindex(b::HPackBlock, key)
    for (n, v) in b
        if n == key
            return v
        end
    end
    throw(KeyError(key))
end

#=
hp_field_nexti(buf, i) = hp_field_nexti(buf, i, @inbounds buf[i])

function hp_field_nexti(buf::Vector{UInt8}, i::UInt, flags::UInt8)::UInt

    int_mask, string_count = hp_field_format(buf, i, flags)

    if int_mask != 0
        i = hp_integer_nexti(buf, i, int_mask, flags)
    else
        i += 1
    end
    while string_count > 0
        i = hp_string_nexti(buf, i)
        string_count -= 1
    end
    @assert i <= length(buf) + 1
    return i
end
=#


# Iteration Interface

struct BlockKeys   b::HPackBlock end
struct BlockValues b::HPackBlock end

Base.eltype(::Type{BlockKeys})   = HPackString
Base.eltype(::Type{BlockValues}) = HPackString
Base.eltype(::Type{HPackBlock})  = Pair{HPackString, HPackString}

Base.keys(b::HPackBlock)   = BlockKeys(b)
Base.values(b::HPackBlock) = BlockValues(b)

const BlockIterator = Union{BlockKeys, BlockValues, HPackBlock}

Base.IteratorSize(::BlockIterator) = Base.SizeUnknown()

@inline function Base.iterate(bi::BlockIterator)

    b::HPackBlock = bi isa HPackBlock ? bi : bi.b
    buf = b.bytes
    i = b.i
    flags = @inbounds buf[i]

    # 6.3 Dynamic Table Size Update
    #   0   1   2   3   4   5   6   7
    # +---+---+---+---+---+---+---+---+
    # | 0 | 0 | 1 |   Max size (5+)   |
    # +---+---------------------------+
    if flags & 0b11100000 == 0b00100000
        i, table_size = hp_integer(buf, i, 0b00011111)
        if b.cursor == 0
            b.cursor = i
            @assert table_size < 64000  #FIXME Limit to HTTP setting value
            set_max_table_size(b.session, table_size)
        end
    end
    return iterate(bi, (i, b.offset))
end

@inline function Base.iterate(bi::BlockIterator, state::Tuple{UInt,UInt})

    b::HPackBlock = bi isa HPackBlock ? bi : bi.b
    buf = b.bytes
    i, offset = state

    if i > length(buf)
        return nothing
    end

    flags = @inbounds buf[i]
    name, value, i = hp_field(buf, i, flags)

    v = bi isa BlockKeys   ? get_name(b, name, offset) :
        bi isa BlockValues ? get_value(b, value, offset) :
                             get_name(b, name, offset) =>
                             get_value(b, value, offset)

    # 6.2.1.  Literal Header Field with Incremental Indexing
    if flags & 0b11000000 == 0b01000000
        if i <= b.cursor
            offset -= 1
        else
            b.cursor = i
            b.offset += 1
            pushfirst!(b.session, buf, name, value, offset)
        end
    end

    return v, (i, offset)
end

const nobytes = UInt8[]

@noinline function hp_field(buf, i::UInt, flags::UInt8)::
                            Tuple{UInt,UInt,UInt}

    int_mask, string_count = hp_field_format(buf, i, flags)

    # 6.3 Dynamic Table Size Update
    if int_mask == 0b00011111
        throw(TableUpdateError())
    end

    if int_mask != 0
        i, idx = hp_integer(buf, i, int_mask)
        if idx == 0
            throw(IndexBoundsError())
        end
        name = idx | table_index_flag
        if string_count == 0
            value = idx | table_index_flag
        else
            value = i
            i = hp_string_nexti(buf, i)
        end
    else
        name = i + 1
        value = hp_string_nexti(buf, name)
        i = hp_string_nexti(buf, value)
    end

    return name, value, i
end

function hp_field_format(buf::Vector{UInt8}, i::UInt, flags::UInt8)

    int_mask::UInt8 = 0
    string_count = 0

    # Headings below are from: https://tools.ietf.org/html/rfc7541

    # 6.1. Indexed Header Field
    #   0   1   2   3   4   5   6   7
    # +---+---+---+---+---+---+---+---+
    # | 1 |        Index (7+)         |
    # +---+---------------------------+
    if flags & 0b10000000 != 0
        int_mask = 0b01111111

    # 6.2.1. Literal Header Field
    # (or 6.2.2. Literal Header Field without Indexing)
    # (or 6.2.3. Literal Header Field Never Indexed)
    #  0   1   2   3   4   5   6   7
    # +---+---+---+---+---+---+---+---+
    # | 0 | 1 |           0           |
    # +---+---+-----------------------+
    # | H |     Name Length (7+)      |
    # +---+---------------------------+
    # |  Name String (Length octets)  |
    # +---+---------------------------+
    # | H |     Value Length (7+)     |
    # +---+---------------------------+
    # | Value String (Length octets)  |
    # +-------------------------------+
    elseif flags == 0b01000000 ||
           flags == 0b00010000 ||
           flags == 0b00000000
        string_count = 2

    # 6.2.1. Literal Header Field
    #   0   1   2   3   4   5   6   7
    # +---+---+---+---+---+---+---+---+
    # | 0 | 1 |      Index (6+)       |
    # +---+---+-----------------------+
    # | H |     Value Length (7+)     |
    # +---+---------------------------+
    # | Value String (Length octets)  |
    # +-------------------------------+
    elseif flags & 0b01000000 != 0
        int_mask = 0b00111111
        string_count = 1

    # 6.3 Dynamic Table Size Update
    #   0   1   2   3   4   5   6   7
    # +---+---+---+---+---+---+---+---+
    # | 0 | 0 | 1 |   Max size (5+)   |
    # +---+---------------------------+
    elseif flags & 0b00100000 != 0
        int_mask = 0b00011111

    # 6.2.3.  Literal Header Field Never Indexed
    # (or 6.2.2.  Literal Header Field without Indexing)
    #   0   1   2   3   4   5   6   7
    # +---+---+---+---+---+---+---+---+
    # | 0 | 0 | 0 | 1 |  Index (4+)   |
    # +---+---+-----------------------+
    # | H |     Value Length (7+)     |
    # +---+---------------------------+
    # | Value String (Length octets)  |
    # +-------------------------------+
    else
        int_mask = 0b00001111
        string_count = 1
    end

    return int_mask, string_count
end

const hp_static_strings = [
    ":authority" => "",
    ":method" => "GET",
    ":method" => "POST",
    ":path" => "/",
    ":path" => "/index.html",
    ":scheme" => "http",
    ":scheme" => "https",
    ":status" => "200",
    ":status" => "204",
    ":status" => "206",
    ":status" => "304",
    ":status" => "400",
    ":status" => "404",
    ":status" => "500",
    "accept-" => "",
    "accept-encoding" => "gzip, deflate",
    "accept-language" => "",
    "accept-ranges" => "",
    "accept" => "",
    "access-control-allow-origin" => "",
    "age" => "",
    "allow" => "",
    "authorization" => "",
    "cache-control" => "",
    "content-disposition" => "",
    "content-encoding" => "",
    "content-language" => "",
    "content-length" => "",
    "content-location" => "",
    "content-range" => "",
    "content-type" => "",
    "cookie" => "",
    "date" => "",
    "etag" => "",
    "expect" => "",
    "expires" => "",
    "from" => "",
    "host" => "",
    "if-match" => "",
    "if-modified-since" => "",
    "if-none-match" => "",
    "if-range" => "",
    "if-unmodified-since" => "",
    "last-modified" => "",
    "link" => "",
    "location" => "",
    "max-forwards" => "",
    "proxy-authenticate" => "",
    "proxy-authorization" => "",
    "range" => "",
    "referer" => "",
    "refresh" => "",
    "retry-after" => "",
    "server" => "",
    "set-cookie" => "",
    "strict-transport-security" => "",
    "transfer-encoding" => "",
    "user-agent" => "",
    "vary" => "",
    "via" => "",
    "www-authenticate" => ""
]

const hp_static_max = lastindex(hp_static_strings)
const hp_static_names = [HPackString(n) for (n, v) in hp_static_strings]
const hp_static_values = [HPackString(v) for (n, v) in hp_static_strings]

end # module HPack
