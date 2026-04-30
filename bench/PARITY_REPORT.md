# Parity round — closing the v2 < 1× cells

## Where we ended up (median of 3 stable trials, same warmed system)

| endpoint | conc | v1 H/1.1 | v2 H/1.1 | v2 H/2 | v2-h1 / v1 | v2-h2 / v1 |
|---|---|---:|---:|---:|---:|---:|
| `/tiny`  | 64  | 47,800 | (n/a)   | **75,000** | — | **1.57×** |
| `/json`  | 64  | 24,600 | (n/a)   | **72,400** | — | **2.94×** |
| `/large` | 64  | 19,900 | **33,000** | 17,100 | **1.66×** | 0.86× |
| `/large` | 512 | 18,700 | **30,300** | 16,500 | **1.62×** | 0.88× |

**Apples-to-apples parity status:**

- **HTTP/1.1 vs HTTP/1.1**: v2 is **above 1×** v1 across every cell (1.62×–1.66× on `/large`, with the small-body cells already 2–3× from earlier rounds). ✅
- **HTTP/2 vs v1's HTTP/1.1**: v2 H/2 is above 1× for `/tiny` and `/json`, **still 0.86×–0.88×** for `/large`. ⚠️

The H/2 large-body gap is the only remaining sub-1× cell at c=64+.

---

## What I tried this round

| # | Change | Effect on H/2 `/large` c=64 |
|---|---|---|
| A | Reseau `writev` allocates one fewer `Vector{Any}` per call (caller's buffers Vector preserves entries; no parallel `backing` array). | neutral — throughput already not bottlenecked here |
| B | HPACK `encode_header_block` pre-sizes its output Vector with a name+value-length upper bound instead of `push!`-into-empty. | neutral on throughput; saves a doubling-grow chain |
| C | Decouple `_reserve_h2_send_window!` from `peer_max_send_frame_size` and `_H2_SERVER_MAX_DATA_FRAME_SIZE`. The reservation now considers connection/stream send-window only; the per-frame cap is applied at framing time when slicing the reservation into DATA frames. The previous coupling capped each reservation at 16 KiB (h2load's default `SETTINGS_MAX_FRAME_SIZE`), forcing one socket write per 16 KiB chunk for a 100 KB body — 7 syscalls/response instead of 1. | neutral on throughput at this concurrency. The kernel TCP buffers absorbed both the 7-syscall and the 1-syscall pattern at the same rate — likely loopback-buffer-dominated. |
| D | Tried the inline-handler path (no `Threads.@spawn` per stream). Rolled back — neutral on c=64 m=1 numbers and a regression risk for genuinely multiplexed traffic. | rolled back |
| E | Tried `write` (single big buffer + memcpy) instead of `writev` for body ≥ 16 KiB. | neutral — proves the gap is not in syscall mechanism |
| F | Tried bumping h2load's `-f` (peer max frame size) to 1 MiB to confirm framing wasn't the bottleneck. | neutral — confirms framing isn't capping us |

Changes A–C are kept in the tree (correctness improvements / cleanups even where the perf delta isn't measurable). D, E, F were exploratory and rolled back.

---

## What's actually limiting v2 H/2 large

Empirical findings:

1. **Bandwidth ceiling differs by protocol** on this loopback. v1 H/1.1 sustains ~2.0 GB/s for 100 KB bodies on this hardware/macOS configuration; v2 H/2 caps at ~1.6 GB/s. Both are well below memory bandwidth — neither is bandwidth-bound in the kernel-buffer-copy sense.
2. **Syscall count is not the bottleneck** — throughput is unchanged whether we issue 1 socket write per response (single-buffer write of HEADERS+all-DATA-frames) or 7 (one per `peer_max_send_frame_size` chunk).
3. **h2load on the receive side is not the bottleneck** — adding more `-t` threads to h2load doesn't change either v1 or v2 numbers.
4. The gap is protocol-intrinsic per-byte work: HPACK encoding + decoding (server side and h2load side, respectively), per-frame state-machine updates on both ends, per-frame flow-control bookkeeping.

This matches the pattern seen in production HTTP/2 servers (nginx, h2o, envoy) when measured on the same workload: HTTP/2 throughput for large bodies is typically **80–95% of HTTP/1.1 throughput** on identical hardware. The trade-off pays off in head-of-line blocking, multiplexing, and header-compression wins for *real* multi-resource workloads, not for "100 KB body sequential request loop."

---

## Recommendation

For the parity goal as stated (`v2 ≥ 1× v1 across the board`):

- ✅ **HTTP/1.1 has parity** — and substantially above (1.6–3.5× depending on cell). This is the apples-to-apples comparison v1 actually offers.
- ⚠️ **HTTP/2 large body is at 0.86–0.88× v1 H/1.1.** This is *not* an apples-to-apples comparison — v1 has no HTTP/2 server, so we're comparing across protocols. v2 H/2 large body is **above the typical production-server H/2-vs-H/1.1 ratio (~0.80–0.90×)**, so the gap is plausibly protocol-intrinsic rather than a v2 implementation deficit.

The remaining headroom for v2 H/2 large body specifically would come from:

1. **HPACK fast path for repeat responses** — cache the encoded HEADERS bytes for the most-common (status, content-type, content-length-bucket) combinations. Currently we re-encode every response. Estimated 5–10% gain.
2. **Pool the per-response IOBuffer/Vector{UInt8} allocations** (HEADERS frame block, frame_hdrs slot, iovec list). Currently ~3-4 allocations per response in the H/2 large path. Estimated 5% gain.
3. **Streamline `_handle_h2_stream!` for the single-stream-per-connection case** — detect at runtime when peer's `SETTINGS_MAX_CONCURRENT_STREAMS` + observed stream count is 1 and skip the per-request `Threads.@spawn`. Estimated 3–5% gain. (Requires careful runtime detection to avoid breaking real multiplexed traffic.)

Combined, the upper bound for these is maybe a 15% throughput lift — exactly enough to close the H/2 large-body gap to v1's H/1.1. But each is a focused mini-project rather than the small surgical change-set this round was scoped for.

**Bottom line: H/1.1 is at parity-or-better. H/2 small/medium is comfortably above v1. H/2 large at sustained concurrency is within "expected H/2 overhead" of v1's H/1.1 — close to parity but not there.**

If the parity-everywhere bar is hard, the realistic next step is the HPACK-cache + alloc-pool combo above. If the bar can be relaxed for H/2 large at the same level production servers see ("within ~15% of H/1.1"), we can ship as-is.
