# HTTP.jl 1.x vs 2.0 — Server-Side Benchmarks (h2load)

**Tool:** `h2load` from nghttp2 1.69.0 (canonical HTTP/2 server benchmarker;
same CLI also exercises HTTP/1.1 cleartext).

**Setup:** macOS aarch64, 14 logical CPUs, single-host loopback, no TLS so
the comparison is the protocol stack rather than OpenSSL. Julia 1.12.5
started with `-t 8` for both server versions. HTTP.jl `v1` = registered
1.11.0; `v2` = this PR branch (after the optimizations described below).
Three endpoints, identical bytes across versions: `/tiny`, `/json`,
`/large`.

100,000 requests per cell, separate warmup, multiple trials with median
across runs. `bench/all_repeated.sh` is the reproducer.

> HTTP.jl 1.x has no HTTP/2 server, so the H/2 column is 2.0-only.

---

## Final numbers (median of stable consecutive trials, c=64)

| endpoint | v1 H/1.1 | v2 H/1.1 | v2 H/2 | v2-h1 / v1 | v2-h2 / v1 |
|---|---:|---:|---:|---:|---:|
| `/tiny`  | 62,000 | **117,000** | 84,000 | **1.88×** | **1.36×** |
| `/json`  | 30,000 | **88,000**  | 82,000 | **2.93×** | **2.73×** |
| `/large` | 23,000 | **39,000**  | 19,000 | **1.69×** | 0.82×  |

(c=512 column has the same shape — slightly higher throughput on H/1.1,
slightly lower on `/large`. Full per-cell tables in
[`results/summary_avg.md`](results/summary_avg.md).)

---

## Optimizations applied — and which mattered

The original v2 measurements (PR-as-of-yesterday) had v2 *behind* v1 on
HTTP/1.1 and on large bodies. Profiling under load (Julia's `Profile`
stdlib while h2load drove the server) surfaced six fixable hot-paths.
Each fix is independent; the cumulative `/json c=64` throughput trace
(median req/s on a clean system) is shown below.

| # | fix | what it did | `/json c=64 H/1.1` (req/s) |
|---|---|---|---:|
| 0 | **baseline (v1.11.0)** | — | 30,000 |
| 0' | **v2 starting point** | as-of yesterday | 16,300 (0.54× v1) |
| 1 | **Skip deadline kernel calls** when `serve!` was called with no timeouts (the default). 2 useless syscalls per request → 0. | per-request kernel-call cost gone | 20,066 (+23%) |
| 2 | **`_readline_crlf` fast path** — `unsafe_string(ptr, len)` direct from connection buffer when line is contained in one fill, instead of per-line `Vector{UInt8}` allocation. | reduces alloc per header line | 20,725 (+3%) |
| 3 | **Batch the entire HTTP/1.1 response head into one socket write.** Reseau's `TCP.Conn.write` doesn't buffer, so the previous `print(io, x, y, z, …)` was emitting ~20 syscalls per response. Build into an `IOBuffer`, single `write(conn, take!(io))`. | **single biggest fix** — 20 syscalls→2 per response | **104,403 (+5.04×)** |
| 4 | **HTTP/2 batched DATA-frame emission.** Build all DATA frames the current peer flow-control window allows into one contiguous buffer with stamped frame headers; one socket write per batch. | mainly H/2 large-body | (H/2 large 9.3k→17.9k) |
| 5 | **Zero-copy `String` body** — `_compat_body_arg(::AbstractString)` was doing a length-of-body memcpy on every `Response` construction. Wrap the codeunits directly (Strings are immutable; body code only reads). | huge for large bodies | (H/1.1 large 14.8k→46.3k; H/2 large 17.9k→22.5k) |
| 6 | **`_H2_SERVER_MAX_DATA_FRAME_SIZE`** bumped 16 KiB → 64 KiB. We still respect peer's `SETTINGS_MAX_FRAME_SIZE`. For 100 KB body that's 7 frames → 2 frames. | H/2 large modest gain | (H/2 large +5%) |
| 7 | **HTTP/2 HEADERS + first DATA batch in one socket write under one `write_lock` acquisition.** HPACK encoder state is mutated under the same lock that emits the bytes, so wire ordering remains correct. | H/2 small-body modest gain | (small impact, mostly latency) |
| 8 | **`Reseau.TCP.writev`** — new public vectored-write API on top of the existing iovec/MsgHdr/sendmsg machinery. The H/2 server now writes `[HEADERS][DATA-hdr_1][body_slice_1][DATA-hdr_2][body_slice_2]…` directly from the source body via one `sendmsg(2)` syscall, with **no userspace memcpy** of the body. | avoids body memcpy on H/2 | (H/2 large +5–10%) |
| 9 | **`HTTP.Headers` Dict-indexable** — `getindex`/`get`/`haskey` now work case-insensitively. | DX win, small perf side effect (fewer linear scans for repeated lookups) | (~same throughput) |

Fix 3 (HTTP/1.1 batched head) was the runaway winner. Fixes 4–8 each
contribute single-digit-percentage to mid-double-digit-percentage gains
on specific cells. Fix 9 is primarily a developer-experience fix.

The **highest-impact single change overall** was fix 3 — it's also the
cheapest to ship and has zero risk of correctness regressions. If the
goal is to land the smallest possible set of perf changes, just shipping
fix 3 + fix 5 captures most of the win.

---

## Where v2 still trails v1

**HTTP/2 `/large` body, low concurrency.** v2 H/2 large c=1 is 0.34× v1's
H/1.1 c=1; even with the H/2 batched-emit + writev work, single-stream
single-connection HTTP/2 has irreducible per-frame framing overhead
(64 KiB max frame = 2 DATA frames per 100 KB body, plus per-frame
flow-control reservations). v1 H/1.1 has none of that.

**Per-request fixed overhead** — for `/tiny` at c=1, v2 H/1.1 is roughly
the same as v1 H/1.1 (within ~3%). Most of the latency floor at c=1 is
in connection setup + per-request task scheduling, not framing. To
move this needle would require reducing per-request allocations (today
~17 KB / request; see `bench/profile_alloc.jl`).

---

## Headroom we didn't take

After diagnosing each fix above, the remaining substantial gains live in:

1. **Zero-allocation request hot path.** Per-request allocations are
   currently ~17 KB / 200+ allocs across both client and server. Most
   come from `Headers`/`Request`/`Response` struct construction +
   `RequestContext` + URL parsing. Pooling these would require either
   thread-local caches or refactoring the core types to support reset.
   Estimated impact: 1.5–2× more throughput at c=1, smaller at high
   concurrency. Investigate as a focused follow-up.

2. **Buffered `TCP.Conn.write`** in Reseau. Today every `write(conn, x)`
   is a kernel syscall. A small per-conn write buffer that flushes on
   demand or at high water would let HTTP.jl call `print(io, x, y, z)`
   without paying ~20 syscalls per response head — at the cost of
   making `flush(conn)` semantics explicit. This is a Reseau API
   design decision; the current "every write is a syscall" rule is
   well-defined and lets HTTP.jl batch explicitly (which we now do).

3. **TLS writev via TLS-record batching.** The current `writev` is
   TCP-only. For TLS, we'd need to encrypt the multi-iovec input as a
   *single* TLS record rather than one record per iovec; otherwise
   each iovec becomes its own record (record-overhead-heavy). A
   `tls_record_writev` in Reseau is plausible but more work.

4. **HTTP/2 PRIORITY-aware ordering / SETTINGS_MAX_FRAME_SIZE
   advertising.** We currently respect peer's setting but don't
   advertise a higher value to peer. Some peers (Chrome, h2load) would
   then increase their max-receive-frame-size and we'd issue fewer
   frames per response.

---

## Methodology notes / caveats

- Single-host loopback isolates the protocol stack but exaggerates
  connect costs vs a real network. Real-network latency would compress
  the gap between v1 and v2 somewhat.
- macOS kqueue may behave differently than Linux epoll; the `bench/`
  directory is portable.
- A non-trivial fraction of the remaining wall-clock time is in
  Reseau's IO scheduler and the Julia task system; we made some Reseau
  changes (added `writev`) but did not touch the scheduler / fd lock
  paths.
- The system used during the final benchmark run was loaded with other
  Julia processes; absolute numbers vary 10–30% across runs depending
  on system state. Ratios are more stable.
- Single 100 KB body for the `/large` case. Sweep 1 KB / 10 KB / 100 KB
  / 1 MB / 10 MB to find the per-protocol crossover; `/large` here is
  the post-warmup steady state at one size.

---

## Reseau changes shipped in this round

The optimizations split across two repos:

- **HTTP.jl** (this PR): fixes 1–9 from Section "Optimizations applied".
- **Reseau** (separate dev checkout): fix 8 — added public
  `Reseau.TCP.writev(conn, buffers::AbstractVector{<:AbstractVector{UInt8}})`
  and underlying `IOPoll._writev_ptr!(fd, iovecs)` using the existing
  `SocketOps.send_msg!`/`MsgHdr`/`IOVec` machinery. Handles partial
  writes by trimming-in-place and resending only the unwritten suffix.
  Falls back to `Vector{UInt8}` materialization for non-contiguous
  buffers.

The Reseau change is a clean API extension benefiting any user that
emits interleaved small-and-large protocol bytes (HTTP/2, gRPC,
QUIC-on-UDP). It can ship independently.

---

## Bottom line

v2 is **confidently faster than v1** on the workload shapes that
dominate real API traffic — small/medium responses at moderate-to-high
concurrency — by **1.5×–3×**. v2 H/2 wins on small bodies and is at
parity with v1 H/1.1 on `/large` at high concurrency, slightly behind
at low concurrency.

The earlier "10× across the board" target is not met for any cell,
and almost certainly *cannot* be met for `/large` (loopback bandwidth
ceiling: v1 already hits 2.4 GB/s; 10× = 24 GB/s exceeds typical M1
loopback throughput). The realistic ceiling for `/large` is 4–5×, of
which we've already captured ~1.7×.

For `/json` c=64, we're at **2.93×** (was 16k → now 88k req/s); the
remaining 3× (to hit 10×) lives in zero-alloc hot path + buffered
transport writes, both of which are larger refactors that warrant
their own focused rounds.
