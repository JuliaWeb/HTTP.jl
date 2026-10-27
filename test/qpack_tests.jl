using Test
using HTTP

# QPACK (RFC 9204) with the static table only: the encoder never uses a
# dynamic table, and the decoder rejects references to one, since HTTP/3
# connections here advertise a dynamic table capacity of 0.

const QP = HTTP

_qp_fields(pairs...) = [QP.HeaderField(String(n), String(v), false) for (n, v) in pairs]
_qp_pairs(fields) = [(f.name, f.value) for f in fields]

@testset "QPACK static table" begin
    @test length(QP._QPACK_STATIC_TABLE) == 99
    @test QP._QPACK_STATIC_TABLE[1] == (":authority", "")
    @test QP._QPACK_STATIC_TABLE[18] == (":method", "GET")
    @test QP._QPACK_STATIC_TABLE[26] == (":status", "200")
    @test QP._QPACK_STATIC_TABLE[99] == ("x-frame-options", "sameorigin")
end

@testset "QPACK encoding uses the static table" begin
    # Required Insert Count 0 and Base 0, then indexed field lines (static).
    @test QP._qpack_encode(_qp_fields(":method" => "GET")) == UInt8[0x00, 0x00, 0xd1]
    @test QP._qpack_encode(_qp_fields(":status" => "200", ":path" => "/")) == UInt8[0x00, 0x00, 0xd9, 0xc1]
    # A static index past the 6-bit prefix continues in the next byte.
    @test QP._qpack_encode(_qp_fields("x-frame-options" => "sameorigin")) == UInt8[0x00, 0x00, 0xff, 0x23]
    # Literal with a static name reference; a short value stays raw.
    @test QP._qpack_encode(_qp_fields(":path" => "/a")) == UInt8[0x00, 0x00, 0x51, 0x02, UInt8('/'), UInt8('a')]
    # Literal name; "x-qz" is no shorter in Huffman, so both stay raw.
    @test QP._qpack_encode(_qp_fields("x-qz" => "1")) ==
        UInt8[0x00, 0x00, 0x24, UInt8('x'), UInt8('-'), UInt8('q'), UInt8('z'), 0x01, UInt8('1')]
    # A sensitive field sets the N bit, which forbids intermediaries from indexing it.
    sensitive = [QP.HeaderField("authorization", "x", true)]
    @test QP._qpack_encode(sensitive)[3] == 0x70 | 0x0f
    # Huffman coding is used when shorter, flagged by the H bit.
    huff = QP._qpack_encode(_qp_fields(":path" => "/index.html"))
    @test huff[3] == 0x51 && (huff[4] & 0x80) != 0
    @test length(huff) < 3 + 1 + 1 + 11
end

@testset "QPACK decodes RFC 9204 Appendix B.1" begin
    block = UInt8[0x00, 0x00, 0x51, 0x0b, 0x2f, 0x69, 0x6e, 0x64, 0x65, 0x78, 0x2e, 0x68, 0x74, 0x6d, 0x6c]
    @test _qp_pairs(QP._qpack_decode(block)) == [(":path", "/index.html")]
end

@testset "QPACK round trip" begin
    fields = _qp_fields(
        ":method" => "POST", ":scheme" => "https", ":authority" => "example.com",
        ":path" => "/upload?x=1", "content-type" => "application/json",
        "user-agent" => "HTTP.jl", "x-custom-header" => "some value with spaces",
        "accept" => "*/*", "cookie" => "a=b", "x-empty" => "",
    )
    @test _qp_pairs(QP._qpack_decode(QP._qpack_encode(fields))) == _qp_pairs(fields)
    long = _qp_fields("x-long" => repeat("abcdefgh", 200))
    @test _qp_pairs(QP._qpack_decode(QP._qpack_encode(long))) == _qp_pairs(long)
    # Huffman-coded literal names decode too.
    named = UInt8[0x00, 0x00, 0x2b]  # literal name, H set, 3-bit length 3
    QP._append_huffman_string!(named, "x-custom")
    named[3] = 0x28 | UInt8(length(named) - 3)
    push!(named, 0x01, UInt8('v'))
    @test length(named) - 5 < 8
    @test _qp_pairs(QP._qpack_decode(named)) == [("x-custom", "v")]
end

@testset "QPACK decoding rejects the dynamic table and malformed input" begin
    bad(block) = @test_throws QP.ProtocolError QP._qpack_decode(block)
    bad(UInt8[])                                   # no prefix
    bad(UInt8[0x00])                               # truncated prefix
    bad(UInt8[0x01, 0x00, 0xd1])                   # Required Insert Count > 0
    bad(UInt8[0x00, 0x81, 0xd1])                   # Base with the sign bit
    bad(UInt8[0x00, 0x00, 0x80])                   # indexed, dynamic (T = 0)
    bad(UInt8[0x00, 0x00, 0x10])                   # indexed with post-base index
    bad(UInt8[0x00, 0x00, 0x40, 0x00])             # literal, dynamic name reference
    bad(UInt8[0x00, 0x00, 0x00, 0x00])             # literal with post-base name reference
    bad(UInt8[0x00, 0x00, 0xff, 0x24])             # static index 99, past the table
    bad(UInt8[0x00, 0x00, 0x51, 0x05, UInt8('/')]) # value runs past the end
    bad(UInt8[0x00, 0x00, 0x23, UInt8('a')])       # name runs past the end
    bad(UInt8[0x00, 0x00, 0x51, 0x81, 0xff])       # invalid Huffman padding
end

@testset "QPACK decoding enforces the field section size limit" begin
    block = QP._qpack_encode(_qp_fields("x-a" => repeat("v", 100)))
    # RFC 9114 Section 4.2.2: name + value + 32 per field.
    @test length(QP._qpack_decode(block; max_size = 3 + 100 + 32)) == 1
    @test_throws QP.ProtocolError QP._qpack_decode(block; max_size = 3 + 100 + 31)
end

# Cases ported from quic-go/qpack v0.5.1 (decoder_test.go, encoder_test.go,
# static_table_test.go). Field lines follow the Required Insert Count 0,
# Base 0 prefix, as their `insertPrefix` adds.
_qp_section(lines::Vector{UInt8}) = vcat(UInt8[0x00, 0x00], lines)

@testset "QPACK cases from quic-go/qpack" begin
    @testset "every static table entry encodes as one indexed field line" begin
        fields = [QP.HeaderField(n, v, false) for (n, v) in QP._QPACK_STATIC_TABLE]
        block = QP._qpack_encode(fields)
        # Duplicate entries (none in the table) would index the first copy.
        expected = UInt8[0x00, 0x00]
        for i in 0:98
            QP._encode_integer!(expected, i, 6, 0xc0)
        end
        @test block == expected
        @test _qp_pairs(QP._qpack_decode(block)) == QP._QPACK_STATIC_TABLE
        # The lookup tables agree with the table itself.
        @test all(((i, e),) -> QP._QPACK_STATIC_EXACT[e] == i - 1, enumerate(QP._QPACK_STATIC_TABLE))
        @test all(((n, _),) -> QP._QPACK_STATIC_TABLE[QP._QPACK_STATIC_NAME[n] + 1][1] == n, QP._QPACK_STATIC_TABLE)
    end

    @testset "fields named in the static table use a name reference" begin
        fields = _qp_fields(":status" => "666", "server" => "lorem ipsum", ":method" => "")
        block = QP._qpack_encode(fields)
        # Literal with a static name reference: 01NT then a 4-bit index.
        @test block[3] == 0x50 | 0x0f  # :status is index 24, past the 4-bit prefix
        @test _qp_pairs(QP._qpack_decode(block)) == _qp_pairs(fields)
    end

    @testset "fields with literal names, and sections encoded one after another" begin
        a = _qp_fields("foobar" => "lorem ipsum", "raboof" => "dolor sit amet")
        @test _qp_pairs(QP._qpack_decode(QP._qpack_encode(a))) == _qp_pairs(a)
        # The encoder keeps no state between sections.
        @test QP._qpack_encode(a[1:1]) == QP._qpack_encode(a[1:1])
        @test _qp_pairs(QP._qpack_decode(QP._qpack_encode(a[2:2]))) == _qp_pairs(a[2:2])
    end

    @testset "decoding indexed field lines" begin
        line = UInt8[]
        QP._encode_integer!(line, 20, 6, 0xc0)
        @test _qp_pairs(QP._qpack_decode(_qp_section(line))) == [QP._QPACK_STATIC_TABLE[21]]
        bad = UInt8[]
        QP._encode_integer!(bad, 10000, 6, 0xc0)
        @test_throws QP.ProtocolError QP._qpack_decode(_qp_section(bad))
        dynamic = UInt8[]
        QP._encode_integer!(dynamic, 20, 6, 0x80)
        @test_throws QP.ProtocolError QP._qpack_decode(_qp_section(dynamic))
    end

    @testset "decoding literals with a static name reference, with and without the N bit" begin
        for n in (0x00, 0x20)
            line = UInt8[]
            QP._encode_integer!(line, 49, 4, 0x50 | n)  # content-type
            push!(line, 0x06)
            append!(line, codeunits("foobar"))
            @test _qp_pairs(QP._qpack_decode(_qp_section(line))) == [("content-type", "foobar")]
        end
        # A Huffman-coded value.
        line = UInt8[]
        QP._encode_integer!(line, 49, 4, 0x50)
        value = UInt8[]
        QP._append_huffman_string!(value, "foobar")
        QP._encode_integer!(line, length(value), 7, 0x80)
        append!(line, value)
        @test _qp_pairs(QP._qpack_decode(_qp_section(line))) == [("content-type", "foobar")]
        # The same reference into the dynamic table is refused.
        line = UInt8[]
        QP._encode_integer!(line, 49, 4, 0x40)
        push!(line, 0x06)
        append!(line, codeunits("foobar"))
        @test_throws QP.ProtocolError QP._qpack_decode(_qp_section(line))
    end

    @testset "decoding a literal with a literal name" begin
        line = UInt8[0x23]
        append!(line, codeunits("foo"))
        push!(line, 0x03)
        append!(line, codeunits("bar"))
        @test _qp_pairs(QP._qpack_decode(_qp_section(line))) == [("foo", "bar")]
    end

    @testset "truncated sections are errors" begin
        block = QP._qpack_encode(_qp_fields("foo" => "bar"))
        @test_throws QP.ProtocolError QP._qpack_decode(block[1:(end - 2)])
        # quic-go also rejects an unknown 0b0001 line type; here that is the
        # post-base indexed form, a dynamic table reference.
        @test_throws QP.ProtocolError QP._qpack_decode(_qp_section(UInt8[0x10]))
    end

    @testset "where this decoder differs from quic-go's" begin
        # quic-go rejects a non-zero Base; with Required Insert Count 0 a Base
        # can reference nothing (post-base forms are refused anyway), so this
        # decoder accepts it, as RFC 9204 allows.
        @test _qp_pairs(QP._qpack_decode(UInt8[0x00, 0x01, 0xd1])) == [(":method", "GET")]
        # quic-go accepts an empty section; RFC 9204 Section 4.5.1 requires
        # the prefix, so this decoder does not.
        @test_throws QP.ProtocolError QP._qpack_decode(UInt8[])
    end
end
