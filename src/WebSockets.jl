module WebSockets

using ..Base64
using MbedTLS: digest, MD_SHA1, SSLContext
import ..HTTP
using ..IOExtras
using ..Streams
import ..ConnectionPool
using HTTP: header
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
    server::Bool
    rxpayload::Vector{UInt8}
    txpayload::Vector{UInt8}
    txclosed::Bool
    rxclosed::Bool
end

function WebSocket(io::T; server=false, binary=false) where T <: IO
   WebSocket{T}(io, binary ? WS_BINARY : WS_TEXT, server,
                UInt8[], UInt8[], false, false)
end



# Handshake

function is_upgrade(req::HTTP.Request)
    is_get = req.method == "GET"
    # "upgrade" for Chrome and "keep-alive, upgrade" for Firefox.
    is_upgrade = HTTP.hasheader(req, "Connection", "upgrade")
    is_websockets = HTTP.hasheader(req, "Upgrade", "websocket")
    return is_get && is_upgrade && is_websockets
end


function is_upgrade(res::HTTP.Response)
    is_101 = res.status == 101
    # "upgrade" for Chrome and "keep-alive, upgrade" for Firefox.
    is_upgrade = HTTP.hasheader(res, "Connection", "upgrade")
    is_websockets = HTTP.hasheader(res, "Upgrade", "websocket")
    return is_101 && is_upgrade && is_websockets
end


function check_upgrade(http)
    if !is_upgrade(http.message)
        throw(WebSocketError(0, "Invalid WebSocket upgrade:\n $(http.message)"))
    end
end


function accept_hash(key)
    hashkey = "$(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    return base64encode(digest(MD_SHA1, hashkey))
end


function open(f::Function, url; binary=false, verbose=false, kw...)

    key = base64encode(rand(UInt8, 16))

    headers = [
        "Upgrade" => "websocket",
        "Connection" => "Upgrade",
        "Sec-WebSocket-Key" => key,
        "Sec-WebSocket-Version" => "13"
    ]

    HTTP.open("GET", url, headers;
              reuse_limit=0, verbose=verbose ? 2 : 0, kw...) do http

        startread(http)

        check_upgrade(http)

        if header(http, "Sec-WebSocket-Accept") != accept_hash(key)
            throw(WebSocketError(0, "Invalid Sec-WebSocket-Accept:\n $(http.message)"))
        end

        io = ConnectionPool.getrawstream(http)
        f(WebSocket(io; binary=binary))
    end
end

function listen(f::Function,
                host::String="localhost", port::UInt16=UInt16(8081);
                binary=false, verbose=false)

    HTTP.listen(host, port; verbose=verbose) do http
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

    io = ConnectionPool.getrawstream(http)
    f(WebSocket(io; binary=binary, server=true))
end



# Sending Frames

function Base.write(ws::WebSocket, opcode::UInt8, data::Vector{UInt8})
    lock(ws.io)
    n = length(data)
    try
        #  0 1 2 3 4 5 6 7 
        # +-+-+-+-+-------+
        # |F|R|R|R| opcode|
        # |I|S|S|S|  (4)  |
        # |N|V|V|V|       |
        # | |1|2|3|       |
        # +-+-+-+-+-------+
        write(ws.io, opcode)
        #  0                   1                   2                   3                   4                   5                   6     
        #  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3
        # +-+-------------+-------------------------------+------------------------------------------------------------------------------+
        # |M| Payload len |    Extended payload length    |    Extended payload length continued                                         |
        # |A|     (7)     |             (16/64)           |          if payload len == 127                                               |
        # |S|             |   (if payload len==126/127)   |                                                                              |
        # |K|             |                               |                                                                              |
        # +-+-------------+-------------------------------+------------------------------------------------------------------------------+
        mask = ws.server ? 0x00 : 0x80
        if n <= 125
            write(ws.io, mask | UInt8(n))
        elseif n <= typemax(UInt16)
            write(ws.io, mask | UInt8(126))
            write(ws.io, UInt16(n))
        elseif n <= typemax(UInt64)
            write(ws.io, mask | UInt8(127))
            write(ws.io, UInt64(n))
        else
            error("Attempted to send too much data for one websocket fragment\n")
        end
        #  0                   1           
        #  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 
        # +-------------------------------+
        # |Masking-key, if MASK set to 1  |
        # +-------------------------------+
        ws.txpayload = data
        if mask > 0
            masking_key = mask!(ws.txpayload, data, n)
            write(ws.io,masking_key)
        end
        # +--------------+
        # | Payload Data |
        # +--------------+
        n > 0 && write(ws.io,ws.txpayload)
    finally
        flush(ws.io)
        unlock(ws.io)
    end
    return n
end
Base.write(ws::WebSocket,opcode::UInt8,x::String) = write(ws,opcode,convert(Vector{UInt8},x))
Base.write(ws::WebSocket,data::Vector{UInt8}) = write(ws,WS_FINAL | ws.frame_type,data)
Base.write(ws::WebSocket,x::String) = write(ws,convert(Vector{UInt8},x))


function IOExtras.closewrite(ws::WebSocket)
    @require !ws.txclosed
    opcode = WS_FINAL | WS_CLOSE
    write(ws, opcode, UInt8[])
    ws.txclosed = true
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


function Base.close(ws::WebSocket)
    if !ws.txclosed
        closewrite(ws)
    end
    while !ws.rxclosed
        readavailable(ws)
    end
end


Base.isopen(ws::WebSocket) = !ws.rxclosed


# Receiving Frames

Base.eof(ws::WebSocket) = eof(ws.io)

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


function Base.readavailable(ws::WebSocket)
    h = readheader(ws.io)

    is_ssl = typeof(ws.io) == SSLContext

    is_ssl && println("**************************************")
    is_ssl && println("Starting readavailable for SSLContext:")
    is_ssl && println("**************************************")

    is_ssl && println(h)

    if h.length > 0
        readbytes!(ws.io, ws.rxpayload, h.length)
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
        write(ws, WS_FINAL | WS_PONG, ws.rxpayload)
        return readavailable(ws)
    else
        l = Int(h.length)
        if h.hasmask
            mask!(ws.rxpayload, ws.rxpayload, l, reinterpret(UInt8, [h.mask]))
        end
        return resize!(ws.rxpayload,l)
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
