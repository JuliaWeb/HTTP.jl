using Test
using HTTP

# HTTP/3 framing (RFC 9114 Section 7) and the QUIC variable-length integers
# it is built on (RFC 9000 Section 16).

const H3F = HTTP

function _h3f_error_code(f)
    try
        f()
    catch err
        err isa H3F._H3Error && return err.code
        rethrow()
    end
    return nothing
end

@testset "HTTP/3 variable-length integers" begin
    enc(v) = (out = UInt8[]; H3F._h3_append_varint!(out, UInt64(v)); out)
    @test enc(0) == [0x00]
    @test enc(63) == [0x3f]
    @test enc(64) == [0x40, 0x40]
    @test enc(16383) == [0x7f, 0xff]
    @test enc(16384) == [0x80, 0x00, 0x40, 0x00]
    @test enc(2^30 - 1) == [0xbf, 0xff, 0xff, 0xff]
    @test enc(2^30) == [0xc0, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00]
    @test_throws ArgumentError enc(UInt64(1) << 62)
    # RFC 9000 Appendix A.1.
    for (bytes, value) in (
        ([0xc2, 0x19, 0x7c, 0x5e, 0xff, 0x14, 0xe8, 0x8c], 151288809941952652),
        ([0x9d, 0x7f, 0x3e, 0x7d], 494878333),
        ([0x7b, 0xbd], 15293),
        ([0x25], 37),
        ([0x40, 0x25], 37),
    )
        @test H3F._h3_decode_varint(bytes, 1) == (UInt64(value), length(bytes) + 1)
        @test H3F._h3_read_varint(IOBuffer(bytes)) == UInt64(value)
    end
    @test H3F._h3_decode_varint(UInt8[0x40], 1) === nothing
    # A stream that ends before a varint starts ends cleanly; one that ends
    # inside it is a framing error.
    @test H3F._h3_read_varint(IOBuffer(UInt8[])) === nothing
    @test _h3f_error_code(() -> H3F._h3_read_varint(IOBuffer(UInt8[0x80, 0x00]))) == H3F._H3_FRAME_ERROR
end

@testset "HTTP/3 frames over a stream" begin
    out = UInt8[]
    H3F._h3_append_frame!(out, H3F._H3_FRAME_HEADERS, UInt8[1, 2, 3])
    H3F._h3_append_frame!(out, 0x21, UInt8[9, 9])  # a reserved type, to be skipped
    H3F._h3_append_frame!(out, H3F._H3_FRAME_DATA, UInt8[4, 5])
    @test out[1:5] == UInt8[0x01, 0x03, 1, 2, 3]
    io = IOBuffer(out)
    @test H3F._h3_read_frame_header(io) == (H3F._H3_FRAME_HEADERS, Int64(3))
    @test H3F._h3_read_payload(io, 3, 16) == UInt8[1, 2, 3]
    @test H3F._h3_read_frame_header(io) == (UInt64(0x21), Int64(2))
    H3F._h3_skip!(io, 2)
    @test H3F._h3_read_frame_header(io) == (H3F._H3_FRAME_DATA, Int64(2))
    @test H3F._h3_read_payload(io, 2, 16) == UInt8[4, 5]
    @test H3F._h3_read_frame_header(io) === nothing
    # Truncated frames are framing errors.
    @test _h3f_error_code(() -> H3F._h3_read_frame_header(IOBuffer(UInt8[0x01]))) == H3F._H3_FRAME_ERROR
    @test _h3f_error_code(() -> H3F._h3_read_payload(IOBuffer(UInt8[1]), 3, 16)) == H3F._H3_FRAME_ERROR
    @test _h3f_error_code(() -> H3F._h3_skip!(IOBuffer(UInt8[1]), 3)) == H3F._H3_FRAME_ERROR
    # A payload over the limit is refused before it is read.
    @test _h3f_error_code(() -> H3F._h3_read_payload(IOBuffer(zeros(UInt8, 32)), 32, 16)) == H3F._H3_EXCESSIVE_LOAD
    # Reserved types are the 0x1f * N + 0x21 grease values.
    @test H3F._h3_is_reserved_type(UInt64(0x21))
    @test H3F._h3_is_reserved_type(UInt64(0x1f * 1000 + 0x21))
    @test !H3F._h3_is_reserved_type(UInt64(0x22))
end

@testset "HTTP/3 SETTINGS" begin
    payload = H3F._h3_encode_settings([UInt64(0x01) => UInt64(0), UInt64(0x06) => UInt64(65536)])
    @test payload == UInt8[0x01, 0x00, 0x06, 0x80, 0x01, 0x00, 0x00]
    @test H3F._h3_decode_settings(payload) == [UInt64(0x01) => UInt64(0), UInt64(0x06) => UInt64(65536)]
    # Unknown identifiers are kept for the caller to ignore.
    @test H3F._h3_decode_settings(UInt8[0x21, 0x05]) == [UInt64(0x21) => UInt64(5)]
    # A setting twice, or an HTTP/2 setting, is H3_SETTINGS_ERROR.
    @test _h3f_error_code(() -> H3F._h3_decode_settings(UInt8[0x06, 0x01, 0x06, 0x02])) == H3F._H3_SETTINGS_ERROR
    for id in (0x02, 0x03, 0x04, 0x05)
        @test _h3f_error_code(() -> H3F._h3_decode_settings(UInt8[id, 0x01])) == H3F._H3_SETTINGS_ERROR
    end
    # A truncated setting is a framing error.
    @test _h3f_error_code(() -> H3F._h3_decode_settings(UInt8[0x06])) == H3F._H3_FRAME_ERROR
end

@testset "HTTP/3 GOAWAY" begin
    @test H3F._h3_decode_goaway(UInt8[0x40, 0x10]) == UInt64(16)
    @test _h3f_error_code(() -> H3F._h3_decode_goaway(UInt8[0x40])) == H3F._H3_FRAME_ERROR
    @test _h3f_error_code(() -> H3F._h3_decode_goaway(UInt8[0x04, 0x00])) == H3F._H3_FRAME_ERROR
end

@testset "HTTP/3 error code names" begin
    @test H3F._h3_error_name(UInt64(0x100)) == "H3_NO_ERROR"
    @test H3F._h3_error_name(UInt64(0x10c)) == "H3_REQUEST_CANCELLED"
    @test H3F._h3_error_name(UInt64(0x200)) == "QPACK_DECOMPRESSION_FAILED"
    @test H3F._h3_error_name(UInt64(0x999)) == "0x999"
end
