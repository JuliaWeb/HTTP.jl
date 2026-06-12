# CPU + allocation profiling of the WS hot paths (2.x only).
#   julia -t 4 --project=. bench/websocket/profile_ws.jl [mode] [msg_bytes] [n]
# mode: echo | send | push   (default echo)
using HTTP
using HTTP.WebSockets
using Profile

const W = HTTP.WebSockets
const MODE = length(ARGS) >= 1 ? ARGS[1] : "echo"
const MSG_BYTES = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 16
const N = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 50_000
const PORT = parse(Int, get(ENV, "WSBENCH_PORT", "9381"))

payload = rand(UInt8, MSG_BYTES)

function run_workload(ws, n)
    if MODE == "echo"
        for _ in 1:n
            W.send(ws, payload)
            W.receive(ws)
        end
    elseif MODE == "send"
        for _ in 1:n
            W.send(ws, payload)
        end
        W.send(ws, "__END__")
        W.receive(ws)
    elseif MODE == "push"
        got = 0
        while got < n
            msg = W.receive(ws)
            got += 1
        end
    end
end

server = W.listen!("127.0.0.1", PORT) do ws
    if MODE == "push"
        for _ in 1:(N + N ÷ 10 + 10)
            W.send(ws, payload)
        end
        W.receive(ws)
    else
        count = 0
        for msg in ws
            if msg isa String && msg == "__END__"
                W.send(ws, "done")
            elseif MODE == "echo"
                W.send(ws, msg)
            end
        end
    end
end

W.open("ws://127.0.0.1:$PORT/") do ws
    run_workload(ws, max(200, N ÷ 10))   # warmup/compile
    println("=== CPU profile ($MODE, $(MSG_BYTES)B × $N) ===")
    Profile.clear()
    @profile run_workload(ws, N)
    Profile.print(IOContext(stdout, :displaysize => (60, 200)); format=:flat, sortedby=:count, mincount=30, combine=true)
    println()
    println("=== Allocation profile (sample_rate=0.05) ===")
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=0.05 run_workload(ws, min(N, 20_000))
    results = Profile.Allocs.fetch()
    # aggregate by (type, top frame inside HTTP/Reseau)
    agg = Dict{String,Tuple{Int,Int}}()  # key => (count, bytes)
    for a in results.allocs
        frame = "?"
        for f in a.stacktrace
            file = String(f.file)
            if occursin("http_websocket", file) || occursin("/src/http_", file) || occursin("Reseau", file)
                frame = "$(f.func) @ $(basename(file)):$(f.line)"
                break
            end
        end
        key = "$(a.type) | $frame"
        c, b = get(agg, key, (0, 0))
        agg[key] = (c + 1, b + a.size)
    end
    rows = sort(collect(agg); by=x -> -x[2][2])
    println(rpad("count", 9), lpad("MB", 9), "  type | allocating frame")
    for (k, (c, b)) in rows[1:min(end, 28)]
        println(rpad(c, 9), lpad(round(b / 1024^2; digits=2), 9), "  ", k)
    end
    MODE == "push" || W.send(ws, "__END2__")
end
close(server)
