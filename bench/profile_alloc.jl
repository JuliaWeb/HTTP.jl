# Allocation profiling: drives a small steady stream of requests against
# the server then dumps Profile.Allocs report.
using HTTP, Profile

const SMALL_JSON = """{"id":1,"name":"alice","email":"alice@example.com","tags":["admin","reviewer"],"created_at":"2024-01-01T12:00:00Z","status":"active","login_count":42}"""
const TINY_HEADERS = ["Content-Length" => "0"]
const JSON_HEADERS = ["Content-Type" => "application/json", "Content-Length" => string(length(SMALL_JSON))]

function handler(req::HTTP.Request)
    t = req.target
    if t == "/tiny"; return HTTP.Response(200, TINY_HEADERS); end
    if t == "/json"; return HTTP.Response(200, JSON_HEADERS; body=SMALL_JSON); end
    return HTTP.Response(404)
end

server = HTTP.serve!(handler, "127.0.0.1", 19921)

# Warm up
client = HTTP.Client()
for _ in 1:100
    HTTP.get("http://127.0.0.1:19921/json"; client=client)
end
println("warmup done")

# Profile allocations on a single request
Profile.Allocs.clear()
Profile.Allocs.@profile sample_rate=1.0 begin
    for _ in 1:100
        HTTP.get("http://127.0.0.1:19921/json"; client=client)
    end
end
results = Profile.Allocs.fetch()
allocs = results.allocs
total_size = sum(a -> a.size, allocs; init=0)
println("Total allocs: $(length(allocs)), total bytes: $total_size")
println("Bytes per request: $(total_size / 100)")
println("Allocs per request: $(length(allocs) / 100)")

# Aggregate by stack frame
by_frame = Dict{String, Tuple{Int,Int}}()
for a in allocs
    if !isempty(a.stacktrace)
        frame = a.stacktrace[1]
        key = "$(frame.file):$(frame.line) $(frame.func)"
        cnt, bytes = get(by_frame, key, (0,0))
        by_frame[key] = (cnt+1, bytes+a.size)
    end
end
sorted = sort(collect(by_frame), by=x -> -x[2][2])
println("\nTop allocs by total bytes:")
for (frame, (cnt, bytes)) in first(sorted, 25)
    println("  $cnt allocs / $bytes bytes — $frame")
end

close(client)
HTTP.forceclose(server)
