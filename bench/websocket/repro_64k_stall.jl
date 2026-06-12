# Minimal repro for the echo_64k stall + task-backtrace dump on hang.
using HTTP
const W = HTTP.WebSockets
const SZ = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 64 * 1024
const N = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 40
const WINDOW = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 64
const PORT = 9461

# watchdog: dump all task backtraces if we don't finish in time
done = Threads.Atomic{Bool}(false)
Threads.@spawn begin
    t0 = time()
    while !done[] && time() - t0 < 15
        sleep(0.5)
    end
    if !done[]
        println(stderr, "==== HANG: dumping task backtraces ====")
        flush(stderr)
        ccall(:jl_print_task_backtraces, Cvoid, (Cint,), 0)
        flush(stderr)
        ccall(:exit, Cvoid, (Cint,), 2)
    end
end

payload = rand(UInt8, SZ)
server = W.listen!("127.0.0.1", PORT) do ws
    for msg in ws
        W.send(ws, msg)
    end
end
W.open("ws://127.0.0.1:$PORT/") do ws
    sent = 0; received = 0; inflight = 0
    while received < N
        while inflight < WINDOW && sent < N
            W.send(ws, payload); sent += 1; inflight += 1
        end
        W.receive(ws); received += 1; inflight -= 1
        received % 10 == 0 && println("received=$received")
    end
end
done[] = true
println("COMPLETED OK: $N × $(SZ) bytes, window=$WINDOW")
close(server)
