using Test
using HTTP
using LazyJSON
using Random

include("../src/Frames.jl")

@testset "Frames" begin

#https://github.com/http2jp/http2-frame-test-case/blob/master/headers/normal.json

frames = LazyJSON.value("""[
{
    "error": null,
    "wire": "00000D010400000001746869732069732064756D6D79",
    "frame": {
        "length": 13,
        "frame_payload": {
            "stream_dependency": null,
            "weight": null,
            "header_block_fragment": "this is dummy",
            "padding_length": null,
            "exclusive": null,
            "padding": null
        },
        "flags": 4,
        "stream_identifier": 1,
        "type": 1
    },
    "description": "normal headers frame"
},{
    "error": null,
    "wire": "000023012C00000003108000001409746869732069732064756D6D79546869732069732070616464696E672E",
    "frame": {
        "length": 35,
        "frame_payload": {
            "stream_dependency": 20,
            "weight": 10,
            "header_block_fragment": "this is dummy",
            "padding_length": 16,
            "exclusive": true,
            "padding": "This is padding."
        },
        "flags": 44,
        "stream_identifier": 3,
        "type": 1
    },
    "description": "normal headers frame including priority"
},{
    "error": null,
    "wire": "0000050200000000090000000B07",
    "frame": {
        "length": 5,
        "frame_payload": {
            "stream_dependency": 11,
            "weight": 8,
            "exclusive": false,
            "padding_length": null,
            "padding": null
        },
        "flags": 0,
        "stream_identifier": 9,
        "type": 2
    },
    "description": "normal priority frame"
},{
    "error": null,
    "wire": "00000D090000000032746869732069732064756D6D79",
    "frame": {
        "length": 13,
        "frame_payload": {
            "header_block_fragment": "this is dummy"
        },
        "flags": 0,
        "stream_identifier": 50,
        "type": 9
    },
    "description": "normal continuation frame without header block fragment"
}]""")


for test in frames
    b = hex2bytes(test.wire)
    @test Frames.frame_length(b) == test.frame.length
    @test Frames.frame_type(b) == test.frame["type"]
    @test Frames.flags(b) == test.frame.flags
    @test Frames.stream_id(b) == test.frame.stream_identifier
    @test view(b, UnitRange(Frames.payload(b)...)) ==
          hex2bytes(test.wire[19:end])
    if Frames.frame_is_padded(b)
        @test test.frame.frame_payload.padding != nothing
        @test Frames.pad_length(b) == test.frame.frame_payload.padding_length ||
                           nothing == test.frame.frame_payload.padding_length
    end
    if Frames.frame_has_dependency(b)
        @test Frames.weight(b) == test.frame.frame_payload.weight
        @test Frames.stream_dependency(b) ==
              (test.frame.frame_payload.exclusive,
               test.frame.frame_payload.stream_dependency)
    end

    if Frames.is_headers(b) || Frames.is_continuation(b)
        @test String(view(b, UnitRange(Frames.fragment(b)...))) ==
              test.frame.frame_payload.header_block_fragment
    end
        
end

frames = LazyJSON.value("""
[{
    "error": null,
    "wire": "0000140008000000020648656C6C6F2C20776F726C6421486F77647921",
    "frame": {
        "length": 20,
        "frame_payload": {
            "data": "Hello, world!",
            "padding_length": 6,
            "padding": "Howdy!"
        },
        "flags": 8,
        "stream_identifier": 2,
        "type": 0
    },
    "description": "normal data frame"
},{
    "error": null,
    "wire": "00001300000000000248656C6C6F2C20776F726C6421486F77647921",
    "frame": {
        "length": 19,
        "frame_payload": {
            "data": "Hello, world!Howdy!",
            "padding_length": null,
            "padding": null
        },
        "flags": 0,
        "stream_identifier": 2,
        "type": 0
    },
    "description": "normal data frame"
}]
""")

for test in frames
    b = hex2bytes(test.wire)
    @test Frames.frame_length(b) == test.frame.length
    @test Frames.frame_type(b) == test.frame["type"]
    @test Frames.flags(b) == test.frame.flags
    @test Frames.stream_id(b) == test.frame.stream_identifier

    @test String(view(b, UnitRange(Frames.data(b)...))) ==
          test.frame.frame_payload.data
end


frames = LazyJSON.value("""[
{
    "error": null,
    "wire": "00000403000000000500000008",
    "frame": {
        "length": 4,
        "frame_payload": {
            "error_code": 8
        },
        "flags": 0,
        "stream_identifier": 5,
        "type": 3
    },
    "description": "normal rst stream frame"
}]""")

for test in frames
    b = hex2bytes(test.wire)
    @test Frames.frame_length(b) == test.frame.length
    @test Frames.frame_type(b) == test.frame["type"]
    @test Frames.flags(b) == test.frame.flags
    @test Frames.stream_id(b) == test.frame.stream_identifier

    @test Frames.error_code(b) == test.frame.frame_payload.error_code
end


frames = LazyJSON.value("""[
{
    "error": null,
    "wire": "00000C040000000000000100002000000300001388",
    "frame": {
        "length": 12,
        "frame_payload": {
            "settings": [
                [
                    1,
                    8192
                ],
                [
                    3,
                    5000
                ]
            ]
        },
        "flags": 0,
        "stream_identifier": 0,
        "type": 4
    },
    "description": "normal rst stream frame"
}]""")


for test in frames
    b = hex2bytes(test.wire)
    @test Frames.frame_length(b) == test.frame.length
    @test Frames.frame_type(b) == test.frame["type"]
    @test Frames.flags(b) == test.frame.flags
    @test Frames.stream_id(b) == test.frame.stream_identifier

    @test Frames.settings_count(b) == length(test.frame.frame_payload.settings)
    for (i, v) in enumerate(test.frame.frame_payload.settings)
        id, val = Frames.setting(b, i)
        @test id == v[1]
        @test val == v[2]
    end
end


frames = LazyJSON.value("""[
{
    "error": null,
    "wire": "000018050C0000000A060000000C746869732069732064756D6D79486F77647921",
    "frame": {
        "length": 24,
        "frame_payload": {
            "header_block_fragment": "this is dummy",
            "padding_length": 6,
            "promised_stream_id": 12,
            "padding": "Howdy!"
        },
        "flags": 12,
        "stream_identifier": 10,
        "type": 5
    },
    "description": "normal push promise frame"
},{
    "error": null,
    "wire": "00001705040000000A0000000C746869732069732064756D6D79486F77647921",
    "frame": {
        "length": 23,
        "frame_payload": {
            "header_block_fragment": "this is dummyHowdy!",
            "padding_length": null,
            "promised_stream_id": 12,
            "padding": null
        },
        "flags": 4,
        "stream_identifier": 10,
        "type": 5
    },
    "description": "normal push promise frame"
}]""")

for test in frames
    b = hex2bytes(test.wire)
    @test Frames.frame_length(b) == test.frame.length
    @test Frames.frame_type(b) == test.frame["type"]
    @test Frames.flags(b) == test.frame.flags
    @test Frames.stream_id(b) == test.frame.stream_identifier

    @test Frames.promised_stream_id(b) ==
          test.frame.frame_payload.promised_stream_id

    @test String(view(b, UnitRange(Frames.promise_fragment(b)...))) ==
          test.frame.frame_payload.header_block_fragment
end


frames = LazyJSON.value("""[
{
    "error": null,
    "wire": "0000170700000000000000001E00000009687061636B2069732062726F6B656E",
    "frame": {
        "length": 23,
        "frame_payload": {
            "error_code": 9,
            "additional_debug_data": "hpack is broken",
            "last_stream_id": 30
        },
        "flags": 0,
        "stream_identifier": 0,
        "type": 7
    },
    "description": "normal goaway frame"
}]""")

for test in frames
    b = hex2bytes(test.wire)
    @test Frames.frame_length(b) == test.frame.length
    @test Frames.frame_type(b) == test.frame["type"]
    @test Frames.flags(b) == test.frame.flags
    @test Frames.stream_id(b) == test.frame.stream_identifier

    @test Frames.last_stream_id(b) ==
          test.frame.frame_payload.last_stream_id
    @test Frames.error_code(b) ==
          test.frame.frame_payload.error_code

    @test String(view(b, UnitRange(Frames.debug(b)...))) ==
          test.frame.frame_payload.additional_debug_data
end



frames = LazyJSON.value("""[
{
    "error": null,
    "wire": "000004080000000032000003E8",
    "frame": {
        "length": 4,
        "frame_payload": {
            "window_size_increment": 1000
        },
        "flags": 0,
        "stream_identifier": 50,
        "type": 8
    },
    "description": "normal window update frame"
}]""")

for test in frames
    b = hex2bytes(test.wire)
    @test Frames.frame_length(b) == test.frame.length
    @test Frames.frame_type(b) == test.frame["type"]
    @test Frames.flags(b) == test.frame.flags
    @test Frames.stream_id(b) == test.frame.stream_identifier

    @test Frames.window_size_increment(b) == 
          test.frame.frame_payload.window_size_increment
end



end #@testset "Frames"
