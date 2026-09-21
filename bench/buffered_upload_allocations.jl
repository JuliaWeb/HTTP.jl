# julia --threads=4 --project=... bench/buffered_upload_allocations.jl [--check]
# The receiving server runs in a separate process so its allocations do not
# contaminate the client's counters. This is a loopback HTTP/1 and HTTP/2 check.
using HTTP

if "--server" in ARGS
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        buf = Vector{UInt8}(undef, 64 * 1024)
        count = 0
        while (n = HTTP.body_read!(request.body, buf)) > 0
            count += n
        end
        HTTP.Response(200, string(count))
    end
    println(HTTP.port(server))
    flush(stdout)
    try
        readline(stdin)
    finally
        HTTP.forceclose(server)
    end
else
    project = dirname(Base.active_project())
    cmd = `$(Base.julia_cmd()) --startup-file=no --threads=2 --project=$project $(@__FILE__) --server`
    open(cmd, "r+") do server
        port = parse(Int, readline(server))
        client = HTTP.Client()
        try
            println("Julia=", VERSION, " HTTP=", Base.pkgversion(HTTP), " path=", pathof(HTTP))
            println("protocol,payload_bytes,allocated_bytes,seconds")
            for protocol in (:h1, :h2), n in (1 << 20, 16 << 20)
                payload = fill(0x61, n)
                send() = HTTP.put("http://127.0.0.1:$port/", HTTP.Headers(), payload;
                    client, protocol, copyheaders=false, request_timeout=60)
                @assert parse(Int, String(send().body)) == n
                samples = [@timed(send()) for _ in 1:3]
                @assert all(parse(Int, String(s.value.body)) == n for s in samples)
                allocated = minimum(s.bytes for s in samples)
                println(protocol, ',', n, ',', allocated, ',', minimum(s.time for s in samples))
                flush(stdout)
                if "--check" in ARGS
                    # Allows protocol metadata and flow-control events, but rejects
                    # payload-sized staging allocations on either protocol.
                    @assert allocated < (256 << 10) + n ÷ 4
                end
            end
        finally
            close(client)
            println(server, "stop")
            flush(server)
        end
    end
end
