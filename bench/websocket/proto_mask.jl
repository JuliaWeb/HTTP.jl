# Prototype: vectorized WebSocket masking kernel + correctness fuzz + speed test.
# Standalone — does not touch HTTP src. Run:  julia --project=. proto_mask.jl

# XOR `n` bytes of `src` (starting src_from) with the rotating 4-byte `key into
# `dst` (starting dst_from). `key_phase` is how many payload bytes preceded this
# chunk (the decoder processes payloads in arbitrary chunk splits).
function ws_mask_into!(dst::Vector{UInt8}, dst_from::Int,
                       src::AbstractVector{UInt8}, src_from::Int,
                       n::Int, key::NTuple{4,UInt8}, key_phase::Int)
    n <= 0 && return nothing
    # Build the 8-byte broadcast of the key as it applies at `key_phase`:
    # byte i of the stream is XORed with key[(key_phase + i) % 4 + 1] (0-based i).
    k = (key[((key_phase % 4) + 0) % 4 + 1],
         key[((key_phase % 4) + 1) % 4 + 1],
         key[((key_phase % 4) + 2) % 4 + 1],
         key[((key_phase % 4) + 3) % 4 + 1])
    k64 = (UInt64(k[1])) | (UInt64(k[2]) << 8) | (UInt64(k[3]) << 16) | (UInt64(k[4]) << 24)
    k64 |= k64 << 32   # little-endian: byte j of k64 = k[(j % 4) + 1]
    i = 0
    GC.@preserve dst src begin
        pd = pointer(dst, dst_from)
        ps = pointer(src, src_from)
        # 8-byte chunks (unaligned loads/stores are fine on x86_64/aarch64)
        while i + 8 <= n
            v = unsafe_load(Ptr{UInt64}(ps + i))
            unsafe_store!(Ptr{UInt64}(pd + i), v ⊻ k64)
            i += 8
        end
        while i < n
            b = unsafe_load(ps + i)
            unsafe_store!(pd + i, b ⊻ k[(i % 4) + 1])
            i += 1
        end
    end
    return nothing
end

# reference scalar implementation (mirrors current codec semantics)
function ref_mask(src::AbstractVector{UInt8}, key::NTuple{4,UInt8}, key_phase::Int)
    out = Vector{UInt8}(undef, length(src))
    for i in 1:length(src)
        out[i] = src[i] ⊻ key[((key_phase + i - 1) % 4) + 1]
    end
    return out
end

# ── correctness fuzz: random sizes, phases, chunk splits ─────────────────────
import Random
Random.seed!(42)
for trial in 1:2000
    n = rand(0:300)
    key = (rand(UInt8), rand(UInt8), rand(UInt8), rand(UInt8))
    phase = rand(0:7)
    src = rand(UInt8, n + 16)
    src_from = rand(1:17)
    avail = n
    expected = ref_mask(view(src, src_from:src_from+avail-1), key, phase)
    dst = zeros(UInt8, avail + 8)
    dst_from = rand(1:9)
    ws_mask_into!(dst, dst_from, src, src_from, avail, key, phase)
    got = dst[dst_from:dst_from+avail-1]
    if got != expected
        error("MISMATCH trial=$trial n=$n phase=$phase src_from=$src_from dst_from=$dst_from")
    end
end
println("fuzz: 2000 trials OK (sizes 0–300, phases 0–7, arbitrary offsets)")

# in-place check (dst === src, same region) — needed for encode-in-place
let n = 1027, key = (0x12, 0x34, 0x56, 0x78)
    src = rand(UInt8, n)
    expected = ref_mask(src, key, 0)
    buf = copy(src)
    ws_mask_into!(buf, 1, buf, 1, n, key, 0)
    @assert buf == expected "in-place masking mismatch"
    println("in-place: OK")
end

# ── speed ────────────────────────────────────────────────────────────────────
for sz in (4 * 1024, 64 * 1024, 1024 * 1024)
    src = rand(UInt8, sz); dst = similar(src)
    key = (0x12, 0x34, 0x56, 0x78)
    ws_mask_into!(dst, 1, src, 1, sz, key, 0)  # compile
    n = 0; t0 = time_ns()
    while time_ns() - t0 < 0.5e9
        ws_mask_into!(dst, 1, src, 1, sz, key, 0); n += 1
    end
    gibs = n * sz / ((time_ns() - t0) / 1e9) / 1024^3
    println("mask_into! $(sz ÷ 1024)k: $(round(gibs; digits=2)) GiB/s")
end
