"""
HTTP Frames.                       https://tools.ietf.org/html/rfc7540#section-4


4.1.  Frame Format               https://tools.ietf.org/html/rfc7540#section-4.1

    +-----------------------------------------------+
    |                 Length (24)                   |
    +---------------+---------------+---------------+
    |   Type (8)    |   Flags (8)   |
    +-+-------------+---------------+-------------------------------+
    |R|                 Stream Identifier (31)                      |
    +=+=============================================================+
    |                   Frame Payload (0...)                      ...
    +---------------------------------------------------------------+

Copyright (c) 2018, Sam O'Connor
"""
module Frames

getbyte(b, i) = @inbounds b[i]

ntoh_16(b, i) = ntoh(unsafe_load(Ptr{UInt16}(pointer(b, i))))
ntoh_32(b, i) = ntoh(unsafe_load(Ptr{UInt32}(pointer(b, i))))
ntoh_31(b, i) = ntoh_32(b, i) & 0x7FFFFFFF

frame_length(b, i=1) = ntoh_32(b, i + 0) >> 8
frame_type(  b, i=1) = getbyte(b, i + 3)
flags(       b, i=1) = getbyte(b, i + 4)
stream_id(   b, i=1) = ntoh_31(b, i + 5)

is_end_stream(f) = f & 0x01 != 0
is_padded(f)     = f & 0x08 != 0

frame_is_end_stream(b, i=1) = is_stream_end(flags(b, i))
frame_is_padded(    b, i=1) = is_padded(    flags(b, i))

payload_start(b, i=1) = i + 9
payload_end(  b, i=1) = i + 8 + frame_length(b, i)

payload(b, i=1) = payload_start(b, i), payload_end(b, i)


"""
    An endpoint MUST send an error code of FRAME_SIZE_ERROR if a frame
    exceeds the size defined in SETTINGS_MAX_FRAME_SIZE
https://tools.ietf.org/html/rfc7540#section-4.2
"""
check_frame_length(settings, l) = 
    l <= settings[SETTINGS_MAX_FRAME_SIZE] ?  NO_ERROR : FRAME_SIZE_ERROR


"""
   The total number of padding octets is determined by the value of the
   Pad Length field.  If the length of the padding is the length of the
   frame payload or greater, the recipient MUST treat this as a
   connection error (Section 5.4.1) of type PROTOCOL_ERROR.

https://tools.ietf.org/html/rfc7540#section-6.1
"""
check_frame_padding(b, i=1) =
    pad_length(b, i) < frame_length(b, i) ? NO_ERROR : PROTOCOL_ERROR


"""
6.1.  DATA                       https://tools.ietf.org/html/rfc7540#section-6.1

    +---------------+
    |Pad Length? (8)|
    +---------------+-----------------------------------------------+
    |                            Data (*)                         ...
    +---------------------------------------------------------------+
    |                           Padding (*)                       ...
    +---------------------------------------------------------------+
"""
const DATA = 0x0
is_data(b, i=1) = frame_type(b, i) == DATA

pad_length(b, i=1, f=flags(b, i)) = is_padded(f) ? getbyte(b, i + 9) : 0

data_start(b, i=1, f=flags(b, i)) = payload_start(b, i) + (is_padded(f) ? 1 : 0)
data_end(  b, i=1, f=flags(b, i)) = payload_end(  b, i) - pad_length(b, i, f)

data(b, i=1, f=flags(b, i)) = data_start(b, i, f), data_end(b, i, f)


"""
6.2.  HEADERS                    https://tools.ietf.org/html/rfc7540#section-6.2

    +---------------+
    |Pad Length? (8)|
    +-+-------------+-----------------------------------------------+
    |E|                 Stream Dependency? (31)                     |
    +-+-------------+-----------------------------------------------+
    |  Weight? (8)  |
    +-+-------------+-----------------------------------------------+
    |                   Header Block Fragment (*)                 ...
    +---------------------------------------------------------------+
    |                           Padding (*)                       ...
    +---------------------------------------------------------------+
"""
const HEADERS = 0x1
is_headers(b, i=1) = frame_type(b, i) == HEADERS

has_dependency(f) = f & 0x20 != 0
frame_has_dependency(b, i=1) = has_dependency(flags(b, i))

weight(b, i=1, f=flags(b, i)) =
    1 + getbyte(b, payload_start(b, i) + (is_padded(f) ? 5 : 4))

function stream_dependency(b, i=1, f=flags(b, i))::Tuple{Bool,UInt32}
    x = ntoh_32(b, payload_start(b, i) + (is_padded(f) ? 1 : 0))
    (x & 0x80000000 != 0), (x & 0x7FFFFFFF)
end

fragment_start(b, i=1, f=flags(b, i)) = (i += is_padded(f) ? 10 : 9;
                                         has_dependency(f) ? i + 5 : i)
fragment_end(b, i=1, f=flags(b, i)) = data_end(b, i, f)

fragment(b, i=1, f=flags(b, i)) = fragment_start(b, i, f),
                                  fragment_end(b, i, f)


check_headers_frame(b, i=1, f=flags(b, i)) = 
    fragment_start(b, i, f) > fragment_end(b, i, f) ? FRAME_SIZE_ERROR :
                                                      NO_ERROR

"""
6.3.  PRIORITY                   https://tools.ietf.org/html/rfc7540#section-6.3

    +-+-------------------------------------------------------------+
    |E|                  Stream Dependency (31)                     |
    +-+-------------+-----------------------------------------------+
    |   Weight (8)  |
    +-+-------------+
"""
const PRIORITY = 0x2
is_priority(b, i=1) = frame_type(b, i) == PRIORITY

check_priority_frame(b, i=1) = 
    frame_length(b, i) != 5 ? FRAME_SIZE_ERROR :
    stream_id(b, i)    == 0 ? PROTOCOL_ERROR :
                              NO_ERROR


"""
6.4.  RST_STREAM                 https://tools.ietf.org/html/rfc7540#section-6.4

    +---------------------------------------------------------------+
    |                        Error Code (32)                        |
    +---------------------------------------------------------------+
"""
const RST_STREAM = 0x3
is_rst_stream(b, i=1) = frame_type(b, i) == RST_STREAM

error_code(b, i=1) = ntoh_32(b, payload_start(b, i) + 
                                (frame_type(b, i) == GOAWAY ? 4 : 0))

check_rst_stream_frame(b, i=1) = 
    frame_length(b, i) != 4 ? FRAME_SIZE_ERROR :
    stream_id(b, i)    == 0 ? PROTOCOL_ERROR :
                              NO_ERROR


"""
6.5.  SETTINGS                   https://tools.ietf.org/html/rfc7540#section-6.5

    +-------------------------------+
    |       Identifier (16)         |
    +-------------------------------+-------------------------------+
    |                        Value (32)                             |
    +---------------------------------------------------------------+
"""
const SETTINGS = 0x4
is_settings(b, i=1) = frame_type(b, i) == SETTINGS

const SETTINGS_HEADER_TABLE_SIZE = 1
const SETTINGS_ENABLE_PUSH = 2
const SETTINGS_MAX_CONCURRENT_STREAMS = 3
const SETTINGS_INITIAL_WINDOW_SIZE = 4
const SETTINGS_MAX_FRAME_SIZE = 5
const SETTINGS_MAX_HEADER_LIST_SIZE = 6

is_ack(b, i, f=flags(b,i)) = f & 0x01 != 0

settings_count(b, i=1) = frame_length(b, i) / 6

setting(b, n, i=1) = (i = payload_start(b, i) + (n - 1) * 6;
                      (ntoh_16(b, i) => ntoh_32(b, i+2)))

check_settings_frame(b, i=1, f=flags(b, i)) = (
    l = frame_length(b, i);
    is_ack(b, i, f) && l != 0 ? FRAME_SIZE_ERROR :
    (l % 6) != 0              ? FRAME_SIZE_ERROR :
    stream_id(b, i) != 0      ? PROTOCOL_ERROR :
                                NO_ERROR)


"""
6.6.  PUSH_PROMISE               https://tools.ietf.org/html/rfc7540#section-6.6

    +---------------+
    |Pad Length? (8)|
    +-+-------------+-----------------------------------------------+
    |R|                  Promised Stream ID (31)                    |
    +-+-----------------------------+-------------------------------+
    |                   Header Block Fragment (*)                 ...
    +---------------------------------------------------------------+
    |                           Padding (*)                       ...
    +---------------------------------------------------------------+
"""
const PUSH_PROMISE  = 0x5
is_push_promise(b, i=1) = frame_type(b, i) == PUSH_PROMISE

promised_stream_id(b, i=1, f=flags(b, i)) = 
    ntoh_32(b, payload_start(b, i) + (is_padded(f) ? 1 : 0)) & 0x7FFFFFFF

promise_fragment_start(b, i=1, f=flags(b, i)) = payload_start(b, i) +
                                                (is_padded(f) ? 5 : 4)

promise_fragment_end(b, i=1, f=flags(b, i)) = fragment_end(b, i, f)

promise_fragment(b, i=1, f=flags(b, i)) = promise_fragment_start(b, i, f),
                                          promise_fragment_end(b, i, f)

check_promise_frame(b, i=1, f=flags(b, i)) =
    promise_fragment_start(b, i, f) >
        promise_fragment_end(b, i, f) ? FRAME_SIZE_ERROR :
        stream_id(b, i) != 0          ? PROTOCOL_ERROR :
                                        NO_ERROR


"""
6.7.  PING                       https://tools.ietf.org/html/rfc7540#section-6.7

    +---------------------------------------------------------------+
    |                                                               |
    |                      Opaque Data (64)                         |
    |                                                               |
    +---------------------------------------------------------------+
"""
const PING = 0x6
is_ping(b, i=1) = frame_type(b, i) == PING

check_ping_frame(b, i=1) = frame_length(b, i) != 8 ? FRAME_SIZE_ERROR :
                                                     NO_ERROR


"""
6.8.  GOAWAY                     https://tools.ietf.org/html/rfc7540#section-6.8

    +-+-------------------------------------------------------------+
    |R|                  Last-Stream-ID (31)                        |
    +-+-------------------------------------------------------------+
    |                      Error Code (32)                          |
    +---------------------------------------------------------------+
    |                  Additional Debug Data (*)                    |
    +---------------------------------------------------------------+
"""
const GOAWAY = 0x7
is_goaway(b, i=1) = frame_type(b, i) == GOAWAY

last_stream_id(b, i=1) = ntoh_32(b, payload_start(b, i)) & 0x7FFFFFFF

debug_start(b, i=1) = payload_start(b, i) + 8
debug_end(b, i=1) = payload_end(b, i)

debug(b, i=1) = debug_start(b, i), debug_end(b, i)

check_goaway_frame(b, i=1) = frame_length(b, i) < 8 ? FRAME_SIZE_ERROR :
                             stream_id(b, i) != 0   ? PROTOCOL_ERROR :
                                                      NO_ERROR

"""
11.4.  Error Code Registry      https://tools.ietf.org/html/rfc7540#section-11.4
"""
const NO_ERROR            = 0x0
const PROTOCOL_ERROR      = 0x1
const INTERNAL_ERROR      = 0x2
const FLOW_CONTROL_ERROR  = 0x3
const SETTINGS_TIMEOUT    = 0x4
const STREAM_CLOSED       = 0x5
const FRAME_SIZE_ERROR    = 0x6
const REFUSED_STREAM      = 0x7
const CANCEL              = 0x8
const COMPRESSION_ERROR   = 0x9
const CONNECT_ERROR       = 0xa
const ENHANCE_YOUR_CALM   = 0xb
const INADEQUATE_SECURITY = 0xc
const HTTP_1_1_REQUIRED   = 0xd



"""
6.9.  WINDOW_UPDATE              https://tools.ietf.org/html/rfc7540#section-6.9

    +-+-------------------------------------------------------------+
    |R|              Window Size Increment (31)                     |
    +-+-------------------------------------------------------------+
"""
const WINDOW_UPDATE = 0x8
is_window_update(b, i=1) = frame_type(b, i) == WINDOW_UPDATE

window_size_increment(b, i=1) = ntoh_32(b, payload_start(b, i)) & 0x7FFFFFFF

check_window_frame(b, i=1) =
    frame_length(b, i) != 4          ? FRAME_SIZE_ERROR :
    window_size_increment(b, i) == 0 ? PROTOCOL_ERROR :
                                       NO_ERROR

"""
6.10.  CONTINUATION             https://tools.ietf.org/html/rfc7540#section-6.10

    +---------------------------------------------------------------+
    |                   Header Block Fragment (*)                 ...
    +---------------------------------------------------------------+
"""
const CONTINUATION  = 0x9
is_continuation(b, i=1) = frame_type(b, i) == CONTINUATION

check_continuation_frame(b, i=1) = stream_id(b, i) == 0 ? PROTOCOL_ERROR :
                                                          NO_ERROR

end # module Frames
