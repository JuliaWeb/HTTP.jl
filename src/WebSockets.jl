module WebSockets

using Base64, LoggingExtras, UUIDs, Sockets
using MbedTLS: digest, MD_SHA1, SSLContext
using ..IOExtras, ..Streams, ..ConnectionPool, ..Messages, ..Conditions, ..Servers
import ..open

export WebSocket, send, receive, ping, pong

# 1st 2 bytes of a frame
primitive type FrameFlags 16 end
Base.UInt16(x::FrameFlags) = Base.bitcast(UInt16, x)
FrameFlags(x::UInt16) = Base.bitcast(FrameFlags, x)

const WS_FINAL =  0b1000000000000000
const WS_RSV1 =   0b0100000000000000
const WS_RSV2 =   0b0010000000000000
const WS_RSV3 =   0b0001000000000000
const WS_OPCODE = 0b0000111100000000
const WS_MASK =   0b0000000010000000
const WS_LEN =    0b0000000001111111

@enum OpCode::UInt8 CONTINUATION=0x00 TEXT=0x01 BINARY=0x02 CLOSE=0x08 PING=0x09 PONG=0x0A

iscontrol(opcode::OpCode) = opcode > BINARY

Base.propertynames(x::FrameFlags) = (:final, :rsv1, :rsv2, :rsv3, :opcode, :mask, :len)
function Base.getproperty(x::FrameFlags, nm::Symbol)
    if nm == :final
        return UInt16(x) & WS_FINAL > 0
    elseif nm == :rsv1
        return UInt16(x) & WS_RSV1 > 0
    elseif nm == :rsv2
        return UInt16(x) & WS_RSV2 > 0
    elseif nm == :rsv3
        return UInt16(x) & WS_RSV3 > 0
    elseif nm == :opcode
        return OpCode(((UInt16(x) & WS_OPCODE) >> 8) % UInt8)
    elseif nm == :masked
        return UInt16(x) & WS_MASK > 0
    elseif nm == :len
        return UInt16(x) & WS_LEN
    end
end

FrameFlags(final::Bool, opcode::OpCode, masked::Bool, len::Integer; rsv1::Bool=false, rsv2::Bool=false, rsv3::Bool=false) =
    FrameFlags(
        (final ? WS_FINAL : UInt16(0)) |
        (rsv1 ? WS_RSV1 : UInt16(0)) | (rsv2 ? WS_RSV2 : UInt16(0)) | (rsv3 ? WS_RSV3 : UInt16(0)) |
        (UInt16(opcode) << 8) |
        (masked ? WS_MASK : UInt16(0)) |
        (len % UInt16)
    )

Base.show(io::IO, x::FrameFlags) =
    print(io, "FrameFlags(", "final=", x.final, ", ", "opcode=", x.opcode, ", ", "masked=", x.masked, ", ", "len=", x.len, ")")

primitive type Mask 32 end
Base.UInt32(x::Mask) = Base.bitcast(UInt32, x)
Mask(x::UInt32) = Base.bitcast(Mask, x)
Base.getindex(x::Mask, i::Int) = (UInt32(x) >> (8 * ((i - 1) % 4))) % UInt8
Base.rand(::Type{Mask}) = Mask(rand(UInt32))
const EMPTY_MASK = Mask(UInt32(0))

struct Frame
    flags::FrameFlags
    extendedlen::Union{Nothing, UInt16, UInt64}
    mask::Mask
    # when sending, Vector{UInt8} if client, any AbstractVector{UInt8} if server
    # when receiving:
      # CONTINUATION: String or Vector{UInt8} based on first fragment frame opcode TEXT/BINARY
      # TEXT: String
      # BINARY/PING/PONG: Vector{UInt8}
      # CLOSE: CloseFrameBody
    payload::Any
end

wslength(l) = l < 0x7E ? (UInt8(l), nothing) :
              l <= 0xFFFF ? (0x7E, UInt16(l)) :
                            (0x7F, UInt64(l))

function mask!(bytes::Vector{UInt8}, mask)
    for i in 1:length(bytes)
        @inbounds bytes[i] = bytes[i] ⊻ mask[i]
    end
    return
end

# send method Frame constructor
function Frame(final::Bool, opcode::OpCode, client::Bool, payload::AbstractVector{UInt8}; rsv1::Bool=false, rsv2::Bool=false, rsv3::Bool=false)
    len, extlen = wslength(length(payload))
    if client
        mask = Base.rand(Mask)
        mask!(payload, mask)
    else
        mask = EMPTY_MASK
    end
    return Frame(FrameFlags(final, opcode, client, len; rsv1, rsv2, rsv3), extlen, mask, payload)
end

Base.show(io::IO, x::Frame) =
    print(io, "Frame(", "flags=", x.flags, ", ", "extendedlen=", x.extendedlen, ", ", "mask=", x.mask, ", ", "payload=", x.payload, ")")

# reading a single frame
# If _The WebSocket Connection is Closed_ and no Close control frame was received by the
# endpoint (such as could occur if the underlying transport connection
# is lost), _The WebSocket Connection Close Code_ is considered to be 1006.
@noinline iocheck(io) = isopen(io) || throw(WebSocketError(CloseFrameBody(1006, "WebSocket connection is closed")))

function readframe(io::IO, ::Type{Frame}, buffer::Vector{UInt8}=UInt8[], first_fragment_opcode::OpCode=CONTINUATION)
    iocheck(io)
    flags = FrameFlags(ntoh(read(io, UInt16)))
    if flags.len == 0x7E
        extlen = ntoh(read(io, UInt16))
        len = UInt64(extlen)
    elseif flags.len == 0x7F
        extlen = ntoh(read(io, UInt64))
        len = extlen
    else
        extlen = nothing
        len = UInt64(flags.len)
    end
    mask = flags.masked ? Mask(read(io, UInt32)) : EMPTY_MASK
    resize!(buffer, len)
    if len > 0
        # NOTE: we could support a pure streaming case by allowing the caller to pass
        # an IO instead of buffer and writing directly from io -> out_io.
        # The tricky case would be server-side streaming, where we need to unmask
        # the incoming client payload; we could just buffer the payload + unmask
        # and then write out to the out_io.
        read!(io, buffer)
    end
    if flags.masked
        mask!(buffer, mask)
    end
    if flags.opcode == CONTINUATION && first_fragment_opcode == CONTINUATION
        throw(WebSocketError(CloseFrameBody(1002, "Continuation frame cannot be the first frame in a message")))
    elseif first_fragment_opcode != CONTINUATION && flags.opcode in (TEXT, BINARY)
        throw(WebSocketError(CloseFrameBody(1002, "Received unfragmented frame while still processing fragmented frame")))
    end
    op = flags.opcode == CONTINUATION ? first_fragment_opcode : flags.opcode
    if op == TEXT
        payload = unsafe_string(pointer(buffer), len)
    elseif op == CLOSE
        if len == 1
            throw(WebSocketError(CloseFrameBody(1002, "Close frame cannot have body of length 1")))
        end
        control_len_check(len)
        if len >= 2
            st = Int(UInt16(buffer[1]) << 8 | buffer[2])
            validclosecheck(st)
            status = st
        else
            status = 1005
        end
        payload = CloseFrameBody(status, len > 2 ? unsafe_string(pointer(buffer) + 2, len - 2) : "")
        utf8check(payload.message)
    else # BINARY
        payload = copy(buffer)
    end
    return Frame(flags, extlen, mask, payload)
end

# writing a single frame
function writeframe(io::IO, x::Frame)
    n = write(io.io, hton(UInt16(x.flags)))
    if x.extendedlen !== nothing
        n += write(io.io, hton(x.extendedlen))
    end
    if x.mask != EMPTY_MASK
        n += write(io.io, UInt32(x.mask))
    end
    pl = x.payload
    # manually unroll a few known type cases to help the compiler
    if pl isa Vector{UInt8}
        n += write(io.io, pl)
    elseif pl isa Base.CodeUnits{UInt8, String}
        n += write(io.io, pl)
    else
        n += write(io.io, pl)
    end
    return n
end

"Status codes according to RFC 6455 7.4.1"
@noinline validclosecheck(x) = (1000 <= x < 5000 && !(x in (1004, 1005, 1006, 1016, 1100, 2000, 2999))) || throw(WebSocketError(CloseFrameBody(1002, "Invalid close status code")))
const STATUS_CODE_DESCRIPTION = Dict{Int, String}(
    1000=>"Normal",                     1001=>"Going Away",
    1002=>"Protocol Error",             1003=>"Unsupported Data",
    1004=>"Reserved",                   1005=>"No Status Recvd- reserved",
    1006=>"Abnormal Closure- reserved", 1007=>"Invalid frame payload data",
    1008=>"Policy Violation",           1009=>"Message too big",
    1010=>"Missing Extension",          1011=>"Internal Error",
    1012=>"Service Restart",            1013=>"Try Again Later",
    1014=>"Bad Gateway",                1015=>"TLS Handshake")

struct CloseFrameBody
    status::Int
    message::String
end

struct WebSocketError <: Exception
    message::Union{String, CloseFrameBody}
end

# Close frame status codes that are "ok"
isok(x) = x isa WebSocketError && x.message isa CloseFrameBody && (x.message.status == 1000 || x.message.status == 1001 || x.message.status == 1005)

mutable struct WebSocket
    id::UUID
    io::Connection
    request::Request
    response::Response
    maxframesize::Int
    maxfragmentation::Int
    client::Bool
    readbuffer::Vector{UInt8}
    writebuffer::Vector{UInt8}
    readclosed::Bool
    writeclosed::Bool
end

const DEFAULT_MAX_FRAG = 1024

WebSocket(io::Connection, req=Request(), resp=Response(); client::Bool=true, maxframesize::Integer=typemax(Int), maxfragmentation::Integer=DEFAULT_MAX_FRAG) =
    WebSocket(uuid4(), io, req, resp, maxframesize, maxfragmentation, client, UInt8[], UInt8[], false, false)

isclosed(ws::WebSocket) = ws.readclosed && ws.writeclosed

# Handshake
function isupgrade(r::Message)
    ((r isa Request && r.method == "GET") ||
     (r isa Response && r.status == 101)) &&
    (hasheader(r, "Connection", "upgrade") ||
     hasheader(r, "Connection", "keep-alive, upgrade")) &&
    hasheader(r, "Upgrade", "websocket")
end

@noinline handshakeerror() = throw(WebSocketError(CloseFrameBody(1002, "Websocket handshake failed")))

function hashedkey(key)
    hashkey = "$(strip(key))258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    return base64encode(digest(MD_SHA1, hashkey))
end

function open(f::Function, url; suppress_close_error::Bool=false, verbose=false, headers=[], maxframesize::Integer=typemax(Int), maxfragmentation::Integer=DEFAULT_MAX_FRAG, kw...)
    key = base64encode(rand(UInt8, 16))
    headers = [
        "Upgrade" => "websocket",
        "Connection" => "Upgrade",
        "Sec-WebSocket-Key" => key,
        "Sec-WebSocket-Version" => "13",
        headers...
    ]
    # HTTP.open
    open("GET", url, headers; verbose=verbose, kw...) do http
        startread(http)
        isupgrade(http.message) || handshakeerror()
        if header(http, "Sec-WebSocket-Accept") != hashedkey(key)
            throw(WebSocketError("Invalid Sec-WebSocket-Accept\n" * "$(http.message)"))
        end
        io = http.stream
        ws = WebSocket(io, http.message.request, http.message; maxframesize, maxfragmentation)
        @debugv 2 "$(ws.id): WebSocket opened"
        try
            f(ws)
        catch e
            if !isok(e)
                suppress_close_error || @error "$(ws.id): error" (e, catch_backtrace())
            end
            if !isclosed(ws)
                if e isa WebSocketError && e.message isa CloseFrameBody
                    close(ws, e.message)
                else
                    close(ws, CloseFrameBody(1008, "Unexpected client websocket error"))
                end
            end
        finally
            if !isclosed(ws)
                close(ws, CloseFrameBody(1000, ""))
            end
        end
    end
end

function listen(f::Function, host="localhost", port::Integer=UInt16(8081); verbose=false, kw...)
    Servers.listen(host, port; verbose=verbose, kw...) do http
        upgrade(f, http; kw...)
    end
end

function upgrade(f::Function, http::Streams.Stream; suppress_close_error::Bool=false, maxframesize::Integer=typemax(Int), maxfragmentation::Integer=DEFAULT_MAX_FRAG, kw...)
    @debugv 2 "Server websocket upgrade requested"
    isupgrade(http.message) || handshakeerror()
    if !hasheader(http, "Sec-WebSocket-Version", "13")
        throw(WebSocketError("Expected \"Sec-WebSocket-Version: 13\"!\n" * "$(http.message)"))
    end
    if !hasheader(http, "Sec-WebSocket-Key")
        throw(WebSocketError("Expected \"Sec-WebSocket-Key header\"!\n" * "$(http.message)"))
    end
    setstatus(http, 101)
    setheader(http, "Upgrade" => "websocket")
    setheader(http, "Connection" => "Upgrade")
    key = header(http, "Sec-WebSocket-Key")
    setheader(http, "Sec-WebSocket-Accept" => hashedkey(key))
    startwrite(http)
    io = http.stream
    req = http.message
    ws = WebSocket(io, req, req.response; client=false, maxframesize, maxfragmentation)
    @debugv 2 "$(ws.id): WebSocket upgraded; connection established"
    try
        f(ws)
    catch e
        if !isok(e)
            suppress_close_error || @error "$(ws.id): Unexpected websocket server error" (e, catch_backtrace())
        end
        if !isclosed(ws)
            if e isa WebSocketError && e.message isa CloseFrameBody
                close(ws, e.message)
            else
                close(ws, CloseFrameBody(1011, "Unexpected server websocket error"))
            end
        end
    finally
        if !isclosed(ws)
            close(ws, CloseFrameBody(1000, ""))
        end
    end
end

# Sending messages
isbinary(x) = x isa AbstractVector{UInt8}
istext(x) = x isa AbstractString
opcode(x) = isbinary(x) ? BINARY : TEXT

function payload(ws, x)
    if ws.client
        # if we're client, we need to mask the payload, so use our writebuffer for masking
        pload = isbinary(x) ? x : codeunits(string(x))
        len = length(pload)
        resize!(ws.writebuffer, len)
        copyto!(ws.writebuffer, pload)
        return ws.writebuffer
    else
        # if we're server, we just need to make sure payload is AbstractVector{UInt8}
        return isbinary(x) ? x : codeunits(string(x))
    end
end

function Sockets.send(ws::WebSocket, x)
    @debugv 2 "$(ws.id): Writing non-control message"
    @require !ws.writeclosed
    if !isbinary(x) && !istext(x)
        # if x is not single binary or text, then assume it's an iterable of binary or text
        # and we'll send fragmented message
        first = true
        n = 0
        state = iterate(x)
        if state === nothing
            # x was not binary or text, but is an empty iterable, send single empty frame
            x = ""
            @goto write_single_frame
        end
        @debugv 2 "$(ws.id): Writing fragmented message"
        item, st = state
        # we prefetch next state so we know if we're on the last item or not
        # so we can appropriately set the FIN bit for the last fragmented frame
        nextstate = iterate(x, st)
        while true
            n += writeframe(ws.io, Frame(nextstate === nothing, first ? opcode(item) : CONTINUATION, ws.client, payload(ws, item)))
            first = false
            nextstate === nothing && break
            item, st = nextstate
            nextstate = iterate(x, st)
        end
    else
        # single binary or text frame for message
@label write_single_frame
        return writeframe(ws.io, Frame(true, opcode(x), ws.client, payload(ws, x)))
    end
end

# control frames
function ping(ws::WebSocket, data=UInt8[])
    @require !ws.writeclosed
    @debugv 2 "$(ws.id): sending ping"
    return writeframe(ws.io, Frame(true, PING, ws.client, payload(ws, data)))
end

function pong(ws::WebSocket, data=UInt8[])
    @require !ws.writeclosed
    @debugv 2 "$(ws.id): sending pong"
    return writeframe(ws.io, Frame(true, PONG, ws.client, payload(ws, data)))
end

function Base.close(ws::WebSocket, body::CloseFrameBody=CloseFrameBody(1000, ""))
    isclosed(ws) && return
    @debugv 2 "$(ws.id): Closing websocket"
    ws.writeclosed = true
    data = Vector{UInt8}(body.message)
    prepend!(data, reinterpret(UInt8, [hton(UInt16(body.status))]))
    try
        writeframe(ws.io, Frame(true, CLOSE, ws.client, data))
    catch
        # ignore thrown errors here because we're closing anyway
    end
    # if we're initiating the close, wait until we receive the
    # responding close frame or timeout
    if !ws.readclosed
        Timer(5) do t
            ws.readclosed = true
        end
    end
    while !ws.readclosed
        try
            receive(ws)
        catch
            # ignore thrown errors here because we're closing anyway
            # but set readclosed so we don't keep trying to read
            ws.readclosed = true
        end
    end
    # we either recieved the responding CLOSE frame and readclosed was set
    # or there was an error/timeout reading it; in any case, readclosed should be closed now
    @assert ws.readclosed
    # if we're the server, it's our job to close the underlying socket
    if !ws.client
        close(ws.io)
    end
    return
end

# Receiving messages

# returns whether additional frames should be read
# true if fragmented message or a ping/pong frame was handled
@noinline control_len_check(len) = len > 125 && throw(WebSocketError(CloseFrameBody(1002, "Invalid length for control frame")))
@noinline utf8check(x) = isvalid(x) || throw(WebSocketError(CloseFrameBody(1007, "Invalid UTF-8")))

function checkreadframe!(ws::WebSocket, frame::Frame)
    if frame.flags.rsv1 || frame.flags.rsv2 || frame.flags.rsv3
        throw(WebSocketError(CloseFrameBody(1002, "Reserved bits set in control frame")))
    end
    opcode = frame.flags.opcode
    if iscontrol(opcode) && !frame.flags.final
        throw(WebSocketError(CloseFrameBody(1002, "Fragmented control frame")))
    end
    if opcode == CLOSE
        ws.readclosed = true
        # reply with Close control frame if we didn't initiate close
        if !ws.writeclosed
            close(ws)
        end
        throw(WebSocketError(frame.payload))
    elseif opcode == PING
        control_len_check(frame.flags.len)
        pong(ws, frame.payload)
        return false
    elseif opcode == PONG
        control_len_check(frame.flags.len)
        return false
    elseif frame.flags.final && frame.flags.opcode == TEXT && frame.payload isa String
        utf8check(frame.payload)
    end
    return frame.flags.final
end

_append(x::AbstractVector{UInt8}, y::AbstractVector{UInt8}) = append!(x, y)
_append(x::String, y::String) = string(x, y)

# low-level for reading a single frame
readframe(ws::WebSocket) = readframe(ws.io, Frame, ws.readbuffer)

function receive(ws::WebSocket)
    @debugv 2 "$(ws.id): Reading message"
    @require !ws.readclosed
    frame = readframe(ws.io, Frame, ws.readbuffer)
    @debugv 2 "$(ws.id): Received frame: $frame"
    done = checkreadframe!(ws, frame)
    # common case of reading single non-control frame
    done && return frame.payload
    opcode = frame.flags.opcode
    iscontrol(opcode) && return receive(ws)
    # if we're here, we're reading a fragmented message
    payload = frame.payload
    while true
        frame = readframe(ws.io, Frame, ws.readbuffer, opcode)
        @debugv 2 "$(ws.id): Received frame: $frame"
        done = checkreadframe!(ws, frame)
        if !iscontrol(frame.flags.opcode)
            payload = _append(payload, frame.payload)
            @debugv 2 "$(ws.id): payload len = $(length(payload))"
        end
        done && break
    end
    payload isa String && utf8check(payload)
    @debugv 2 "Read message: $(payload[1:min(1024, sizeof(payload))])"
    return payload
end

# convenience construct for iterating over messages for lifetime of websocket
function Base.iterate(ws::WebSocket, st=nothing)
    isclosed(ws) && return nothing
    try
        return receive(ws), nothing
    catch e
        isok(e) && return nothing
        rethrow(e)
    end
end

end # module WebSockets
