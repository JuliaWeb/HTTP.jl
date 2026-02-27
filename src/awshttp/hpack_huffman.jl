# HPACK Huffman encoding/decoding (RFC 7541 Appendix B)
# Port of aws-c-http/source/hpack_huffman_static.c + aws-c-compression/source/huffman.c

# ─── Huffman code point ───

struct HuffmanCode
    pattern::UInt32
    num_bits::UInt8
end

# ─── RFC 7541 Appendix B: HPACK Huffman table (256 symbols) ───
# Index = symbol value + 1 (1-indexed Julia array)

const HPACK_HUFFMAN_CODES = HuffmanCode[
    HuffmanCode(0x1ff8, 13),     #   0
    HuffmanCode(0x7fffd8, 23),   #   1
    HuffmanCode(0xfffffe2, 28),  #   2
    HuffmanCode(0xfffffe3, 28),  #   3
    HuffmanCode(0xfffffe4, 28),  #   4
    HuffmanCode(0xfffffe5, 28),  #   5
    HuffmanCode(0xfffffe6, 28),  #   6
    HuffmanCode(0xfffffe7, 28),  #   7
    HuffmanCode(0xfffffe8, 28),  #   8
    HuffmanCode(0xffffea, 24),   #   9
    HuffmanCode(0x3ffffffc, 30), #  10
    HuffmanCode(0xfffffe9, 28),  #  11
    HuffmanCode(0xfffffea, 28),  #  12
    HuffmanCode(0x3ffffffd, 30), #  13
    HuffmanCode(0xfffffeb, 28),  #  14
    HuffmanCode(0xfffffec, 28),  #  15
    HuffmanCode(0xfffffed, 28),  #  16
    HuffmanCode(0xfffffee, 28),  #  17
    HuffmanCode(0xfffffef, 28),  #  18
    HuffmanCode(0xffffff0, 28),  #  19
    HuffmanCode(0xffffff1, 28),  #  20
    HuffmanCode(0xffffff2, 28),  #  21
    HuffmanCode(0x3ffffffe, 30), #  22
    HuffmanCode(0xffffff3, 28),  #  23
    HuffmanCode(0xffffff4, 28),  #  24
    HuffmanCode(0xffffff5, 28),  #  25
    HuffmanCode(0xffffff6, 28),  #  26
    HuffmanCode(0xffffff7, 28),  #  27
    HuffmanCode(0xffffff8, 28),  #  28
    HuffmanCode(0xffffff9, 28),  #  29
    HuffmanCode(0xffffffa, 28),  #  30
    HuffmanCode(0xffffffb, 28),  #  31
    HuffmanCode(0x14, 6),        #  32 ' '
    HuffmanCode(0x3f8, 10),      #  33 '!'
    HuffmanCode(0x3f9, 10),      #  34 '"'
    HuffmanCode(0xffa, 12),      #  35 '#'
    HuffmanCode(0x1ff9, 13),     #  36 '$'
    HuffmanCode(0x15, 6),        #  37 '%'
    HuffmanCode(0xf8, 8),        #  38 '&'
    HuffmanCode(0x7fa, 11),      #  39 '\''
    HuffmanCode(0x3fa, 10),      #  40 '('
    HuffmanCode(0x3fb, 10),      #  41 ')'
    HuffmanCode(0xf9, 8),        #  42 '*'
    HuffmanCode(0x7fb, 11),      #  43 '+'
    HuffmanCode(0xfa, 8),        #  44 ','
    HuffmanCode(0x16, 6),        #  45 '-'
    HuffmanCode(0x17, 6),        #  46 '.'
    HuffmanCode(0x18, 6),        #  47 '/'
    HuffmanCode(0x0, 5),         #  48 '0'
    HuffmanCode(0x1, 5),         #  49 '1'
    HuffmanCode(0x2, 5),         #  50 '2'
    HuffmanCode(0x19, 6),        #  51 '3'
    HuffmanCode(0x1a, 6),        #  52 '4'
    HuffmanCode(0x1b, 6),        #  53 '5'
    HuffmanCode(0x1c, 6),        #  54 '6'
    HuffmanCode(0x1d, 6),        #  55 '7'
    HuffmanCode(0x1e, 6),        #  56 '8'
    HuffmanCode(0x1f, 6),        #  57 '9'
    HuffmanCode(0x5c, 7),        #  58 ':'
    HuffmanCode(0xfb, 8),        #  59 ';'
    HuffmanCode(0x7ffc, 15),     #  60 '<'
    HuffmanCode(0x20, 6),        #  61 '='
    HuffmanCode(0xffb, 12),      #  62 '>'
    HuffmanCode(0x3fc, 10),      #  63 '?'
    HuffmanCode(0x1ffa, 13),     #  64 '@'
    HuffmanCode(0x21, 6),        #  65 'A'
    HuffmanCode(0x5d, 7),        #  66 'B'
    HuffmanCode(0x5e, 7),        #  67 'C'
    HuffmanCode(0x5f, 7),        #  68 'D'
    HuffmanCode(0x60, 7),        #  69 'E'
    HuffmanCode(0x61, 7),        #  70 'F'
    HuffmanCode(0x62, 7),        #  71 'G'
    HuffmanCode(0x63, 7),        #  72 'H'
    HuffmanCode(0x64, 7),        #  73 'I'
    HuffmanCode(0x65, 7),        #  74 'J'
    HuffmanCode(0x66, 7),        #  75 'K'
    HuffmanCode(0x67, 7),        #  76 'L'
    HuffmanCode(0x68, 7),        #  77 'M'
    HuffmanCode(0x69, 7),        #  78 'N'
    HuffmanCode(0x6a, 7),        #  79 'O'
    HuffmanCode(0x6b, 7),        #  80 'P'
    HuffmanCode(0x6c, 7),        #  81 'Q'
    HuffmanCode(0x6d, 7),        #  82 'R'
    HuffmanCode(0x6e, 7),        #  83 'S'
    HuffmanCode(0x6f, 7),        #  84 'T'
    HuffmanCode(0x70, 7),        #  85 'U'
    HuffmanCode(0x71, 7),        #  86 'V'
    HuffmanCode(0x72, 7),        #  87 'W'
    HuffmanCode(0xfc, 8),        #  88 'X'
    HuffmanCode(0x73, 7),        #  89 'Y'
    HuffmanCode(0xfd, 8),        #  90 'Z'
    HuffmanCode(0x1ffb, 13),     #  91 '['
    HuffmanCode(0x7fff0, 19),    #  92 '\\'
    HuffmanCode(0x1ffc, 13),     #  93 ']'
    HuffmanCode(0x3ffc, 14),     #  94 '^'
    HuffmanCode(0x22, 6),        #  95 '_'
    HuffmanCode(0x7ffd, 15),     #  96 '`'
    HuffmanCode(0x3, 5),         #  97 'a'
    HuffmanCode(0x23, 6),        #  98 'b'
    HuffmanCode(0x4, 5),         #  99 'c'
    HuffmanCode(0x24, 6),        # 100 'd'
    HuffmanCode(0x5, 5),         # 101 'e'
    HuffmanCode(0x25, 6),        # 102 'f'
    HuffmanCode(0x26, 6),        # 103 'g'
    HuffmanCode(0x27, 6),        # 104 'h'
    HuffmanCode(0x6, 5),         # 105 'i'
    HuffmanCode(0x74, 7),        # 106 'j'
    HuffmanCode(0x75, 7),        # 107 'k'
    HuffmanCode(0x28, 6),        # 108 'l'
    HuffmanCode(0x29, 6),        # 109 'm'
    HuffmanCode(0x2a, 6),        # 110 'n'
    HuffmanCode(0x7, 5),         # 111 'o'
    HuffmanCode(0x2b, 6),        # 112 'p'
    HuffmanCode(0x76, 7),        # 113 'q'
    HuffmanCode(0x2c, 6),        # 114 'r'
    HuffmanCode(0x8, 5),         # 115 's'
    HuffmanCode(0x9, 5),         # 116 't'
    HuffmanCode(0x2d, 6),        # 117 'u'
    HuffmanCode(0x77, 7),        # 118 'v'
    HuffmanCode(0x78, 7),        # 119 'w'
    HuffmanCode(0x79, 7),        # 120 'x'
    HuffmanCode(0x7a, 7),        # 121 'y'
    HuffmanCode(0x7b, 7),        # 122 'z'
    HuffmanCode(0x7ffe, 15),     # 123 '{'
    HuffmanCode(0x7fc, 11),      # 124 '|'
    HuffmanCode(0x3ffd, 14),     # 125 '}'
    HuffmanCode(0x1ffd, 13),     # 126 '~'
    HuffmanCode(0xffffffc, 28),  # 127
    HuffmanCode(0xfffe6, 20),    # 128
    HuffmanCode(0x3fffd2, 22),   # 129
    HuffmanCode(0xfffe7, 20),    # 130
    HuffmanCode(0xfffe8, 20),    # 131
    HuffmanCode(0x3fffd3, 22),   # 132
    HuffmanCode(0x3fffd4, 22),   # 133
    HuffmanCode(0x3fffd5, 22),   # 134
    HuffmanCode(0x7fffd9, 23),   # 135
    HuffmanCode(0x3fffd6, 22),   # 136
    HuffmanCode(0x7fffda, 23),   # 137
    HuffmanCode(0x7fffdb, 23),   # 138
    HuffmanCode(0x7fffdc, 23),   # 139
    HuffmanCode(0x7fffdd, 23),   # 140
    HuffmanCode(0x7fffde, 23),   # 141
    HuffmanCode(0xffffeb, 24),   # 142
    HuffmanCode(0x7fffdf, 23),   # 143
    HuffmanCode(0xffffec, 24),   # 144
    HuffmanCode(0xffffed, 24),   # 145
    HuffmanCode(0x3fffd7, 22),   # 146
    HuffmanCode(0x7fffe0, 23),   # 147
    HuffmanCode(0xffffee, 24),   # 148
    HuffmanCode(0x7fffe1, 23),   # 149
    HuffmanCode(0x7fffe2, 23),   # 150
    HuffmanCode(0x7fffe3, 23),   # 151
    HuffmanCode(0x7fffe4, 23),   # 152
    HuffmanCode(0x1fffdc, 21),   # 153
    HuffmanCode(0x3fffd8, 22),   # 154
    HuffmanCode(0x7fffe5, 23),   # 155
    HuffmanCode(0x3fffd9, 22),   # 156
    HuffmanCode(0x7fffe6, 23),   # 157
    HuffmanCode(0x7fffe7, 23),   # 158
    HuffmanCode(0xffffef, 24),   # 159
    HuffmanCode(0x3fffda, 22),   # 160
    HuffmanCode(0x1fffdd, 21),   # 161
    HuffmanCode(0xfffe9, 20),    # 162
    HuffmanCode(0x3fffdb, 22),   # 163
    HuffmanCode(0x3fffdc, 22),   # 164
    HuffmanCode(0x7fffe8, 23),   # 165
    HuffmanCode(0x7fffe9, 23),   # 166
    HuffmanCode(0x1fffde, 21),   # 167
    HuffmanCode(0x7fffea, 23),   # 168
    HuffmanCode(0x3fffdd, 22),   # 169
    HuffmanCode(0x3fffde, 22),   # 170
    HuffmanCode(0xfffff0, 24),   # 171
    HuffmanCode(0x1fffdf, 21),   # 172
    HuffmanCode(0x3fffdf, 22),   # 173
    HuffmanCode(0x7fffeb, 23),   # 174
    HuffmanCode(0x7fffec, 23),   # 175
    HuffmanCode(0x1fffe0, 21),   # 176
    HuffmanCode(0x1fffe1, 21),   # 177
    HuffmanCode(0x3fffe0, 22),   # 178
    HuffmanCode(0x1fffe2, 21),   # 179
    HuffmanCode(0x7fffed, 23),   # 180
    HuffmanCode(0x3fffe1, 22),   # 181
    HuffmanCode(0x7fffee, 23),   # 182
    HuffmanCode(0x7fffef, 23),   # 183
    HuffmanCode(0xfffea, 20),    # 184
    HuffmanCode(0x3fffe2, 22),   # 185
    HuffmanCode(0x3fffe3, 22),   # 186
    HuffmanCode(0x3fffe4, 22),   # 187
    HuffmanCode(0x7ffff0, 23),   # 188
    HuffmanCode(0x3fffe5, 22),   # 189
    HuffmanCode(0x3fffe6, 22),   # 190
    HuffmanCode(0x7ffff1, 23),   # 191
    HuffmanCode(0x3ffffe0, 26),  # 192
    HuffmanCode(0x3ffffe1, 26),  # 193
    HuffmanCode(0xfffeb, 20),    # 194
    HuffmanCode(0x7fff1, 19),    # 195
    HuffmanCode(0x3fffe7, 22),   # 196
    HuffmanCode(0x7ffff2, 23),   # 197
    HuffmanCode(0x3fffe8, 22),   # 198
    HuffmanCode(0x1ffffec, 25),  # 199
    HuffmanCode(0x3ffffe2, 26),  # 200
    HuffmanCode(0x3ffffe3, 26),  # 201
    HuffmanCode(0x3ffffe4, 26),  # 202
    HuffmanCode(0x7ffffde, 27),  # 203
    HuffmanCode(0x7ffffdf, 27),  # 204
    HuffmanCode(0x3ffffe5, 26),  # 205
    HuffmanCode(0xfffff1, 24),   # 206
    HuffmanCode(0x1ffffed, 25),  # 207
    HuffmanCode(0x7fff2, 19),    # 208
    HuffmanCode(0x1fffe3, 21),   # 209
    HuffmanCode(0x3ffffe6, 26),  # 210
    HuffmanCode(0x7ffffe0, 27),  # 211
    HuffmanCode(0x7ffffe1, 27),  # 212
    HuffmanCode(0x3ffffe7, 26),  # 213
    HuffmanCode(0x7ffffe2, 27),  # 214
    HuffmanCode(0xfffff2, 24),   # 215
    HuffmanCode(0x1fffe4, 21),   # 216
    HuffmanCode(0x1fffe5, 21),   # 217
    HuffmanCode(0x3ffffe8, 26),  # 218
    HuffmanCode(0x3ffffe9, 26),  # 219
    HuffmanCode(0xffffffd, 28),  # 220
    HuffmanCode(0x7ffffe3, 27),  # 221
    HuffmanCode(0x7ffffe4, 27),  # 222
    HuffmanCode(0x7ffffe5, 27),  # 223
    HuffmanCode(0xfffec, 20),    # 224
    HuffmanCode(0xfffff3, 24),   # 225
    HuffmanCode(0xfffed, 20),    # 226
    HuffmanCode(0x1fffe6, 21),   # 227
    HuffmanCode(0x3fffe9, 22),   # 228
    HuffmanCode(0x1fffe7, 21),   # 229
    HuffmanCode(0x1fffe8, 21),   # 230
    HuffmanCode(0x7ffff3, 23),   # 231
    HuffmanCode(0x3fffea, 22),   # 232
    HuffmanCode(0x3fffeb, 22),   # 233
    HuffmanCode(0x1ffffee, 25),  # 234
    HuffmanCode(0x1ffffef, 25),  # 235
    HuffmanCode(0xfffff4, 24),   # 236
    HuffmanCode(0xfffff5, 24),   # 237
    HuffmanCode(0x3ffffea, 26),  # 238
    HuffmanCode(0x7ffff4, 23),   # 239
    HuffmanCode(0x3ffffeb, 26),  # 240
    HuffmanCode(0x7ffffe6, 27),  # 241
    HuffmanCode(0x3ffffec, 26),  # 242
    HuffmanCode(0x3ffffed, 26),  # 243
    HuffmanCode(0x7ffffe7, 27),  # 244
    HuffmanCode(0x7ffffe8, 27),  # 245
    HuffmanCode(0x7ffffe9, 27),  # 246
    HuffmanCode(0x7ffffea, 27),  # 247
    HuffmanCode(0x7ffffeb, 27),  # 248
    HuffmanCode(0xffffffe, 28),  # 249
    HuffmanCode(0x7ffffec, 27),  # 250
    HuffmanCode(0x7ffffed, 27),  # 251
    HuffmanCode(0x7ffffee, 27),  # 252
    HuffmanCode(0x7ffffef, 27),  # 253
    HuffmanCode(0x7fffff0, 27),  # 254
    HuffmanCode(0x3ffffee, 26),  # 255
]

# ─── Decode tree ───
# Binary tree built from the Huffman codes. Each node stores:
#   symbol: -1 for internal nodes, 0-255 for leaf nodes
#   zero_child / one_child: child node index (0 = no child)

mutable struct _HuffmanTreeNode
    symbol::Int16
    zero_child::Int32
    one_child::Int32
end

const HPACK_HUFFMAN_DECODE_TREE = let
    nodes = _HuffmanTreeNode[_HuffmanTreeNode(-1, 0, 0)]  # root at index 1

    for sym in 0:255
        code = HPACK_HUFFMAN_CODES[sym + 1]
        node_idx = 1
        for bit_pos in (code.num_bits - 1):-1:0
            bit = Int((code.pattern >> bit_pos) & 1)
            node = nodes[node_idx]
            child_idx = bit == 0 ? node.zero_child : node.one_child
            if child_idx == 0
                push!(nodes, _HuffmanTreeNode(-1, 0, 0))
                child_idx = Int32(length(nodes))
                if bit == 0
                    node.zero_child = child_idx
                else
                    node.one_child = child_idx
                end
            end
            node_idx = child_idx
        end
        nodes[node_idx].symbol = Int16(sym)
    end

    nodes
end

# ─── Compute encoded length (in bytes) ───

function hpack_huffman_encoded_length(data::AbstractVector{UInt8})::Int
    total_bits = 0
    for b in data
        total_bits += Int(HPACK_HUFFMAN_CODES[b + 1].num_bits)
    end
    return cld(total_bits, 8)  # ceiling division
end

# ─── Huffman encode ───

function hpack_huffman_encode(data::AbstractVector{UInt8})::Vector{UInt8}
    output = UInt8[]
    accum = UInt64(0)
    accum_bits = 0

    for b in data
        code = HPACK_HUFFMAN_CODES[b + 1]
        accum = (accum << code.num_bits) | UInt64(code.pattern)
        accum_bits += Int(code.num_bits)

        while accum_bits >= 8
            accum_bits -= 8
            push!(output, UInt8((accum >> accum_bits) & 0xff))
        end
    end

    # Pad remaining bits with 1s (EOS padding per RFC 7541 §5.2)
    if accum_bits > 0
        pad = 8 - accum_bits
        accum = (accum << pad) | ((UInt64(1) << pad) - 1)
        push!(output, UInt8(accum & 0xff))
    end

    return output
end

# ─── Decode one symbol from top 32 bits ───
# Returns (bits_consumed::UInt8, symbol::Int16)
# bits_consumed == 0 means invalid (EOS or error)

function _huffman_decode_symbol(bits::UInt32)::Tuple{UInt8, Int16}
    node_idx = 1  # root
    depth = 0
    while true
        node = HPACK_HUFFMAN_DECODE_TREE[node_idx]
        if node.symbol >= 0
            return (UInt8(depth), node.symbol)
        end
        depth >= 30 && return (UInt8(0), Int16(-1))
        bit = Int((bits >> (31 - depth)) & 1)
        child_idx = bit == 0 ? node.zero_child : node.one_child
        child_idx == 0 && return (UInt8(0), Int16(-1))
        node_idx = child_idx
        depth += 1
    end
end

# ─── Huffman decode ───

function hpack_huffman_decode(data::AbstractVector{UInt8}; max_output::Int=typemax(Int))::Tuple{Int, Vector{UInt8}}
    output = UInt8[]
    working = UInt64(0)
    num_bits = 0
    data_idx = 1

    while true
        # Fill working buffer (up to 56 bits, leaving room for 8 more)
        while num_bits <= 56 && data_idx <= length(data)
            working |= UInt64(data[data_idx]) << (56 - num_bits)
            num_bits += 8
            data_idx += 1
        end

        num_bits == 0 && break

        # Decode one symbol from the top 32 bits
        top32 = UInt32((working >> 32) & 0xffffffff)
        bits_consumed, symbol = _huffman_decode_symbol(top32)

        if bits_consumed == 0 || bits_consumed > num_bits
            # Remaining bits must be valid EOS padding (all 1s, < 8 bits)
            if num_bits < 8
                mask = (UInt64(1) << num_bits) - 1
                top_bits = (working >> (64 - num_bits)) & mask
                top_bits == mask && break  # valid padding
            end
            return (OP_ERR, output)
        end

        if symbol < 0
            return (OP_ERR, output)
        end

        length(output) >= max_output && return (OP_ERR, output)
        push!(output, UInt8(symbol))

        working <<= bits_consumed
        num_bits -= bits_consumed
    end

    return (OP_SUCCESS, output)
end
