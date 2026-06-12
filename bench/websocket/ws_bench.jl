# WebSocket benchmark suite — runs identically under HTTP.jl 1.x and 2.x.
#
#   julia -t 4 --project=<env> bench/websocket/ws_bench.jl [scale]
#
# `scale` (default 1.0) multiplies message counts (0.05 for smoke tests).
# Emits one parseable line per scenario:
#   RESULT name=... msgs=... msg_bytes=... secs=... msgs_s=... mb_s=... \
#          allocs_per_msg=... kb_per_msg=... gc_pct=...
# Allocation numbers are whole-process (client+server side combined), which is
# what a same-process comparison across versions can measure honestly.

using HTTP
using HTTP.WebSockets
using Statistics

const W = HTTP.WebSockets
const PORT_BASE = parse(Int, get(ENV, "WSBENCH_PORT", "9143"))
const SCALE = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 1.0
const END_SENTINEL = "__WSBENCH_END__"

nmsgs(n) = max(8, round(Int, n * SCALE))

struct BenchResult
    name::String
    msgs::Int
    msg_bytes::Int
    secs::Float64
    allocs_per_msg::Float64
    kb_per_msg::Float64
    gc_pct::Float64
end

function report(r::BenchResult)
    progress!()
    msgs_s = r.msgs / r.secs
    mb_s = (r.msgs * r.msg_bytes) / r.secs / 1024^2
    println("RESULT name=$(r.name) msgs=$(r.msgs) msg_bytes=$(r.msg_bytes) secs=$(round(r.secs; digits=3)) " *
            "msgs_s=$(round(msgs_s; digits=1)) mb_s=$(round(mb_s; digits=1)) " *
            "allocs_per_msg=$(round(r.allocs_per_msg; digits=2)) kb_per_msg=$(round(r.kb_per_msg; digits=2)) " *
            "gc_pct=$(round(r.gc_pct; digits=1))")
    flush(stdout)
end

# Measure f() returning (secs, allocs, bytes, gc_pct)
function measured(f)
    GC.gc()
    before = Base.gc_num()
    t0 = time_ns()
    f()
    secs = (time_ns() - t0) / 1e9
    diff = Base.GC_Diff(Base.gc_num(), before)
    return secs, Base.gc_alloc_count(diff), diff.allocd, (diff.total_time / 1e9) / secs * 100
end

# ── one-way client→server flood; server consumes and acks the sentinel ──────
function bench_send(name::String, payload::Vector{UInt8}, n::Int, port::Int)
    server = W.listen!("127.0.0.1", port) do ws
        count = 0
        for msg in ws
            if msg isa String && msg == END_SENTINEL
                W.send(ws, "done")
                break
            end
            count += 1
        end
    end
    result = Ref{BenchResult}()
    try
        W.open("ws://127.0.0.1:$port/") do ws
            # warmup
            for _ in 1:max(4, n ÷ 20)
                W.send(ws, payload)
            end
            secs, allocs, bytes, gc_pct = measured() do
                for _ in 1:n
                    W.send(ws, payload)
                end
                W.send(ws, END_SENTINEL)
                W.receive(ws)  # "done" — server has consumed everything
            end
            result[] = BenchResult(name, n, length(payload), secs, allocs / n, bytes / n / 1024, gc_pct)
        end
    finally
        close(server)
    end
    report(result[])
end

# ── server→client flood; client consumes ────────────────────────────────────
function bench_push(name::String, payload::Vector{UInt8}, n::Int, port::Int)
    total = n + max(4, n ÷ 20)
    server = W.listen!("127.0.0.1", port) do ws
        for _ in 1:total
            W.send(ws, payload)
        end
        W.send(ws, END_SENTINEL)
        W.receive(ws)  # hold until client acks so close doesn't race the drain
    end
    result = Ref{BenchResult}()
    try
        W.open("ws://127.0.0.1:$port/") do ws
            for _ in 1:max(4, n ÷ 20)  # warmup portion
                W.receive(ws)
            end
            secs, allocs, bytes, gc_pct = measured() do
                got = 0
                while true
                    msg = W.receive(ws)
                    msg isa String && msg == END_SENTINEL && break
                    got += 1
                end
                got == n || error("push undercount: $got != $n")
            end
            W.send(ws, "done")
            result[] = BenchResult(name, n, length(payload), secs, allocs / n, bytes / n / 1024, gc_pct)
        end
    finally
        close(server)
    end
    report(result[])
end

# ── pipelined echo: keep `window` messages in flight ─────────────────────────
function bench_echo(name::String, payload, n::Int, port::Int;
                    # cap in-flight BYTES (not messages): realistic pipelining and
                    # avoids loopback-buffer deadlock pressure at large payloads
                    window::Int=clamp(262_144 ÷ max(1, sizeof(payload)), 1, 64))
    server = W.listen!("127.0.0.1", port) do ws
        for msg in ws
            W.send(ws, msg)
        end
    end
    result = Ref{BenchResult}()
    try
        W.open("ws://127.0.0.1:$port/") do ws
            for _ in 1:max(4, n ÷ 20)  # warmup round-trips
                W.send(ws, payload); W.receive(ws)
            end
            secs, allocs, bytes, gc_pct = measured() do
                inflight = 0
                sent = 0
                received = 0
                while received < n
                    while inflight < window && sent < n
                        W.send(ws, payload); sent += 1; inflight += 1
                    end
                    W.receive(ws); received += 1; inflight -= 1
                end
            end
            result[] = BenchResult(name, n, sizeof(payload), secs, allocs / n, bytes / n / 1024, gc_pct)
        end
    finally
        close(server)
    end
    report(result[])
end

# ── strict ping-pong latency ─────────────────────────────────────────────────
function bench_latency(name::String, payload::Vector{UInt8}, n::Int, port::Int)
    server = W.listen!("127.0.0.1", port) do ws
        for msg in ws
            W.send(ws, msg)
        end
    end
    try
        W.open("ws://127.0.0.1:$port/") do ws
            for _ in 1:max(4, n ÷ 20)
                W.send(ws, payload); W.receive(ws)
            end
            times = Vector{Float64}(undef, n)
            for i in 1:n
                t0 = time_ns()
                W.send(ws, payload)
                W.receive(ws)
                times[i] = (time_ns() - t0) / 1e3  # µs
            end
            sort!(times)
            p50 = times[max(1, round(Int, 0.50 * n))]
            p90 = times[max(1, round(Int, 0.90 * n))]
            p99 = times[max(1, round(Int, 0.99 * n))]
            println("RESULT name=$name msgs=$n msg_bytes=$(length(payload)) " *
                    "p50_us=$(round(p50; digits=1)) p90_us=$(round(p90; digits=1)) p99_us=$(round(p99; digits=1)) " *
                    "rt_msgs_s=$(round(1e6 / p50; digits=1))")
            flush(stdout)
        end
    finally
        close(server)
    end
end

# Optional hang watchdog: WSBENCH_WATCHDOG_S>0 dumps task backtraces and exits
# if a single scenario makes no progress for that many seconds.
const _LAST_PROGRESS = Threads.Atomic{Float64}(time())
progress!() = (_LAST_PROGRESS[] = time(); nothing)
function _arm_watchdog!()
    budget = parse(Float64, get(ENV, "WSBENCH_WATCHDOG_S", "0"))
    budget <= 0 && return
    Threads.@spawn begin
        while true
            sleep(1.0)
            if time() - _LAST_PROGRESS[] > budget
                println(stderr, "==== WSBENCH HANG (no progress for $(budget)s): task backtraces ====")
                flush(stderr); flush(stdout)
                ccall(:jl_print_task_backtraces, Cvoid, (Cint,), 0)
                flush(stderr)
                ccall(:exit, Cvoid, (Cint,), 2)
            end
        end
    end
    return
end

function main()
    println("# WSBENCH julia=$(VERSION) http=$(pkgversion(HTTP)) threads=$(Threads.nthreads()) scale=$SCALE")
    _arm_watchdog!()
    payload16 = rand(UInt8, 16)
    payload4k = rand(UInt8, 4 * 1024)
    payload1m = rand(UInt8, 1024 * 1024)
    text16 = String(rand('a':'z', 16))

    bench_send("send_16b",  payload16, nmsgs(100_000), PORT_BASE + 1)
    bench_send("send_4k",   payload4k, nmsgs(25_000),  PORT_BASE + 2)
    bench_send("send_1m",   payload1m, nmsgs(300),     PORT_BASE + 3)
    bench_push("push_16b",  payload16, nmsgs(100_000), PORT_BASE + 4)
    bench_push("push_4k",   payload4k, nmsgs(25_000),  PORT_BASE + 5)
    bench_echo("echo_16b",  payload16, nmsgs(50_000),  PORT_BASE + 6)
    bench_echo("echo_text16", text16,  nmsgs(50_000),  PORT_BASE + 7)
    bench_echo("echo_64k",  rand(UInt8, 64 * 1024), nmsgs(2_000), PORT_BASE + 8)
    bench_latency("latency_16b", payload16, nmsgs(5_000), PORT_BASE + 9)
end

main()
