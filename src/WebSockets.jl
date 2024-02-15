module WebSockets

using Base64, LoggingExtras, UUIDs, Sockets, Random
using MbedTLS: digest, MD_SHA1, SSLContext
using ..IOExtras, ..Streams, ..Connections, ..Messages, ..Conditions, ..Servers
using ..Exceptions: current_exceptions_to_string
import ..open
import ..HTTP # for doc references

export WebSocket, send, receive, ping, pong

# 1st 2 bytes of a frame
primitive type FrameFlags 16 end
uint16(x::FrameFlags) = Base.bitcast(UInt16, x)
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
    ux = uint16(x)
    if nm == :final
        return ux & WS_FINAL > 0
    elseif nm == :rsv1
        return ux & WS_RSV1 > 0
    elseif nm == :rsv2
        return ux & WS_RSV2 > 0
    elseif nm == :rsv3
        return ux & WS_RSV3 > 0
    elseif nm == :opcode
        return OpCode(((ux & WS_OPCODE) >> 8) % UInt8)
    elseif nm == :masked
        return ux & WS_MASK > 0
    elseif nm == :len
        return ux & WS_LEN
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
mask() = Mask(rand(Random.RandomDevice(), UInt32))
const EMPTY_MASK = Mask(UInt32(0))

# representation of a single websocket frame
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

# given a payload total length, split into 7-bit length + 16-bit or 64-bit extended length
wslength(l) = l < 0x7E ? (UInt8(l), nothing) :
              l <= 0xFFFF ? (0x7E, UInt16(l)) :
                            (0x7F, UInt64(l))

# give a mutable byte payload + mask, perform client websocket masking
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
        msk = mask()
        mask!(payload, msk)
    else
        msk = EMPTY_MASK
    end
    return Frame(FrameFlags(final, opcode, client, len; rsv1, rsv2, rsv3), extlen, msk, payload)
end

Base.show(io::IO, x::Frame) =
    print(io, "Frame(", "flags=", x.flags, ", ", "extendedlen=", x.extendedlen, ", ", "mask=", x.mask, ", ", "payload=", x.payload, ")")

# reading a single frame

# If _The WebSocket Connection is Closed_ and no Close control frame was received by the
# endpoint (such as could occur if the underlying transport connection
# is lost), _The WebSocket Connection Close Code_ is considered to be 1006.
@noinline iocheck(io) = isopen(io) || throw(WebSocketError(CloseFrameBody(1006, "WebSocket connection is closed")))

"""
    WebSockets.readframe(ws) -> WebSockets.Frame
    WebSockets.readframe(io, Frame, buffer, first_fragment_opcode) -> WebSockets.Frame

Read a single websocket frame from a `WebSocket` or `IO` stream.
Frame may be a control frame with `PING`, `PONG`, or `CLOSE` opcode.
Frame may also be part of fragmented message, with opcdoe `CONTINUATION`;
`first_fragment_opcode` should be passed from the 1st frame of a fragmented message
to ensure each subsequent frame payload is converted correctly (String or Vector{UInt8}).
"""
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
    # even if len is 0, we need to resize! so previously filled buffers aren't erroneously reused
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
        # TODO: possible avoid the double copy from read!(io, buffer) + unsafe_string?
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
    n = write(io.io, hton(uint16(x.flags)))
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
const STATUS_CODE_DESCRIPTION = Dict{Int, String}(
    1000=>"Normal",                     1001=>"Going Away",
    1002=>"Protocol Error",             1003=>"Unsupported Data",
    1004=>"Reserved",                   1005=>"No Status Recvd- reserved",
    1006=>"Abnormal Closure- reserved", 1007=>"Invalid frame payload data",
    1008=>"Policy Violation",           1009=>"Message too big",
    1010=>"Missing Extension",          1011=>"Internal Error",
    1012=>"Service Restart",            1013=>"Try Again Later",
    1014=>"Bad Gateway",                1015=>"TLS Handshake")

@noinline validclosecheck(x) = (1000 <= x < 5000 && !(x in (1004, 1005, 1006, 1016, 1100, 2000, 2999))) || throw(WebSocketError(CloseFrameBody(1002, "Invalid close status code")))

"""
    WebSockets.CloseFrameBody(status, message)

Represents the payload of a CLOSE control websocket frame.
For error close `status`, it can be wrapped in a `WebSocketError`
and thrown.
"""
struct CloseFrameBody
    status::Int
    message::String
end

struct WebSocketError <: Exception
    message::Union{String, CloseFrameBody}
end

"""
    WebSockets.isok(x::WebSocketError) -> Bool

Returns true if the `WebSocketError` has a non-error status code.
When calling `receive(websocket)`, if a CLOSE frame is received,
the CLOSE frame body is parsed and thrown inside the `WebSocketError`,
but if the CLOSE frame has a non-error status code, it's safe to
ignore the error and return from the `WebSockets.open` or `WebSockets.listen`
calls without throwing.
"""
isok(x) = x isa WebSocketError && x.message isa CloseFrameBody && (x.message.status == 1000 || x.message.status == 1001 || x.message.status == 1005)

"""
    WebSocket(io::HTTP.Connection, req, resp; client=true)

Representation of a websocket connection.
Use `WebSockets.open` to open a websocket connection, passing a
handler function `f(ws)` to send and receive messages.
Use `WebSockets.listen` to listen for incoming websocket connections,
passing a handler function `f(ws)` to send and receive messages.

Call `send(ws, msg)` to send a message; if `msg` is an `AbstractString`,
a TEXT websocket message will be sent; if `msg` is an `AbstractVector{UInt8}`,
a BINARY websocket message will be sent. Otherwise, `msg` should be an iterable
of either `AbstractString` or `AbstractVector{UInt8}`, and a fragmented message
will be sent, one frame for each iterated element.

Control frames can be sent by calling `ping(ws[, data])`, `pong(ws[, data])`,
or `close(ws[, body::WebSockets.CloseFrameBody])`. Calling `close` will initiate
the close sequence and close the underlying connection.

To receive messages, call `receive(ws)`, which will block until a non-control,
full message is received. PING messages will automatically be responded to when
received. CLOSE messages will also be acknowledged and then a `WebSocketError`
will be thrown with the `WebSockets.CloseFrameBody` payload, which may include
a non-error CLOSE frame status code. `WebSockets.isok(err)` can be called to
check if the CLOSE was normal or unexpected. Fragmented messages will be
received until the final frame is received and the full concatenated payload
can be returned. `receive(ws)` returns a `Vector{UInt8}` for BINARY messages,
and a `String` for TEXT messages.

For convenience, `WebSocket`s support the iteration protocol, where each iteration
will `receive` a non-control message, with iteration terminating when the connection
is closed. E.g.:
```julia
WebSockets.open(url) do ws
    for msg in ws
        # do cool stuff with msg
    end
end
```
"""
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

"""
    WebSockets.isclosed(ws) -> Bool

Check whether a `WebSocket` has sent and received CLOSE frames.
"""
isclosed(ws::WebSocket) = ws.readclosed && ws.writeclosed

# Handshake
"Check whether a HTTP.Request or HTTP.Response is a websocket upgrade request/response"
function isupgrade(r::Message)
    ((r isa Request && r.method == "GET") ||
     (r isa Response && r.status == 101)) &&
    (hasheader(r, "Connection", "upgrade") ||
     hasheader(r, "Connection", "keep-alive, upgrade")) &&
    hasheader(r, "Upgrade", "websocket")
end

# Renamed in HTTP@1
@deprecate is_upgrade isupgrade

@noinline handshakeerror() = throw(WebSocketError(CloseFrameBody(1002, "Websocket handshake failed")))

function hashedkey(key)
    hashkey = "$(strip(key))258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    return base64encode(digest(MD_SHA1, hashkey))
end

"""
    WebSockets.open(handler, url; verbose=false, kw...)

Initiate a websocket connection to `url` (which should have schema like `ws://` or `wss://`),
and call `handler(ws)` with the websocket connection. Passing `verbose=true` or `verbose=2`
will enable debug logging for the life of the websocket connection.
`handler` should be a function of the form `f(ws) -> nothing`, where `ws` is a [`WebSocket`](@ref).
Supported keyword arguments are the same as supported by [`HTTP.request`](@ref).
Typical websocket usage is:
```julia
WebSockets.open(url) do ws
    # iterate incoming websocket messages
    for msg in ws
        # send message back to server or do other logic here
        send(ws, msg)
    end
    # iteration ends when the websocket connection is closed by server or error
end
```
"""
function open(f::Function, url; suppress_close_error::Bool=false, verbose=false, headers=[], maxframesize::Integer=typemax(Int), maxfragmentation::Integer=DEFAULT_MAX_FRAG, kw...)
    key = base64encode(rand(Random.RandomDevice(), UInt8, 16))
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
        # later stream logic checks to see if the HTTP message is "complete"
        # by seeing if ntoread is 0, which is typemax(Int) for websockets by default
        # so set it to 0 so it's correctly viewed as "complete" once we're done
        # doing websocket things
        http.ntoread = 0
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

"""
    WebSockets.listen(handler, host, port; verbose=false, kw...)
    WebSockets.listen!(handler, host, port; verbose=false, kw...) -> HTTP.Server

Listen for websocket connections on `host` and `port`, and call `handler(ws)`,
which should be a function taking a single `WebSocket` argument.
Keyword arguments `kw...` are the same as supported by [`HTTP.listen`](@ref).
Typical usage is like:
```julia
WebSockets.listen(host, port) do ws
    # iterate incoming websocket messages
    for msg in ws
        # send message back to client or do other logic here
        send(ws, msg)
    end
    # iteration ends when the websocket connection is closed by client or error
end
```
"""
function listen end

listen(f, args...; kw...) = Servers.listen(http -> upgrade(f, http; kw...), args...; kw...)
listen!(f, args...; kw...) = Servers.listen!(http -> upgrade(f, http; kw...), args...; kw...)

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
            suppress_close_error || @error begin
                msg = current_exceptions_to_string()
                "$(ws.id): Unexpected websocket server error. $msg"
            end
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

"""
    send(ws::WebSocket, msg)

Send a message on a websocket connection. If `msg` is an `AbstractString`,
a TEXT websocket message will be sent; if `msg` is an `AbstractVector{UInt8}`,
a BINARY websocket message will be sent. Otherwise, `msg` should be an iterable
of either `AbstractString` or `AbstractVector{UInt8}`, and a fragmented message
will be sent, one frame for each iterated element.

Control frames can be sent by calling `ping(ws[, data])`, `pong(ws[, data])`,
or `close(ws[, body::WebSockets.CloseFrameBody])`. Calling `close` will initiate
the close sequence and close the underlying connection.
"""
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
"""
    ping(ws, data=[])

Send a PING control frame on a websocket connection. `data` is an optional
body to send with the message. PONG messages are automatically responded
to when a PING message is received by a websocket connection.
"""
function ping(ws::WebSocket, data=UInt8[])
    @require !ws.writeclosed
    @debugv 2 "$(ws.id): sending ping"
    return writeframe(ws.io, Frame(true, PING, ws.client, payload(ws, data)))
end

"""
    pong(ws, data=[])

Send a PONG control frame on a websocket connection. `data` is an optional
body to send with the message. Note that PING messages are automatically
responded to internally by the websocket connection with a corresponding
PONG message, but in certain cases, a unidirectional PONG message can be
used as a one-way heartbeat.
"""
function pong(ws::WebSocket, data=UInt8[])
    @require !ws.writeclosed
    @debugv 2 "$(ws.id): sending pong"
    return writeframe(ws.io, Frame(true, PONG, ws.client, payload(ws, data)))
end

"""
    close(ws, body::WebSockets.CloseFrameBody=nothing)

Initiate a close sequence on a websocket connection. `body` is an optional
`WebSockets.CloseFrameBody` with a status code and optional reason message.
If a CLOSE frame has already been received, then a responding CLOSE frame is sent
and the connection is closed. If a CLOSE frame hasn't already been received, the
CLOSE frame is sent and `receive` is attempted to receive the responding CLOSE
frame.
"""
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
            !ws.client && isopen(ws.io) && close(ws.io)
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
    !ws.client && isopen(ws.io) && close(ws.io)
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

"""
    receive(ws::WebSocket) -> Union{String, Vector{UInt8}}

Receive a message from a websocket connection. Returns a `String` if
the message was TEXT, or a `Vector{UInt8}` if the message was BINARY.
If control frames (ping or pong) are received, they are handled
automatically and a non-control message is waited for. If a CLOSE
message is received, it is responded to and a `WebSocketError` is thrown
with the `WebSockets.CloseFrameBody` as the error value. This error can
be checked with `WebSockets.isok(err)` to see if the closing was "normal"
or if an actual error occurred. For fragmented messages, the incoming
frames will continue to be read until the final fragment is received.
The bodies of each fragment are concatenated into the final message
returned by `receive`. Note that `WebSocket` objects can be iterated,
where each iteration yields a message until the connection is closed.
"""
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

"""
    iterate(ws)

Continuously call `receive(ws)` on a `WebSocket` connection, with
each iteration yielding a message until the connection is closed.
E.g.
```julia
for msg in ws
    # do something with msg
end
```
"""
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
