module WebSockets

using ..Base64
using MbedTLS: digest, MD_SHA1, SSLContext
import ..HTTP
using ..IOExtras
using ..Streams
import ..ConnectionPool
using HTTP: header, headercontains
import ..@debug, ..DEBUG_LEVEL, ..@require, ..precondition_error
import ..string

const WS_FINAL = 0x80
const WS_CONTINUATION = 0x00
const WS_TEXT = 0x01
const WS_BINARY = 0x02
const WS_CLOSE = 0x08
const WS_PING = 0x09
const WS_PONG = 0x0A

const WS_MASK = 0x80

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

struct WebSocketError <: Exception
    status::UInt16
    message::String
end

struct WebSocketHeader
    opcode::UInt8
    final::Bool
    length::UInt
    hasmask::Bool
    mask::UInt32
end

mutable struct WebSocket{T <: IO} <: IO
    io::T
    frame_type::UInt8
    server::Bool
    rxpayload::Vector{UInt8}
    txpayload::Vector{UInt8}
    txclosed::Bool
    rxclosed::Bool
    request::Union{Nothing,HTTP.Request}
end

function WebSocket(io::T; server=false, binary=false, request=nothing) where T <: IO
   WebSocket{T}(io, binary ? WS_BINARY : WS_TEXT, server,
                UInt8[], UInt8[], false, false, request)
end

# Handshake

function is_upgrade(r::HTTP.Message)
    ((r isa HTTP.Request && r.method == "GET") ||
     (r isa HTTP.Response && r.status == 101)) &&
    (HTTP.hasheader(r, "Connection", "upgrade") ||
     HTTP.hasheader(r, "Connection", "keep-alive, upgrade")) &&
    HTTP.hasheader(r, "Upgrade", "websocket")
end

function check_upgrade(http)

    if !hasheader(http, "Upgrade", "websocket")
        throw(WebSocketError(0, "Expected \"Upgrade: websocket\"!\n" *
                                "$(http.message)"))
    end

    if !(hasheader(http, "Connection", "upgrade") ||
         hasheader(http, "Connection", "keep-alive, upgrade"))
        throw(WebSocketError(0, "Expected \"Connection: upgrade\"!\n" *
                                "$(http.message)"))
    end
end

function accept_hash(key)
    hashkey = "$(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    return base64encode(digest(MD_SHA1, hashkey))
end

function open(f::Function, url; binary=false, verbose=false, headers = [], kw...)

    key = base64encode(rand(UInt8, 16))

    headers = [
        "Upgrade" => "websocket",
        "Connection" => "Upgrade",
        "Sec-WebSocket-Key" => key,
        "Sec-WebSocket-Version" => "13",
        headers...
    ]

    HTTP.open("GET", url, headers;
              reuse_limit=0, verbose=verbose ? 2 : 0, kw...) do http

        startread(http)

        status = http.message.status
        if status != 101
            return
        end

        check_upgrade(http)

        if header(http, "Sec-WebSocket-Accept") != accept_hash(key)
            throw(WebSocketError(0, "Invalid Sec-WebSocket-Accept\n" *
                                    "$(http.message)"))
        end

        io = http.stream
        ws = WebSocket(io; binary=binary)
        try
            f(ws)
        finally
            close(ws)
        end
    end
end

function listen(f::Function,
                host::String="localhost", port::UInt16=UInt16(8081);
                binary=false, verbose=false, kw...)

    HTTP.listen(host, port; verbose=verbose, kw...) do http
        upgrade(f, http; binary=binary)
    end
end

function upgrade(f::Function, http::HTTP.Stream; binary=false)

    check_upgrade(http)
    if !hasheader(http, "Sec-WebSocket-Version", "13")
        throw(WebSocketError(0, "Expected \"Sec-WebSocket-Version: 13\"!\n" *
                                "$(http.message)"))
    end

    setstatus(http, 101)
    setheader(http, "Upgrade" => "websocket")
    setheader(http, "Connection" => "Upgrade")
    key = header(http, "Sec-WebSocket-Key")
    setheader(http, "Sec-WebSocket-Accept" => accept_hash(key))

    startwrite(http)

    io = http.stream
    req = http.message
    ws = WebSocket(io; binary=binary, server=true, request=req)
    try
        f(ws)
    finally
        close(ws)
    end
end

# Sending Frames

function Base.unsafe_write(ws::WebSocket, p::Ptr{UInt8}, n::UInt)
    return wswrite(ws, unsafe_wrap(Array, p, n))
end

function Base.write(ws::WebSocket, x1, x2, xs...)
    local n::Int = 0
    n += wswrite(ws, ws.frame_type, x1)
    xs = (x2, xs...)
    l = length(xs)
    for i in 1:l
        n += wswrite(ws, i == l ? WS_FINAL : WS_CONTINUATION, xs[i])
    end
    return n
end

function IOExtras.closewrite(ws::WebSocket; statuscode=nothing)
    @require !ws.txclosed
    opcode = WS_FINAL | WS_CLOSE
    @debug 1 "WebSocket ⬅️  $(WebSocketHeader(opcode, 0x00))"
    if statuscode === nothing
        write(ws.io, [opcode, 0x00])
    else
        wswrite(ws, opcode, reinterpret(UInt8, [hton(UInt16(statuscode))]))
    end
    ws.txclosed = true
end

wslength(l) = l < 0x7E ? (UInt8(l), UInt8[]) :
              l <= 0xFFFF ? (0x7E, reinterpret(UInt8, [hton(UInt16(l))])) :
                            (0x7F, reinterpret(UInt8, [hton(UInt64(l))]))

wswrite(ws::WebSocket, x) = wswrite(ws, WS_FINAL | ws.frame_type, x)

wswrite(ws::WebSocket, opcode::UInt8, x) = wswrite(ws, opcode, bytes(x))

function wswrite(ws::WebSocket, opcode::UInt8, bytes::AbstractVector{UInt8})

    n = length(bytes)
    len, extended_len = wslength(n)
    if ws.server
        mask = UInt8[]
        txpayload = bytes
    else
        len |= WS_MASK
        mask = mask!(ws.txpayload, bytes, n)
        txpayload = ws.txpayload
    end

    @debug 1 "WebSocket ⬅️  $(WebSocketHeader(opcode, len, extended_len, mask))"
    write(ws.io, vcat(opcode, len, extended_len, mask))

    @debug 2 "          ⬅️  $(txpayload[1:n])"
    unsafe_write(ws.io, pointer(txpayload), n)
end

function mask!(to, from, l, mask=rand(UInt8, 4))
    if length(to) < l
        resize!(to, l)
    end
    for i in 1:l
        to[i] = from[i] ⊻ mask[((i-1) % 4)+1]
    end
    return mask
end

function Base.close(ws::WebSocket; statuscode::Union{Int, Nothing}=nothing)
    if !ws.txclosed
        try
            closewrite(ws; statuscode=statuscode)
        catch e
            e isa Base.IOError || rethrow(e)
        end
    end
    while !eof(ws) # FIXME Timeout in case other end does not send CLOSE?
        try
            readframe(ws)
        catch e
            e isa WebSocketError || e isa Base.IOError || rethrow(e)
        end
    end
    close(ws.io)
end

Base.isopen(ws::WebSocket) = !ws.rxclosed

# Receiving Frames

Base.eof(ws::WebSocket) = ws.rxclosed || eof(ws.io)

Base.readavailable(ws::WebSocket) = readmessage(ws)

function readmessage(ws::WebSocket)
    payload, header = _readframe(ws)
    bytes = collect(payload)
    while !(header.final)
        payload, header = _readframe(ws)
        @assert header.opcode == WS_CONTINUATION
        append!(bytes, payload)
    end
    return bytes
end

function readheader(io::IO)
    b = UInt8[0,0]
    read!(io, b)
    len = b[2] & ~WS_MASK
    WebSocketHeader(
        b[1] & 0x0F,
        b[1] & WS_FINAL > 0,
        len == 0x7F ? UInt(ntoh(read(io, UInt64))) :
        len == 0x7E ? UInt(ntoh(read(io, UInt16))) : UInt(len),
        b[2] & WS_MASK > 0,
        b[2] & WS_MASK > 0 ? read(io, UInt32) : UInt32(0))
end

readframe(ws::WebSocket) = first(_readframe(ws))

function _readframe(ws::WebSocket)
    h = readheader(ws.io)
    @debug 1 "WebSocket ➡️  $h"

    len = Int(h.length)

    if len > 0
        if length(ws.rxpayload) < len
            resize!(ws.rxpayload, len)
        end
        unsafe_read(ws.io, pointer(ws.rxpayload), len)
        @debug 2 "          ➡️  \"$(String(ws.rxpayload[1:len]))\""
    end
    
    if h.hasmask
        mask!(ws.rxpayload, ws.rxpayload, len, reinterpret(UInt8, [h.mask]))
    end

    if h.opcode == WS_CLOSE
        ws.rxclosed = true
        if len >= 2
            status = UInt16(ws.rxpayload[1]) << 8 | ws.rxpayload[2]
            if status != 1000
                message = String(ws.rxpayload[3:len])
                status_descr = get(STATUS_CODE_DESCRIPTION, Int(status), "")
                msg = "Status: $(status_descr), Internal Code: $(message)"
                throw(WebSocketError(status, msg))
            end
        end
        return view(ws.rxpayload, 1:0), h
    elseif h.opcode == WS_PING
        wswrite(ws, WS_FINAL | WS_PONG, ws.rxpayload[1:len])
        return _readframe(ws)
    elseif h.opcode == WS_PONG
        return _readframe(ws)
    else
        return view(ws.rxpayload, 1:len), h
    end
end

function WebSocketHeader(bytes...)
    io = IOBuffer()
    write(io, bytes...)
    seek(io, 0)
    return readheader(io)
end

function Base.show(io::IO, h::WebSocketHeader)
    print(io, "WebSocketHeader(",
          h.opcode == WS_CONTINUATION ? "CONTINUATION" :
          h.opcode == WS_TEXT ? "TEXT" :
          h.opcode == WS_BINARY ? "BINARY" :
          h.opcode == WS_CLOSE ? "CLOSE" :
          h.opcode == WS_PING ? "PING" :
          h.opcode == WS_PONG ? "PONG" : h.opcode,
          h.final ? " | FINAL, " : ", ",
          h.length > 0 ? "$(Int(h.length))-byte payload" : "",
          h.hasmask ? ", mask = $(string(h.mask, base=16))" : "",
          ")")
end

end # module WebSockets
