module WebSockets

using Base64
using Unicode
using MbedTLS: digest, MD_SHA1, SSLContext
import ..HTTP
using ..HTTP.IOExtras
import ..ConnectionPool
using HTTP.header
import ..@debug, ..DEBUG_LEVEL, ..@require, ..precondition_error



const WS_FINAL = 0x80
const WS_CONTINUATION = 0x00
const WS_TEXT = 0x01
const WS_BINARY = 0x02
const WS_CLOSE = 0x08
const WS_PING = 0x09
const WS_PONG = 0x0A

const WS_MASK = 0x80


struct WebSocketError <: Exception
    status::Int16
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
    rxpayload::Vector{UInt8}
    txpayload::Vector{UInt8}
    txclosed::Bool
    rxclosed::Bool
end

function WebSocket(io::T; binary=false) where T <: IO
   WebSocket{T}(io, binary ? WS_BINARY : WS_TEXT,
                UInt8[], UInt8[], false, false)
end



# Handshake


function open(f::Function, url; binary=false, kw...)

    key = base64encode(rand(UInt8, 16))

    headers = [
        "Upgrade" => "websocket",
        "Connection" => "Upgrade",
        "Sec-WebSocket-Key" => key,
        "Sec-WebSocket-Version" => "13"
    ]

    HTTP.open("GET", url, headers; reuse_limit=0, kw...) do http

        startread(http)

        status = http.message.status
        if status != 101
            return
        end

        upgrade = header(http, "Upgrade")
        if lowercase(upgrade) != "websocket"
            throw(WebSocketError(0, "Expected \"Upgrade: websocket\"!\n" *
                                    "$(http.message)"))
        end

        connection = header(http, "Connection")
        if lowercase(connection) != "upgrade"
            throw(WebSocketError(0, "Expected \"Connection: upgrade\"!\n" *
                                    "$(http.message)"))
        end

        hashkey = "$(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        accepthash = base64encode(digest(MD_SHA1, hashkey))
        accept = header(http, "Sec-WebSocket-Accept") 
        if accept != accepthash
            throw(WebSocketError(0, "Invalid Sec-WebSocket-Accept\n" *
                                    "$(http.message)"))
        end

        io = ConnectionPool.getrawstream(http)
        f(WebSocket(io; binary=binary))
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


function IOExtras.closewrite(ws::WebSocket)
    @require !ws.txclosed
    opcode = WS_FINAL | WS_CLOSE
    @debug 1 "WebSocket ⬅️  $(WebSocketHeader(opcode, 0x00))"
    write(ws.io, opcode, 0x00)
    ws.txclosed = true
end


wslength(l) = l < 0x7E ? (UInt8(l), UInt8[]) : 
              l <= 0xFFFF ? (0x7E, reinterpret(UInt8, [UInt16(l)])) :
                            (0x7F, reinterpret(UInt8, [UInt64(l)]))


wswrite(ws::WebSocket, x) = wswrite(ws, WS_FINAL | ws.frame_type, x)

wswrite(ws::WebSocket, opcode::UInt8, x) = wswrite(ws, opcode, Vector{UInt8}(x))

function wswrite(ws::WebSocket, opcode::UInt8, bytes::Vector{UInt8})

    n = length(bytes)
    len, extended_len = wslength(n)
    len |= WS_MASK
    mask = mask!(ws, bytes)

    @debug 1 "WebSocket ⬅️  $(WebSocketHeader(opcode, len, extended_len, mask))"
    write(ws.io, opcode, len, extended_len, mask)
  
    @debug 2 "          ⬅️  $(ws.txpayload[1:n])"
    unsafe_write(ws.io, pointer(ws.txpayload), n)
end


function mask!(ws::WebSocket, bytes::Vector{UInt8})
    mask = rand(UInt8, 4)
    l = length(bytes)
    if length(ws.txpayload) < l
        resize!(ws.txpayload, l)
    end
    for i in 1:l
        ws.txpayload[i] = bytes[i] ⊻ mask[((i-1) % 4)+1]
    end
    return mask
end


function Base.close(ws::WebSocket)
    if !ws.txclosed
        closewrite(ws)
    end
    while !ws.rxclosed
        readframe(ws)
    end
end


Base.isopen(ws::WebSocket) = !ws.rxclosed



# Receiving Frames

Base.eof(ws::WebSocket) = eof(ws.io)

Base.readavailable(ws::WebSocket) = collect(readframe(ws))


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
        b[2] & WS_MASK > 0 ? ntoh(read(io, UInt32)) : UInt32(0))
end


function readframe(ws::WebSocket)
    h = readheader(ws.io)
    @debug 1 "WebSocket ➡️  $h"

    if h.length > 0
        if length(ws.rxpayload) < h.length
            resize!(ws.rxpayload, h.length)
        end
        unsafe_read(ws.io, pointer(ws.rxpayload), h.length)
        @debug 2 "          ➡️  \"$(String(ws.rxpayload[1:h.length]))\""
    end

    if h.opcode == WS_CLOSE
        ws.rxclosed = true
        if h.length >= 2
            status = UInt16(ws.rxpayload[1]) << 8 | ws.rxpayload[2]
            if status != 1000
                message = String(ws.rxpayload[3:h.length])
                throw(WebSocketError(status, message))
            end
        end
        return UInt8[]
    elseif h.opcode == WS_PING
        write(ws.io, [WS_PONG, 0x00])
        wswrite(ws, WS_FINAL | WS_PONG, ws.rxpayload)
        return readframe(ws)
    else
        return view(ws.rxpayload, 1:Int(h.length))
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
          h.hasmask ? ", mask = $(hex(h.mask))" : "",
          ")")
end


end # module WebSockets
