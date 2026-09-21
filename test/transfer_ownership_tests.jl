using Test, HTTP

const _transfer_result = Ref{Any}()
function transfer_allocations(f)
    _transfer_result[] = f()
    return minimum(@allocated(_transfer_result[] = f()) for _ in 1:5)
end

@testset "Owned transfer storage" begin
    for count in (0, 4, 16, 64)
        headers = HTTP.Headers(["X-Field-$i" => string(i) for i in 1:count])
        @test HTTP._normalize_headers_input(headers, false) === headers
        @test transfer_allocations(() -> HTTP._normalize_headers_input(headers, false)) == 0
        copied = copy(headers)
        @test copied !== headers && copied.entries !== headers.entries
        @test collect(copied) == collect(headers)
        @test all(copied[i].first === headers[i].first for i in eachindex(headers))
        @test transfer_allocations(() -> copy(headers)) <= 256 + 32count
        req = HTTP.Request("PUT", "/"; headers, copyheaders=false)
        @test req.headers === headers
        @test HTTP.Request("PUT", "/"; headers).headers !== headers
    end
    @test_throws ArgumentError HTTP.Request("GET", "/"; headers=["x" => "y"], copyheaders=false)
    @test_throws ArgumentError HTTP._normalize_headers_input(["x" => "y"], false)
    for n in (1024, 1 << 20)
        data = fill(0x61, n)
        body = HTTP.BytesBody(data)
        @test HTTP._clone_body(body).data === data
        @test transfer_allocations(() -> HTTP._clone_body(body)) < 1024
        target = fill(0xff, n + 2)
        dest = @view target[2:(n + 1)]
        @test transfer_allocations(() -> HTTP._copy_response_bytes!(dest, HTTP.BytesBody(data))) < 4096
        @test dest == data
        @test target[1] == target[end] == 0xff
        @test_throws ArgumentError HTTP._copy_response_bytes!(UInt8[], HTTP.BytesBody(data))
        @test_throws ArgumentError HTTP._copy_response_bytes!(zeros(UInt8, n - 1), HTTP.BytesBody(data))
    end
end

@testset "Header ownership and replay through HTTP/1 and HTTP/2" begin
    payload = collect(codeunits(repeat("ownership", 8192)))
    received = Channel{Any}(8)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do req
        io = IOBuffer()
        buf = Vector{UInt8}(undef, 4096)
        while (n = HTTP.body_read!(req.body, buf)) > 0
            write(io, @view buf[1:n])
        end
        data = take!(io)
        put!(received, (data, HTTP.header(req, "X-Attempt")))
        return HTTP.Response(200, data)
    end
    client = HTTP.Client()
    try
        for protocol in (:h1, :h2), owned in (false, true)
            headers = HTTP.Headers(["X-Caller" => "retained"])
            attempts = HTTP.Request[]
            trace = function(ev)
                if ev isa HTTP.RequestEvent
                    @test !HTTP.hasheader(ev.request, "X-Attempt")
                    @test ev.request.body.data === payload
                    push!(attempts, ev.request)
                    HTTP.setheader(ev.request, "X-Attempt", string(ev.attempt))
                end
            end
            output = fill(0xff, length(payload) + 2)
            response = HTTP.put("http://127.0.0.1:$(HTTP.port(server))/", headers, payload;
                client, protocol, copyheaders=!owned, trace,
                retries=1, retry_if=(attempt, _, _, resp) -> attempt == 1,
                retry_bucket=HTTP.RetryBucket(backoff_scale_factor_ms=0, max_backoff_secs=0),
                response_stream=view(output, 2:length(output)-1), request_timeout=20)
            @test response.status == 200
            @test output[2:end-1] == payload
            @test output[1] == output[end] == 0xff
            @test take!(received) == (payload, "1")
            @test take!(received) == (payload, "2")
            @test length(attempts) == 2
            @test attempts[1].headers !== attempts[2].headers
            @test !HTTP.hasheader(headers, "X-Attempt")
            owned || @test collect(headers) == ["X-Caller" => "retained"]
        end
    finally
        close(client)
        HTTP.forceclose(server)
    end
end
