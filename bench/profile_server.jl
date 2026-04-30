# Like server.jl but starts a background Profile sampling task,
# accepts a benchmark-driven shutdown, and writes profile output to a file.
#
# Usage: julia --project=. profile_server.jl <port> <profile_out_path> <profile_seconds>
using HTTP
using Profile

const SMALL_JSON = """{"id":1,"name":"alice","email":"alice@example.com","tags":["admin","reviewer"],"created_at":"2024-01-01T12:00:00Z","status":"active","login_count":42}"""
const LARGE_BODY = repeat("x", 100 * 1024)

const TINY_HEADERS = ["Content-Length" => "0"]
const JSON_HEADERS = ["Content-Type" => "application/json", "Content-Length" => string(length(SMALL_JSON))]
const LARGE_HEADERS = ["Content-Type" => "application/octet-stream", "Content-Length" => string(length(LARGE_BODY))]

function handler(req::HTTP.Request)
    t = req.target
    if t == "/tiny"; return HTTP.Response(200, TINY_HEADERS); end
    if t == "/json"; return HTTP.Response(200, JSON_HEADERS; body=SMALL_JSON); end
    if t == "/large"; return HTTP.Response(200, LARGE_HEADERS; body=LARGE_BODY); end
    return HTTP.Response(404)
end

port = parse(Int, ARGS[1])
prof_path = ARGS[2]
prof_secs = parse(Float64, ARGS[3])

# Pre-allocate a generous profile buffer
Profile.init(n=10_000_000, delay=0.0001)

server = HTTP.serve!(handler, "127.0.0.1", port)
println("READY $(HTTP.port(server))")
flush(stdout)

# Wait briefly so h2load can start hitting endpoints, then sample.
# h2load runner kicks off load before this script's profile window starts.
# Use a wait-for-load token via a sentinel file.
sentinel = prof_path * ".begin"
println("WAITING_FOR_BEGIN $sentinel")
flush(stdout)
while !isfile(sentinel)
    sleep(0.05)
end
println("PROFILING $(prof_secs)s")
flush(stdout)
Profile.clear()
Profile.@profile begin
    sleep(prof_secs)
end
println("PROFILE_DONE")
flush(stdout)

# Write Profile.print output to file
open(prof_path, "w") do io
    Profile.print(io; format=:flat, sortedby=:count, mincount=20)
    println(io, "\n\n=== TREE FORMAT (top frames) ===\n")
    Profile.print(io; format=:tree, mincount=50, maxdepth=20)
end
println("WROTE $prof_path")
flush(stdout)
HTTP.forceclose(server)
