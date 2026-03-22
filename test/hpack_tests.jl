using Test
using HTTP
using Reseau

const HT = HTTP

function _pairs(headers::Vector{HT.HeaderField})
    return [(h.name, h.value) for h in headers]
end

@testset "HPACK encode/decode round trip" begin
    encoder = HT.Encoder()
    decoder = HT.Decoder()
    input = HT.HeaderField[
        HT.HeaderField(":method", "GET", false),
        HT.HeaderField(":path", "/", false),
        HT.HeaderField("x-test", "abc", false),
    ]
    block = HT.encode_header_block(encoder, input)
    output = HT.decode_header_block(decoder, block)
    @test _pairs(output) == _pairs(input)
end

@testset "HPACK dynamic table indexing" begin
    encoder = HT.Encoder()
    decoder = HT.Decoder()
    first = HT.encode_header_block(encoder, HT.HeaderField[HT.HeaderField("x-dyn", "1", false)])
    _ = HT.decode_header_block(decoder, first)
    second = HT.encode_header_block(encoder, HT.HeaderField[HT.HeaderField("x-dyn", "1", false)])
    @test length(second) <= length(first)
    decoded_second = HT.decode_header_block(decoder, second)
    @test _pairs(decoded_second) == [("x-dyn", "1")]
end

@testset "HPACK size update and validation" begin
    encoder = HT.Encoder(max_table_size = 64)
    HT.set_max_dynamic_table_size!(encoder, 32)
    @test encoder.table.max_size == 32
    decoder = HT.Decoder()
    block = UInt8[0x3f, 0x01] # dynamic table size update to 32
    decoded = HT.decode_header_block(decoder, block)
    @test isempty(decoded)
    @test decoder.table.max_size == 32
end

@testset "HPACK decoder rejects dynamic table updates above allowed limit" begin
    encoder = HT.Encoder(max_table_size = 16_384)
    HT.set_max_dynamic_table_size!(encoder, 8_192)
    block = HT.encode_header_block(encoder, HT.HeaderField[])
    decoder = HT.Decoder(max_table_size = 4_096)
    @test_throws HT.ParseError HT.decode_header_block(decoder, block)
end

@testset "HPACK encoder emits table size update bytes" begin
    encoder = HT.Encoder(max_table_size = 64)
    HT.set_max_dynamic_table_size!(encoder, 16)
    block = HT.encode_header_block(encoder, HT.HeaderField[])
    @test block == UInt8[0x30]
    @test isempty(HT.encode_header_block(encoder, HT.HeaderField[]))
end

@testset "HPACK encoder emits min and final table size update bytes" begin
    encoder = HT.Encoder(max_table_size = 64)
    HT.set_max_dynamic_table_size!(encoder, 16)
    HT.set_max_dynamic_table_size!(encoder, 32)
    block = HT.encode_header_block(encoder, HT.HeaderField[])
    @test block == UInt8[0x30, 0x3f, 0x01]
end

@testset "HPACK sensitive headers use never-indexed representation" begin
    encoder = HT.Encoder()
    decoder = HT.Decoder()
    input = HT.HeaderField[HT.HeaderField("authorization", "secret", true)]
    block = HT.encode_header_block(encoder, input)
    @test (block[1] & 0xf0) == 0x10
    decoded = HT.decode_header_block(decoder, block)
    @test length(decoded) == 1
    @test decoded[1].name == "authorization"
    @test decoded[1].value == "secret"
    @test decoded[1].sensitive
    @test isempty(encoder.table.entries)
end

@testset "HPACK table size update must appear before header fields" begin
    decoder = HT.Decoder()
    bad = UInt8[0x82, 0x20]
    @test_throws HT.ParseError HT.decode_header_block(decoder, bad)
end

@testset "HPACK huffman decode fixture" begin
    decoder = HT.Decoder()
    # RFC 7541 Appendix C.4.1: "www.example.com" (huffman-coded)
    # Literal without indexing, indexed name = "host" (static table index 38)
    block = UInt8[
        0x0f, 0x17, 0x8c,
        0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff,
    ]
    decoded = HT.decode_header_block(decoder, block)
    @test _pairs(decoded) == [("host", "www.example.com")]
end

@testset "HPACK huffman encode/decode round trip" begin
    encoder = HT.Encoder()
    decoder = HT.Decoder()
    input = HT.HeaderField[
        HT.HeaderField("host", "www.example.com", false),
        HT.HeaderField("x-h2-header", "abcdefghijklmnopqrstuvwxyz", false),
    ]
    block = HT.encode_header_block(encoder, input)
    # First literal has indexed name (host=38), and value should be Huffman-coded.
    @test block[1] == 0x66
    @test (block[2] & 0x80) == 0x80
    decoded = HT.decode_header_block(decoder, block)
    @test _pairs(decoded) == _pairs(input)
end

@testset "HPACK decoder enforces max decoded string length" begin
    encoder = HT.Encoder()
    block = HT.encode_header_block(
        encoder,
        HT.HeaderField[HT.HeaderField("x-limit", repeat("abcdef", 8), false)],
    )
    decoder = HT.Decoder(max_string_length = 16)
    @test_throws HT.ParseError HT.decode_header_block(decoder, block)
end

@testset "HPACK decoder enforces max header list size" begin
    encoder = HT.Encoder()
    block = HT.encode_header_block(
        encoder,
        HT.HeaderField[
            HT.HeaderField("x-a", repeat("a", 20), false),
            HT.HeaderField("x-b", repeat("b", 20), false),
        ],
    )
    decoder = HT.Decoder(max_header_list_size = 96)
    @test_throws HT.ParseError HT.decode_header_block(decoder, block)
end
