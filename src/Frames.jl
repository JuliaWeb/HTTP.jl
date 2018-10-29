"""
HTTP Frames.                       https://tools.ietf.org/html/rfc7540#section-4


Copyright (c) 2018, Sam O'Connor
"""
module Frames

include("StackBuffers.jl")

# Errors

struct FramingError <: Exception
    code::Int
    description::String
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
f_length(frame) = ntoh_32(frame, 1) >> 8
f_type(  frame) = getbyte(frame, 4)
f_flags( frame) = getbyte(frame, 5)
f_stream(frame) = ntoh_31(frame, 6)

const FRAME_HEADER_SIZE 9
const PAYLOAD_START = FRAME_HEADER_SIZE  + 1

@inline check_frame_length(settings, l) =
    l <= settings[SETTINGS_MAX_FRAME_SIZE] || frame_length_error()

@noinline frame_length_error() = throw(FramingError(FRAME_SIZE_ERROR, """
    An endpoint MUST send an error code of FRAME_SIZE_ERROR if a
    frame exceeds the size defined in SETTINGS_MAX_FRAME_SIZE.
    https://tools.ietf.org/html/rfc7540#section-4.2
    """))

@inline function frame_header(l::UInt32, frame_type::UInt8,
                              flags::UInt8, stream_id::UInt32,
                              data=nothing)

    l = data === nothing ? 0 : length(data)
    frame = StackBuffer(FRAME_HEADER_SIZE + l)

    unsafe_store(frame, 1, hton(l << 8))
    unsafe_store(frame, 4, frame_type)
    unsafe_store(frame, 5, flags)
    unsafe_store(frame, 6, hton(stream_id))

    if data !== nothing
        unsafe_copyto!(pointer(frame, PAYLOAD_START), pointer(data), l)
    end

    return frame
end



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

is_end_stream(flags) = flags & 0x01 != 0
is_padded(flags)     = flags & 0x08 != 0

function process_data(connection, io, frame, flags, l)

    stream_id = f_stream(frame)
    stream = get_stream(connection, stream_id)

    if is_padded(flags)
        padding = read(io, UInt8)
        padding < l || frame_padding_error()
        process_data(stream, io, l - (1 + padding))
        read!(io, StackBuffer(padding))
    else
        process_data(stream, io, l)
    end

    if is_end_stream(flags)
        connection.state = :half_closed_remote
    end
end

@noinline frame_padding_error() = throw(FramingError(PROTOCOL_ERROR, """
    If the length of the padding is the length of the frame payload
    or greater, the recipient MUST treat this as a connection error
    (Section 5.4.1) of type PROTOCOL_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.1
    """))



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

const HEADER_FRAME_HEADER_SIZE_MAX = 6

is_end_headers(flags) = flags & 0x04 != 0
has_dependency(flags) = flags & 0x20 != 0

fragment_offset(flags) = (is_padded(flags) ? 1 : 0) +
                         (has_dependency(flags) ? 5 : 0)

function process_headers(connection, io, frame, flags, l)

    stream_id = f_stream(frame)
    stream_id > 0 || stream_zero_headers_error()
    stream_id > max_stream_id(connection) || stream_id_error()
    # FIXME promised stream ?

    padding = is_padded(flags) ? read(io, UInt8) : UInt8(0)
    offset = fragment_offset(flags)
    offset + padding < l || frame_too_small_error()
    header_block_length = l - padding - offset
    header_block = Vector{UInt8}(undef, header_block_length)

    state = is_end_stream(flags) ? :half_closed : :open
    stream = Stream(stream_id, state, header_block)
    if has_dependency(flags)
        read_priority(io, stream)
    end

    read!(io, header_block)
    read!(io, StackBuffer(padding))

    done = is_end_headers(flags)
    while !done
        done = process_continuation(connection, stream_id, io, header_block)
    end

    new_stream(connection, stream)
end

@noinline stream_id_error() = throw(FramingError(PROTOCOL_ERROR, """
    The identifier of a newly established stream MUST be numerically
    greater than all streams that the initiating endpoint has opened
    or reserved.
    https://tools.ietf.org/html/rfc7540#section-5.1.1
    """))

@noinline frame_too_small_error() = throw(FramingError(FRAME_SIZE_ERROR, """
    An endpoint MUST send an error code of FRAME_SIZE_ERROR if a frame
    ... is too small to contain mandatory frame data.
    https://tools.ietf.org/html/rfc7540#section-4.2
    """))

@noinline stream_zero_headers_error() = throw(FramingError(PROTOCOL_ERROR, """
    If a HEADERS frame is received whose stream identifier field is 0x0,
    the recipient MUST respond with a connection error (Section 5.4.1) of
    type PROTOCOL_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.2
    """))



"""
6.10.  CONTINUATION             https://tools.ietf.org/html/rfc7540#section-6.10

    +---------------------------------------------------------------+
    |                   Header Block Fragment (*)                 ...
    +---------------------------------------------------------------+
"""
const CONTINUATION  = 0x9

"""
Read CONTINUATION frame from `io`.
Append frame payload (Header Block Fragment) to `buf`.
https://tools.ietf.org/html/rfc7540#section-6.10
"""
function process_continuation(connection, stream_id, io, header_block)

    frame = read!(io, StackBuffer(FRAME_HEADER_SIZE))

    c_stream_id = f_stream(frame)
    c_stream_id > 0 || stream_zero_continuation_error()
    f_type(frame) == CONTINUATION &&
    c_stream_id == stream_id || continuation_error()

    l = f_length(frame)
    check_frame_length(connection.settings, l)
    i = length(header_block)
    resize!(header_block, i + l)
    unsafe_read(io, pointer(header_block, i + 1), l)

    return is_end_headers(f_flags(frame))
end

@noinline continuation_error() = throw(FramingError(PROTOCOL_ERROR, """
    A HEADERS frame without the END_HEADERS flag set MUST be followed
    by a CONTINUATION frame for the same stream.  A receiver MUST
    treat the receipt of any other type of frame or a frame on a
    different stream as a connection error (Section 5.4.1) of type
    PROTOCOL_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.2
    """))

@noinline stream_zero_continuation_error() = throw(FramingError(PROTOCOL_ERROR,
    """
    If a CONTINUATION frame is received whose stream identifier field is
    0x0, the recipient MUST respond with a connection error (Section 5.4.1)
    of type PROTOCOL_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.10
    """))



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

function read_priority(io, stream)
    payload = read!(io, StackBuffer(5))
    x = ntoh_32(payload, 1)

    stream.exclusive = x & 0x80000000 != 0
    stream.dependency = x & 0x7FFFFFFF
    stream.weight = getbyte(payload, 5)
end

function process_priority(connection, io, frame, flags, l)

    l == 5 || prority_frame_size_error()
    stream_id = f_stream(frame)
    stream_id > 0 || stream_zero_priority_error()
    stream = get_stream(connection, stream_id)

    read_priority(io, stream)

    #FIXME 
end

@noinline prority_frame_size_error() = throw(FramingError(FRAME_SIZE_ERROR, """
    A PRIORITY frame with a length other than 5 octets MUST be treated as
    a stream error (Section 5.4.2) of type FRAME_SIZE_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.3
    """))

@noinline stream_zero_priority_error() = throw(FramingError(PROTOCOL_ERROR, """
    If a PRIORITY frame is received with a stream identifier of 0x0, the
    recipient MUST respond with a connection error (Section 5.4.1) of type
    PROTOCOL_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.3
    """))



# End of Stream Frames

"""
6.4.  RST_STREAM                 https://tools.ietf.org/html/rfc7540#section-6.4

    +---------------------------------------------------------------+
    |                        Error Code (32)                        |
    +---------------------------------------------------------------+
"""
const RST_STREAM = 0x3

function process_rst_stream(connection, io, frame, flags, l)

    f_length(b) == 4 || rst_stream_size_error()
    stream_id = f_stream(frame)
    stream_id > 0 || stream_zero_rst_error()

    stream = get_stream(connection, stream_id)
    connection.streams[stream_id] = (:closed, stream)

    error_code = read(io, UInt32)
    #FIXME
end

@noinline rst_stream_size_error() = throw(FramingError(FRAME_SIZE_ERROR, """
    A RST_STREAM frame with a length other than 4 octets MUST be treated
    as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.4
    """))

@noinline stream_zero_rst_error() = throw(FramingError(PROTOCOL_ERROR, """
    RST_STREAM frames MUST be associated with a stream.  If a RST_STREAM
    frame is received with a stream identifier of 0x0, the recipient MUST
    treat this as a connection error (Section 5.4.1) of type
    PROTOCOL_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.4
    """))


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

is_ack(flags) = flags & 0x01 != 0

const SETTINGS_HEADER_TABLE_SIZE = 1
const SETTINGS_ENABLE_PUSH = 2
const SETTINGS_MAX_CONCURRENT_STREAMS = 3
const SETTINGS_INITIAL_WINDOW_SIZE = 4
const SETTINGS_MAX_FRAME_SIZE = 5
const SETTINGS_MAX_HEADER_LIST_SIZE = 6
const MAX_SETTINGS_ID = 6

const DEFAULT_SETTINGS = (()->begin
    v = Vector{UInt32}(undef, MAX_SETTINGS_ID)
    v[SETTINGS_HEADER_TABLE_SIZE] = 4096
    v[SETTINGS_ENABLE_PUSH] = 1
    v[SETTINGS_MAX_CONCURRENT_STREAMS] = 1000 #FIXME enforce
    v[SETTINGS_INITIAL_WINDOW_SIZE] = 65535
    v[SETTINGS_MAX_FRAME_SIZE] = 16384
    v[SETTINGS_MAX_HEADER_LIST_SIZE] = typemax(Int)
end)()

function process_settings(connection, io, frame, flags, l)

    f_stream(b, i) == 0 || settings_stream_id_error()
    !is_ack(f) || l == 0 || settings_ack_error()
    (l % 6) == 0 || settings_size_error()

    data = read!(io, StackBuffer(l))

    i = 1
    while i < l
        id = ntoh_16(data, i)
        i += 2
        value = ntoh_32(data, i)
        i += 4
        if id <= MAX_SETTINGS_ID
            set_peer_setting(connection, id, value)
        end
    end
    response = frame_header(SETTINGS, 0x01, UInt32(0))
    unsafe_write(io, pointer(response), length(response))
end

@noinline settings_ack_error() = throw(FramingError(FRAME_SIZE_ERROR, """
    Receipt of a SETTINGS frame with the ACK flag set and a length
    field value other than 0 MUST be treated as a connection error
    (Section 5.4.1) of type FRAME_SIZE_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.5
    """))

@noinline settings_size_error() = throw(FramingError(FRAME_SIZE_ERROR, """
    A SETTINGS frame with a length other than a multiple of 6 octets MUST
    be treated as a connection error (Section 5.4.1) of type
    FRAME_SIZE_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.5
    """))

@noinline settings_stream_id_error() = throw(FramingError(PROTOCOL_ERROR, """
    If an endpoint receives a SETTINGS frame whose stream identifier field
    is anything other than 0x0, the endpoint MUST respond with a connection
    error (Section 5.4.1) of type PROTOCOL_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.5
    """))



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

promise_fragment_offset(flags) = (is_padded(flags) ? 1 : 0) + 4

function process_push_promise(connection, io, frame, flags, l)
    stream_id = f_stream(frame)
    stream_id > 0 || stream_zero_push_error()

    padding = is_padded(flags) ? read(io, UInt8) : UInt8(0)
    offset = promise_fragment_offset(flags)
    offset + padding < l || frame_too_small_error()
    promised_stream_id = ntoh(read(io, UInt32)) & 0x7FFFFFFF

    header_block_length = l - padding - offset
    header_block = Vector{UInt8}(undef, header_block_length)

    state = :reserved_remote
    stream = Stream(promised_stream_id, state, header_block)

    read!(io, header_block)
    read!(io, StackBuffer(padding))

    done = is_end_headers(flags)
    while !done
        done = process_continuation(connection, stream_id, io, header_block)
    end

    new_stream(connection, stream)
end

@noinline stream_zero_push_error() = throw(FramingError(PROTOCOL_ERROR, """
    If the stream identifier field specifies the value 0x0, a recipient MUST
    respond with a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.6
    """))



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

function process_ping(connection, io, frame, flags, l)

    f_stream(frame) == 0 || ping_stream_id_error()
    l == 8 || ping_size_error()

    data = read!(io, StackBuffer(8))
    
    if !is_ack(flags)
        response = frame_header(PING, 0x01, UInt32(0), data)
        unsafe_write(io, pointer(response), length(response))
    end
end

@noinline ping_size_error() = throw(FramingError(FRAME_SIZE_ERROR, """
    Receipt of a PING frame with a length field value other than 8 MUST be
    treated as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.7
    """))

@noinline ping_stream_id_error() = throw(FramingError(PROTOCOL_ERROR, """
    If a PING frame is received with a stream identifier field value
    other than 0x0, the recipient MUST respond with a connection error
    (Section 5.4.1) of type PROTOCOL_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.7
    """))



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
const DEBUG_START = PAYLOAD_START + 8

function process_goaway(connection, io, frame, flags, l)

    l >= 8 || frame_too_small_error()
    f_stream(frame) == 0 || goaway_stream_id_error()

    payload = read!(io, StackBuffer(l))

    conncetion.last_stream_id = ntoh_31(payload, 1)
    conncetion.goaway_error = ntoh_32(payload, 5)
end

@noinline goaway_stream_id_error() = throw(FramingError(PROTOCOL_ERROR, """
    An endpoint MUST treat a GOAWAY frame with a stream identifier other
    than 0x0 as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.8
    """))

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

function process_window_update(connection, io, frame, flags, l)

    l == 4 || window_frame_size_error() 

    increment = ntoh(read(io, UInt32)) & 0x7FFFFFFF
    increment > 0 || window_size_error()

    stream_id = f_stream(frame)
    if stream_id == 0
        connection.window += increment
    else
        get_stream(connection, stream_id).window += increment
    end
end

@noinline window_frame_size_error() = throw(FramingError(FRAME_SIZE_ERROR, """
    A WINDOW_UPDATE frame with a length other than 4 octets MUST be
    treated as a connection error (Section 5.4.1) of type FRAME_SIZE_ERROR.
    https://tools.ietf.org/html/rfc7540#section-6.9
    """))

@noinline window_size_error() = throw(FramingError(PROTOCOL_ERROR, """
    A receiver MUST treat the receipt of a WINDOW_UPDATE frame with an
    flow-control window increment of 0 as a stream error (Section 5.4.2)
    of type PROTOCOL_ERROR
    https://tools.ietf.org/html/rfc7540#section-6.9
    """))



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



# Streams

mutable struct Stream
    id::UInt32
    state::Symbol
    headers::Vector{UInt8}
    exclusive::Bool
    dependency::UInt32
    weight::Int
    window::Int32
end

Stream(id, state) = Stream(id, state, headers, false, 0, 0, 65535)


mutable struct Connection
    settings::Vector{UInt32}
    peer_settings::Vector{UInt32}
    streams::Vector{Stream}
    goaway_error::UInt32
    last_stream_id::UInt32
    window::Int32
end

Connection() = Connection(copy(DEFAULT_SETTINGS),
                          copy(DEFAULT_SETTINGS),
                          Stream[], NO_ERROR, 0, 65535)

function set_setting(connection, id, value)
    connection.settings[id] = value
end

function set_peer_setting(connection, id, value)
    connection.peer_settings[id] = value
end

function get_stream(connection, stream_id)
    connection.streams[stream_id]
end

function new_stream(connection, stream)

#=FIXME
   The first use of a new stream identifier implicitly closes all
   streams in the "idle" state that might have been initiated by that
   peer with a lower-valued stream identifier.  For example, if a client
   sends a HEADERS frame on stream 7 without ever sending a frame on
   stream 5, then stream 5 transitions to the "closed" state when the
   first frame for stream 7 is sent or received.
=#

    resize!(connection.streams, stream.id)
    connection.streams[stream.id] = stream
end


function process_frame(connection, io)

    frame = read!(io, StackBuffer(FRAME_HEADER_SIZE))

    t = f_type(frame)
    l = f_length(frame)
    flags = f_flags(frame)

    check_frame_length(connection.settings, l)
    
    args = (connection, io, frame, flags, l)

        if t == DATA           process_data(args...)
    elseif t == HEADERS        process_headers(args...)
    elseif t == PRIORITY       process_priority(args...)
    elseif t == RST_STREAM     process_rst_stream(args...)
    elseif t == SETTINGS       process_settings(args...)
    elseif t == PUSH_PROMISE   process_push_promise(args...)
    elseif t == PING           process_ping(args...)
    elseif t == GOAWAY         process_goaway(args...)
    elseif t == WINDOW_UPDATE  process_window_update(args...)
    end

    nothing
end


end # module Frames
