using Test
using HTTP
using Reseau

const HT = HTTP

function _roundtrip_frame(frame::HT.AbstractFrame)::HT.AbstractFrame
    io = IOBuffer()
    writer = io
    HT.write_frame!(writer, frame)
    reader = IOBuffer(take!(io))
    return HT.read_frame!(reader)
end

@testset "HTTP/2 frame roundtrip basics" begin
    data = HT.DataFrame(UInt32(1), true, UInt8[0x61, 0x62])
    data_rt = _roundtrip_frame(data)
    @test data_rt isa HT.DataFrame
    @test (data_rt::HT.DataFrame).stream_id == UInt32(1)
    @test (data_rt::HT.DataFrame).end_stream
    @test (data_rt::HT.DataFrame).data == UInt8[0x61, 0x62]
    settings = HT.SettingsFrame(false, [UInt16(0x4) => UInt32(65535)])
    settings_rt = _roundtrip_frame(settings)
    @test settings_rt isa HT.SettingsFrame
    @test !(settings_rt::HT.SettingsFrame).ack
    @test (settings_rt::HT.SettingsFrame).settings == [UInt16(0x4) => UInt32(65535)]
    ping = HT.PingFrame(true, (0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08))
    ping_rt = _roundtrip_frame(ping)
    @test ping_rt isa HT.PingFrame
    @test (ping_rt::HT.PingFrame).ack
    @test (ping_rt::HT.PingFrame).opaque_data == (0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08)
end

@testset "HTTP/2 structured frame roundtrips" begin
    headers = HT.HeadersFrame(UInt32(3), false, true, UInt8[0xaa, 0xbb])
    headers_rt = _roundtrip_frame(headers)
    @test headers_rt isa HT.HeadersFrame
    @test (headers_rt::HT.HeadersFrame).stream_id == UInt32(3)
    @test (headers_rt::HT.HeadersFrame).end_headers
    @test (headers_rt::HT.HeadersFrame).header_block_fragment == UInt8[0xaa, 0xbb]
    goaway = HT.GoAwayFrame(UInt32(7), UInt32(0), UInt8[0x64, 0x62, 0x67])
    goaway_rt = _roundtrip_frame(goaway)
    @test goaway_rt isa HT.GoAwayFrame
    @test (goaway_rt::HT.GoAwayFrame).last_stream_id == UInt32(7)
    @test (goaway_rt::HT.GoAwayFrame).debug_data == UInt8[0x64, 0x62, 0x67]
    continuation = HT.ContinuationFrame(UInt32(5), true, UInt8[0x01, 0x02])
    continuation_rt = _roundtrip_frame(continuation)
    @test continuation_rt isa HT.ContinuationFrame
    @test (continuation_rt::HT.ContinuationFrame).end_headers
end

@testset "HTTP/2 parse guards" begin
    io = IOBuffer()
    bytes = UInt8[
        0x00, 0x00, 0x04,
        HT.FRAME_WINDOW_UPDATE,
        0x00,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00,
    ]
    write(io, bytes)
    reader = IOBuffer(take!(io))
    @test_throws HT.ProtocolError HT.read_frame!(reader)
end

@testset "HTTP/2 frame stream-id validation on read" begin
    invalid_frames = (
        (
            "DATA stream 0",
            UInt8[0x00, 0x00, 0x00, HT.FRAME_DATA, 0x00, 0x00, 0x00, 0x00, 0x00],
        ),
        (
            "HEADERS stream 0",
            UInt8[0x00, 0x00, 0x00, HT.FRAME_HEADERS, HT.FLAG_END_HEADERS, 0x00, 0x00, 0x00, 0x00],
        ),
        (
            "PRIORITY stream 0",
            UInt8[0x00, 0x00, 0x05, HT.FRAME_PRIORITY, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x10],
        ),
        (
            "RST_STREAM stream 0",
            UInt8[0x00, 0x00, 0x04, HT.FRAME_RST_STREAM, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01],
        ),
        (
            "SETTINGS non-zero stream",
            UInt8[0x00, 0x00, 0x00, HT.FRAME_SETTINGS, 0x00, 0x00, 0x00, 0x00, 0x01],
        ),
        (
            "PUSH_PROMISE stream 0",
            UInt8[0x00, 0x00, 0x04, HT.FRAME_PUSH_PROMISE, HT.FLAG_END_HEADERS, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02],
        ),
        (
            "PING non-zero stream",
            UInt8[0x00, 0x00, 0x08, HT.FRAME_PING, 0x00, 0x00, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0],
        ),
        (
            "GOAWAY non-zero stream",
            UInt8[0x00, 0x00, 0x08, HT.FRAME_GOAWAY, 0x00, 0x00, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0],
        ),
        (
            "CONTINUATION stream 0",
            UInt8[0x00, 0x00, 0x00, HT.FRAME_CONTINUATION, HT.FLAG_END_HEADERS, 0x00, 0x00, 0x00, 0x00],
        ),
    )
    for (name, bytes) in invalid_frames
        @testset "$name" begin
            @test_throws HT.ProtocolError HT.read_frame!(IOBuffer(bytes))
        end
    end
end

@testset "HTTP/2 frame stream-id validation on write" begin
    invalid_writes = (
        HT.DataFrame(UInt32(0), false, UInt8[]),
        HT.HeadersFrame(UInt32(0), false, true, UInt8[]),
        HT.PriorityFrame(UInt32(0), false, UInt32(1), UInt8(0x10)),
        HT.RSTStreamFrame(UInt32(0), UInt32(0x1)),
        HT.PushPromiseFrame(UInt32(0), UInt32(2), true, UInt8[]),
        HT.PushPromiseFrame(UInt32(1), UInt32(0), true, UInt8[]),
        HT.ContinuationFrame(UInt32(0), true, UInt8[]),
    )
    for frame in invalid_writes
        io = IOBuffer()
        writer = io
        @test_throws HT.ProtocolError HT.write_frame!(writer, frame)
    end
end

@testset "HTTP/2 padded payload parsing" begin
    padded_data_bytes = UInt8[
        0x00, 0x00, 0x06,
        HT.FRAME_DATA,
        HT.FLAG_PADDED | HT.FLAG_END_STREAM,
        0x00, 0x00, 0x00, 0x01,
        0x02,
        0x61, 0x62, 0x63,
        0x00, 0x00,
    ]
    data_frame = HT.read_frame!(IOBuffer(padded_data_bytes))
    @test data_frame isa HT.DataFrame
    @test (data_frame::HT.DataFrame).end_stream
    @test (data_frame::HT.DataFrame).data == collect(codeunits("abc"))

    padded_headers_bytes = UInt8[
        0x00, 0x00, 0x05,
        HT.FRAME_HEADERS,
        HT.FLAG_PADDED | HT.FLAG_END_HEADERS,
        0x00, 0x00, 0x00, 0x03,
        0x01,
        0xaa, 0xbb, 0xcc,
        0x00,
    ]
    headers_frame = HT.read_frame!(IOBuffer(padded_headers_bytes))
    @test headers_frame isa HT.HeadersFrame
    @test (headers_frame::HT.HeadersFrame).end_headers
    @test (headers_frame::HT.HeadersFrame).header_block_fragment == UInt8[0xaa, 0xbb, 0xcc]
end

@testset "HTTP/2 priority and push-promise parsing" begin
    headers_priority_bytes = UInt8[
        0x00, 0x00, 0x09,
        HT.FRAME_HEADERS,
        HT.FLAG_PADDED | HT.FLAG_END_HEADERS | HT._FLAG_HEADERS_PRIORITY,
        0x00, 0x00, 0x00, 0x03,
        0x01,
        0x80, 0x00, 0x00, 0x02,
        0x10,
        0xaa, 0xbb,
        0x00,
    ]
    headers_priority = HT.read_frame!(IOBuffer(headers_priority_bytes))
    @test headers_priority isa HT.HeadersFrame
    @test (headers_priority::HT.HeadersFrame).header_block_fragment == UInt8[0xaa, 0xbb]

    bad_headers_priority_bytes = UInt8[
        0x00, 0x00, 0x04,
        HT.FRAME_HEADERS,
        HT._FLAG_HEADERS_PRIORITY,
        0x00, 0x00, 0x00, 0x03,
        0x80, 0x00, 0x00, 0x02,
    ]
    @test_throws HT.ParseError HT.read_frame!(IOBuffer(bad_headers_priority_bytes))

    push_promise_bytes = UInt8[
        0x00, 0x00, 0x08,
        HT.FRAME_PUSH_PROMISE,
        HT.FLAG_PADDED | HT.FLAG_END_HEADERS,
        0x00, 0x00, 0x00, 0x05,
        0x01,
        0x00, 0x00, 0x00, 0x07,
        0xaa, 0xbb,
        0x00,
    ]
    push_promise = HT.read_frame!(IOBuffer(push_promise_bytes))
    @test push_promise isa HT.PushPromiseFrame
    @test (push_promise::HT.PushPromiseFrame).promised_stream_id == UInt32(7)
    @test (push_promise::HT.PushPromiseFrame).header_block_fragment == UInt8[0xaa, 0xbb]

    priority_bytes = UInt8[
        0x00, 0x00, 0x05,
        HT.FRAME_PRIORITY,
        0x00,
        0x00, 0x00, 0x00, 0x09,
        0x80, 0x00, 0x00, 0x03,
        0x20,
    ]
    priority = HT.read_frame!(IOBuffer(priority_bytes))
    @test priority isa HT.PriorityFrame
    @test (priority::HT.PriorityFrame).exclusive
    @test (priority::HT.PriorityFrame).stream_dependency == UInt32(3)
    @test (priority::HT.PriorityFrame).weight == UInt8(0x20)
end

@testset "HTTP/2 unknown frame passthrough" begin
    header = HT.FrameHeader(3, UInt8(0xfe), UInt8(0x00), UInt32(9))
    frame = HT.UnknownFrame(header, UInt8[0x01, 0x02, 0x03])
    rt = _roundtrip_frame(frame)
    @test rt isa HT.UnknownFrame
    @test (rt::HT.UnknownFrame).header.type == UInt8(0xfe)
    @test (rt::HT.UnknownFrame).payload == UInt8[0x01, 0x02, 0x03]
end

@testset "HTTP/2 header block fragmentation helper" begin
    block = collect(UInt8(0x01):UInt8(0x0a))
    frames = HT.AbstractFrame[]
    HT._header_block_frames(UInt32(9), true, block, 4) do frame
        push!(frames, frame)
    end
    @test length(frames) == 3
    @test frames[1] isa HT.HeadersFrame
    @test (frames[1]::HT.HeadersFrame).end_stream
    @test !(frames[1]::HT.HeadersFrame).end_headers
    @test (frames[1]::HT.HeadersFrame).header_block_fragment == UInt8[0x01, 0x02, 0x03, 0x04]
    @test frames[2] isa HT.ContinuationFrame
    @test !(frames[2]::HT.ContinuationFrame).end_headers
    @test (frames[2]::HT.ContinuationFrame).header_block_fragment == UInt8[0x05, 0x06, 0x07, 0x08]
    @test frames[3] isa HT.ContinuationFrame
    @test (frames[3]::HT.ContinuationFrame).end_headers
    @test (frames[3]::HT.ContinuationFrame).header_block_fragment == UInt8[0x09, 0x0a]
end
