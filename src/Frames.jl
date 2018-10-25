"""
HTTP Frames.                       https://tools.ietf.org/html/rfc7540#section-4


Copyright (c) 2018, Sam O'Connor
"""
module Frames



# Errors

struct FramingError <: Exception
    code::Int
end



# Low Level Byte Loading

getbyte(b, i) = @inbounds b[i]

ntoh_16(b, i) = ntoh(unsafe_load(Ptr{UInt16}(pointer(b, i))))
ntoh_32(b, i) = ntoh(unsafe_load(Ptr{UInt32}(pointer(b, i))))
ntoh_31(b, i) = ntoh_32(b, i) & 0x7FFFFFFF



# Reading Frame Headers

"""
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

`f_length`: Frame Payload Length
`f_type`:   Frame Type
`f_flags`:  Frame Flags
`f_stream`: Frame Stream Identifier.
"""
f_length(b, i=1) = ntoh_32(b, i + 0) >> 8
f_type(  b, i=1) = getbyte(b, i + 3)
f_flags( b, i=1) = getbyte(b, i + 4)
f_stream(b, i=1) = ntoh_31(b, i + 5)

"""
Index of first byte of Frame Payload.
"""
payload_start(b, i=1) = i + 9

"""
Index of last byte of Frame Payload.
"""
payload_end(b, i=1) = i + 8 + f_length(b, i)

"""
Indices of first and last bytes of Frame Payload.
"""
payload(b, i=1) = payload_start(b, i), payload_end(b, i)


"""
    An endpoint MUST send an error code of FRAME_SIZE_ERROR if a frame
    exceeds the size defined in SETTINGS_MAX_FRAME_SIZE
https://tools.ietf.org/html/rfc7540#section-4.2
"""
check_frame_length(settings, l) =
    l <= settings[SETTINGS_MAX_FRAME_SIZE] ?  NO_ERROR : FRAME_SIZE_ERROR



# Data Frames

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
is_data(b, i=1) = f_type(b, i) == DATA

const END_STREAM_FLAG = 0x01
const PADDED_FLAG     = 0x08

is_end_stream(f) = f & 0x01 != 0
is_padded(f)     = f & 0x08 != 0

frame_is_end_stream(b, i=1) = is_stream_end(f_flags(b, i))
frame_is_padded(    b, i=1) = is_padded(    f_flags(b, i))

pad_length(b, i=1, f=f_flags(b, i)) = is_padded(f) ? getbyte(b, i + 9) : 0

data_start(b, i=1, f=f_flags(b, i)) = payload_start(b, i) +
                                      (is_padded(f) ? 1 : 0)
data_end(  b, i=1, f=f_flags(b, i)) = payload_end(  b, i) -
                                      pad_length(b, i, f)

data(b, i=1, f=f_flags(b, i)) = data_start(b, i, f), data_end(b, i, f)


"""
   The total number of padding octets is determined by the value of the
   Pad Length field.  If the length of the padding is the length of the
   frame payload or greater, the recipient MUST treat this as a
   connection error (Section 5.4.1) of type PROTOCOL_ERROR.

https://tools.ietf.org/html/rfc7540#section-6.1
"""
check_frame_padding(b, i=1) =
    pad_length(b, i) < f_length(b, i) ? NO_ERROR : PROTOCOL_ERROR



# Headers Frames

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
is_headers(b, i=1) = f_type(b, i) == HEADERS

const END_HEADERS_FLAG = 0x04
const PRIORITY_FLAG    = 0x20

is_end_headers(f) = f & 0x04 != 0
has_dependency(f) = f & 0x20 != 0
frame_has_dependency(b, i=1) = has_dependency(f_flags(b, i))

weight(b, i=1, f=f_flags(b, i)) =
    1 + getbyte(b, payload_start(b, i) + (is_padded(f) ? 5 : 4))

function stream_dependency(b, i=1, f=f_flags(b, i))::Tuple{Bool,UInt32}
    x = ntoh_32(b, payload_start(b, i) + (is_padded(f) ? 1 : 0))
    (x & 0x80000000 != 0), (x & 0x7FFFFFFF)
end

fragment_start(b, i=1, f=f_flags(b, i)) = data_start(b, i, f) +
                                          (has_dependency(f) ? 5 : 0)
fragment_end(  b, i=1, f=f_flags(b, i)) = data_end(b, i, f)

function fragment(b, i=1, f=f_flags(b, i))
    j = fragment_end(b, i, f)
    i = fragment_start(b, i, f)
    if i > j
        throw(FramingError(FRAME_SIZE_ERROR))
    end
    return i, j
end


"""
6.10.  CONTINUATION             https://tools.ietf.org/html/rfc7540#section-6.10

    +---------------------------------------------------------------+
    |                   Header Block Fragment (*)                 ...
    +---------------------------------------------------------------+
"""
const CONTINUATION  = 0x9
is_continuation(b, i=1) = f_type(b, i) == CONTINUATION

check_continuation_frame(b, i=1) = f_stream(b, i) == 0 ? PROTOCOL_ERROR :
                                                         NO_ERROR



# Stream Priority Setting Frames

"""
6.3.  PRIORITY                   https://tools.ietf.org/html/rfc7540#section-6.3

    +-+-------------------------------------------------------------+
    |E|                  Stream Dependency (31)                     |
    +-+-------------+-----------------------------------------------+
    |   Weight (8)  |
    +-+-------------+
"""
const PRIORITY = 0x2
is_priority(b, i=1) = f_type(b, i) == PRIORITY

check_priority_frame(b, i=1) =
    f_length(b, i) != 5 ? FRAME_SIZE_ERROR :
    f_stream(b, i) == 0 ? PROTOCOL_ERROR :
                          NO_ERROR



# End of Stream Frames

"""
6.4.  RST_STREAM                 https://tools.ietf.org/html/rfc7540#section-6.4

    +---------------------------------------------------------------+
    |                        Error Code (32)                        |
    +---------------------------------------------------------------+
"""
const RST_STREAM = 0x3
is_rst_stream(b, i=1) = f_type(b, i) == RST_STREAM

error_code(b, i=1) = ntoh_32(b, payload_start(b, i) +
                                (f_type(b, i) == GOAWAY ? 4 : 0))

check_rst_stream_frame(b, i=1) =
    f_length(b, i) != 4 ? FRAME_SIZE_ERROR :
    f_stream(b, i) == 0 ? PROTOCOL_ERROR :
                          NO_ERROR



# Connection Settings Frames

"""
6.5.  SETTINGS                   https://tools.ietf.org/html/rfc7540#section-6.5

    +-------------------------------+
    |       Identifier (16)         |
    +-------------------------------+-------------------------------+
    |                        Value (32)                             |
    +---------------------------------------------------------------+
"""
const SETTINGS = 0x4
is_settings(b, i=1) = f_type(b, i) == SETTINGS

const ACK_FLAG = 0x01

is_ack(b, i, f=f_flags(b,i)) = f & 0x01 != 0

const SETTINGS_HEADER_TABLE_SIZE = 1
const SETTINGS_ENABLE_PUSH = 2
const SETTINGS_MAX_CONCURRENT_STREAMS = 3
const SETTINGS_INITIAL_WINDOW_SIZE = 4
const SETTINGS_MAX_FRAME_SIZE = 5
const SETTINGS_MAX_HEADER_LIST_SIZE = 6

settings_count(b, i=1) = f_length(b, i) / 6

setting(b, n, i=1) = (i = payload_start(b, i) + (n - 1) * 6;
                      (ntoh_16(b, i) => ntoh_32(b, i+2)))

check_settings_frame(b, i=1, f=f_flags(b, i)) = (
    l = f_length(b, i);
    is_ack(b, i, f) && l != 0 ? FRAME_SIZE_ERROR :
    (l % 6) != 0              ? FRAME_SIZE_ERROR :
    f_stream(b, i) != 0       ? PROTOCOL_ERROR :
                                NO_ERROR)


# Push Promise Frames

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
is_push_promise(b, i=1) = f_type(b, i) == PUSH_PROMISE

promised_stream_id(b, i=1, f=f_flags(b, i)) =
    ntoh_32(b, payload_start(b, i) + (is_padded(f) ? 1 : 0)) & 0x7FFFFFFF

promise_fragment_start(b, i=1, f=f_flags(b, i)) = payload_start(b, i) +
                                                  (is_padded(f) ? 5 : 4)

promise_fragment_end(b, i=1, f=f_flags(b, i)) = fragment_end(b, i, f)

promise_fragment(b, i=1, f=f_flags(b, i)) = promise_fragment_start(b, i, f),
                                            promise_fragment_end(b, i, f)

check_promise_frame(b, i=1, f=f_flags(b, i)) =
    promise_fragment_start(b, i, f) >
        promise_fragment_end(b, i, f) ? FRAME_SIZE_ERROR :
        f_stream(b, i) != 0           ? PROTOCOL_ERROR :
                                        NO_ERROR



# Ping Frames

"""
6.7.  PING                       https://tools.ietf.org/html/rfc7540#section-6.7

    +---------------------------------------------------------------+
    |                                                               |
    |                      Opaque Data (64)                         |
    |                                                               |
    +---------------------------------------------------------------+
"""
const PING = 0x6
is_ping(b, i=1) = f_type(b, i) == PING


check_ping_frame(b, i=1) = f_length(b, i) != 8 ? FRAME_SIZE_ERROR :
                                                 NO_ERROR



# End of Connection Frames

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
is_goaway(b, i=1) = f_type(b, i) == GOAWAY

last_stream_id(b, i=1) = ntoh_32(b, payload_start(b, i)) & 0x7FFFFFFF

debug_start(b, i=1) = payload_start(b, i) + 8
debug_end(b, i=1) = payload_end(b, i)

debug(b, i=1) = debug_start(b, i), debug_end(b, i)

check_goaway_frame(b, i=1) = f_length(b, i)  < 8 ? FRAME_SIZE_ERROR :
                             f_stream(b, i) != 0 ? PROTOCOL_ERROR :
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



# Flow Control Frames

"""
6.9.  WINDOW_UPDATE              https://tools.ietf.org/html/rfc7540#section-6.9

    +-+-------------------------------------------------------------+
    |R|              Window Size Increment (31)                     |
    +-+-------------------------------------------------------------+
"""
const WINDOW_UPDATE = 0x8
is_window_update(b, i=1) = f_type(b, i) == WINDOW_UPDATE

window_size_increment(b, i=1) = ntoh_32(b, payload_start(b, i)) & 0x7FFFFFFF

check_window_frame(b, i=1) =
    f_length(b, i) != 4              ? FRAME_SIZE_ERROR :
    window_size_increment(b, i) == 0 ? PROTOCOL_ERROR :
                                       NO_ERROR



# Stream Processing

"""
5.1.  Stream States                https://tools.ietf.org/html/rfc7540#section-5

   The lifecycle of a stream is shown in Figure 2.

                                +--------+
                        send PP |        | recv PP
                       ,--------|  idle  |--------.
                      /         |        |         \\
                     v          +--------+          v
              +----------+          |           +----------+
              |          |          | send H /  |          |
       ,------| reserved |          | recv H    | reserved |------.
       |      | (local)  |          |           | (remote) |      |
       |      +----------+          v           +----------+      |
       |          |             +--------+             |          |
       |          |     recv ES |        | send ES     |          |
       |   send H |     ,-------|  open  |-------.     | recv H   |
       |          |    /        |        |       \\     |          |
       |          v   v         +--------+         v   v          |
       |      +----------+          |           +----------+      |
       |      |   half   |          |           |   half   |      |
       |      |  closed  |          | send R /  |  closed  |      |
       |      | (remote) |          | recv R    | (local)  |      |
       |      +----------+          |           +----------+      |
       |           |                |                 |           |
       |           | send ES /      |       recv ES / |           |
       |           | send R /       v        send R / |           |
       |           | recv R     +--------+   recv R   |           |
       | send R /  `----------->|        |<-----------'  send R / |
       | recv R                 | closed |               recv R   |
       `----------------------->|        |<----------------------'
                                +--------+

          send:   endpoint sends this frame
          recv:   endpoint receives this frame

          H:  HEADERS frame (with implied CONTINUATIONs)
          PP: PUSH_PROMISE frame (with implied CONTINUATIONs)
          ES: END_STREAM flag
          R:  RST_STREAM frame
"""

function append_fragment end
function set_dependency end
function set_end_stream end
function is_end_stream end

function process_idle(stream, b, i=1, t=f_type(b, i), f=f_flags(b, i))

    if t == HEADERS

        if has_dependency(f)
            e, d = stream_dependency(b, i, f)
            w = weight(b, i, f)
            set_dependency(stream, e, d, w)
        end

        i, j = fragment(b, i, f)
        append_fragment(stream, b, i, j)

        if is_end_headers(f)
            return is_end_stream(f) ? :half_closed : :open
        else
            if is_end_stream(f)
                set_end_stream(stream)
            end
            return :idle
        end

    elseif t == CONTINUATION

        i, j = payload(b, i)
        append_fragment(stream, b, i, j)

        return !is_end_headers(f) ? :idle :
            is_end_stream(stream) ? :half_closed :
                                    :open
    end

    throw(FramingError(PROTOCOL_ERROR))
end



# IO

function read_frame!(settings, io::IO, buf::AbstractVector{UInt8}, i=1)
    @assert length(buf) >= 9
    unsafe_read(io, pointer(buf, i), 9)
    i += 9
    l = f_length(buf)
    resize!(buf, i + l)
    e = check_frame_length(settings, l)
    if e != NO_ERROR
        throw(FramingError(e))
    end
    unsafe_read(io, pointer(buf, i), l)
end



end # module Frames
