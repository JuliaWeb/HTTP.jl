# Buffered HTTP/1 stream response benchmark. Run the same script on both revisions:
#   julia --project=. --threads=1,8 bench/fixed_response_writes.jl 8080 2
#   h2load --h1 -t4 -c1024 -D15 --warm-up-time=8 http://127.0.0.1:8080/
# Repeat with body sizes 0, 512, 4096, 4097, and 131072; alternate revisions.
# The body is prepared once so the benchmark isolates request/response overhead.
using HTTP

port = parse(Int, ARGS[1])
body = fill(UInt8('x'), parse(Int, get(ARGS, 2, "2")))
content_length = string(length(body))
server = HTTP.listen!("127.0.0.1", port; backlog = 4096) do stream
    HTTP.setheader(stream, "Content-Type", "application/octet-stream")
    HTTP.setheader(stream, "Content-Length", content_length)
    write(stream, body)
end
println("READY ", HTTP.port(server), " Julia ", VERSION, " HTTP ", pkgversion(HTTP))
flush(stdout)
wait(server)
