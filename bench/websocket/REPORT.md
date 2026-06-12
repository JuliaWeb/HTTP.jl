# WebSocket performance: 1.x vs 2.x — analysis and fixes

**Trigger:** report that 2.x WebSockets are slow vs 1.x / uWebSockets, with
large-binary-message workloads (Bonito/WGLMakie-style) most affected.

**Setup:** macOS aarch64 (14 cores), Julia 1.12.5 `-t 4`, loopback, no TLS.
v1 = HTTP 1.11.0 (latest 1.x); v2 = this branch + Reseau main (`9e3ff7d`).
`ws_bench.jl`, medians of 3 trials; allocations are whole-process
(client+server) per message. Reproduce: `./run_baseline.sh 3 1.0` then
`julia compare.jl results`.

## Baseline (before this branch)

2.x already beat 1.x by 4–8× on small/medium messages, but **lost on large
ones** — exactly the reported regime:

| cell | v1 | v2 before | ratio |
|---|---:|---:|---:|
| send_1m | 1002 MB/s | 433 MB/s | **0.43×** |
| echo_64k | 515 MB/s | 313 MB/s | **0.61×** (GC 51%) |

Component microbenchmarks (`codec_micro.jl`) pinned it: masked decode ran at
**0.53 GiB/s** (`push!`-per-byte with a per-byte modulo — the server's receive
path for all client traffic), masked encode at 1.35 GiB/s, and every sent byte
was copied twice (payload → per-frame buffer → concatenated flush buffer).

## Fixes

**Round 1 (codec inner loops):**
- `_ws_mask_into!`: masking XORs 8 bytes/iteration with the 4-byte key
  broadcast into a `UInt64` (phase-aware for chunked delivery, in-place
  capable; fuzz-validated). Masked decode 0.53 → **7.1 GiB/s**, masked encode
  1.35 → 6.7 GiB/s.
- Decoder payload assembly: explicit `payload_received` cursor; exact-size
  presize for frames ≤ 4 MiB (capped so a forged length header cannot
  allocate unbounded memory); frame payload **ownership handoff** instead of a
  copy per frame.
- Client masking key from `rand(UInt32)` (no 4-byte Vector per send).

**Round 2 (buffer architecture):**
- Outgoing frames encode **directly into a persistent buffer**
  (`_ws_append_frame!`); flushing swaps buffers instead of concatenating.
  Steady-state sends allocate nothing in the codec. The buffer is guarded by a
  leaf lock never held across socket I/O — which also fixes a latent race
  where the read task queued PONG/CLOSE replies unsynchronized with senders.
- Reused decoder `frames_scratch`; extended-length/masking-key caches filled
  without view allocations; `(buf, n)` chunk API so the read loop passes no
  per-read view; hoisted per-connection frame callback; callable-struct header
  guard instead of a boxed-capture closure.

## After

| scenario | metric | v1 (1.11) | v2 (this branch) | v2/v1 |
|---|---|---:|---:|---:|
| send_1m  | MB/s | 1002 | **2541** | **2.54** |
| echo_64k | MB/s | 515 | **888** | **1.72** |
| send_4k  | MB/s | 129 | 862 | 6.7 |
| push_4k  | MB/s | 139 | 1157 | 8.4 |
| send_16b | msgs/s | 39k | 277k | 7.1 |
| push_16b | msgs/s | 41k | 340k | 8.2 |
| echo_16b | msgs/s | 31k | 200k | 6.5 |
| latency_16b | p50 / p99 µs | 77 / 142 | 56 / 89 | 0.73 / 0.63 |

Allocation floor reached: `send_1m` allocates **1029.5 KB/msg ≈ the 1 MiB
user-owned payload + ~5 KB** — the deliverable itself is the only remaining
per-message byte cost (`receive` hands ownership to the caller, so one
exact-size allocation per message is the API floor). `ws_decoder_process!` on
empty input allocates 0 bytes.

## Correctness gates

Codec 88/88, WS client 20/20, server 35/35, integration 42/42, and the
**Autobahn fuzzing suite: 463 cases, zero failures** (233 OK, 11 NON-STRICT,
3 INFORMATIONAL; the 216 UNIMPLEMENTED are all case 12/13.* permessage-deflate,
an extension we do not implement). Run before and after the codec rewrite with
identical verdicts.

## Notes / future work

- A bench-suite stall was observed pre-fix at `echo_64k` with >2 MB of
  unacked in-flight data on **both** 1.x and 2.x (intermittent, loopback
  buffer pressure); the suite caps in-flight bytes at 256 KiB and arms a
  task-backtrace watchdog (`WSBENCH_WATCHDOG_S`) to capture it if it recurs.
- Cross-implementation reference (gorilla/uWebSockets) deferred: no local
  toolchain. The suite is version-agnostic, so adding an external echo server
  is straightforward.
- Possible round 3: `writev` (header + payload iovec) to drop the one
  remaining send-side payload copy for very large frames; permessage-deflate.
