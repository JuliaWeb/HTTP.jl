# Codec-only microbenchmarks (no sockets): frame encode, masked encode,
# decoder throughput for masked (server-receive) and unmasked (client-receive)
# input. 2.x only — uses internal codec API.
#   julia --project=. bench/websocket/codec_micro.jl
using HTTP
const W = HTTP.WebSockets

function bench(f, label, bytes_per_iter; secs=0.8)
    f()  # compile
    n = 0
    t0 = time_ns()
    while time_ns() - t0 < secs * 1e9
        f(); n += 1
    end
    elapsed = (time_ns() - t0) / 1e9
    a = @allocated f()
    println(rpad(label, 30), lpad(round(Int, n / elapsed), 12), " iters/s  ",
            lpad(round(n * bytes_per_iter / elapsed / 1024^3; digits=2), 8), " GiB/s  ",
            lpad(a, 9), " B/iter alloc")
end

function masked_wire(payload)  # client-style frame as it appears on the wire
    f = W.WsFrame(opcode=UInt8(W.WsOpcode.BINARY), payload=payload, fin=true,
                  masked=true, masking_key=(0x12, 0x34, 0x56, 0x78))
    return Vector{UInt8}(W.ws_encode_frame(f))
end
plain_wire(payload) = Vector{UInt8}(W.ws_encode_frame(
    W.WsFrame(opcode=UInt8(W.WsOpcode.BINARY), payload=payload, fin=true)))

for sz in (16, 4 * 1024, 64 * 1024, 1024 * 1024)
    payload = rand(UInt8, sz)
    szl = sz >= 1024 ? "$(sz ÷ 1024)k" : "$(sz)b"

    frame_plain = W.WsFrame(opcode=UInt8(W.WsOpcode.BINARY), payload=payload, fin=true)
    frame_masked = W.WsFrame(opcode=UInt8(W.WsOpcode.BINARY), payload=payload, fin=true,
                             masked=true, masking_key=(0x12, 0x34, 0x56, 0x78))
    bench(() -> W.ws_encode_frame(frame_plain), "encode_unmasked_$szl", sz)
    bench(() -> W.ws_encode_frame(frame_masked), "encode_masked_$szl", sz)

    wire_u = plain_wire(payload)     # what a CLIENT receives
    wire_m = masked_wire(payload)    # what a SERVER receives
    dec_u = W.ws_decoder_new()
    dec_m = W.ws_decoder_new()
    bench(() -> W.ws_decoder_process!(dec_u, wire_u), "decode_unmasked_$szl", sz)
    bench(() -> W.ws_decoder_process!(dec_m, wire_m), "decode_masked_$szl", sz)
    println()
end
