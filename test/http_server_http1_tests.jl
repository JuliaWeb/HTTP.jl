using Test
using HTTP
using Reseau
using Dates

const HT = HTTP
const NC = Reseau.TCP
const ND = Reseau.HostResolvers
const IOP = Reseau.IOPoll

function _read_all_server_bytes(body::HT.AbstractBody)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 32)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
end

function _run_with_timeout(f::F; timeout_s::Float64 = 5.0, label::String = "operation") where {F <: Function}
    task = Threads.@spawn f()
    status = timedwait(() -> istaskdone(task), timeout_s; pollint = 0.001)
    status == :timed_out && error("timed out waiting for $label")
    return fetch(task)
end

mutable struct _BlockingResponseBody <: HT.AbstractBody
    gate::Channel{Nothing}
    data::Vector{UInt8}
    sent::Bool
end

function HT.body_read!(body::_BlockingResponseBody, dst::Vector{UInt8})::Int
    body.sent && return 0
    take!(body.gate)
    n = min(length(dst), length(body.data))
    copyto!(dst, 1, body.data, 1, n)
    body.sent = true
    return n
end

function HT.body_close!(body::_BlockingResponseBody)
    body.sent = true
    return nothing
end

function _raw_http_request(port::Integer, request::AbstractString; settle_s::Float64 = 0.5, close_write::Bool = true)::String
    sock = ND.connect("tcp", "127.0.0.1:$(Int(port))")
    try
        write(sock, Vector{UInt8}(codeunits(String(request))))
        if close_write
            HT.@try_ignore begin
                NC.closewrite(sock)
            end
        end
        return _read_until_quiet(
            sock;
            timeout_s = max(2.0, settle_s + 1.0),
            quiet_timeout_s = min(0.25, max(0.05, settle_s)),
        )
    finally
        NC.close(sock)
    end
end

function _raw_http_request_until_close(port::Integer, request::AbstractString; timeout_s::Float64 = 3.0)::Tuple{String, Bool}
    sock = ND.connect("tcp", "127.0.0.1:$(Int(port))")
    try
        write(sock, Vector{UInt8}(codeunits(String(request))))
        return _read_until_close(sock; timeout_s)
    finally
        NC.close(sock)
    end
end

function _read_until_deadline(conn::NC.Conn; timeout_s::Float64 = 1.0)::String
    buf = Vector{UInt8}(undef, 1024)
    out = UInt8[]
    while true
        NC.set_read_deadline!(conn, Int64(time_ns()) + round(Int64, timeout_s * 1.0e9))
        try
            chunk = readavailable(conn)
            n = length(chunk)
            n == 0 && break
            n > length(buf) && resize!(buf, n)
            copyto!(buf, 1, chunk, 1, n)
            append!(out, @view(buf[1:n]))
        catch err
            if err isa IOP.DeadlineExceededError || err isa EOFError
                break
            end
            if HT._is_peer_close_error(err::Exception)
                break
            end
            rethrow(err)
        end
    end
    return String(out)
end

function _read_until_quiet(conn::NC.Conn; timeout_s::Float64 = 1.0, quiet_timeout_s::Float64 = 0.1)::String
    buf = Vector{UInt8}(undef, 1024)
    out = UInt8[]
    deadline_ns = Int64(time_ns()) + round(Int64, timeout_s * 1.0e9)
    saw_bytes = false
    while true
        remaining_ns = deadline_ns - Int64(time_ns())
        remaining_ns <= 0 && break
        read_timeout_s = saw_bytes ? min(quiet_timeout_s, remaining_ns / 1.0e9) : (remaining_ns / 1.0e9)
        NC.set_read_deadline!(conn, Int64(time_ns()) + round(Int64, read_timeout_s * 1.0e9))
        try
            chunk = readavailable(conn)
            n = length(chunk)
            n == 0 && break
            n > length(buf) && resize!(buf, n)
            copyto!(buf, 1, chunk, 1, n)
            append!(out, @view(buf[1:n]))
            saw_bytes = true
        catch err
            if err isa IOP.DeadlineExceededError || err isa EOFError
                break
            end
            if HT._is_peer_close_error(err::Exception)
                break
            end
            rethrow(err)
        end
    end
    return String(out)
end

function _read_until_close(conn::NC.Conn; timeout_s::Float64 = 1.0)::Tuple{String, Bool}
    buf = Vector{UInt8}(undef, 1024)
    out = UInt8[]
    deadline_ns = Int64(time_ns()) + round(Int64, timeout_s * 1.0e9)
    while true
        remaining_ns = deadline_ns - Int64(time_ns())
        remaining_ns <= 0 && return String(out), false
        NC.set_read_deadline!(conn, Int64(time_ns()) + remaining_ns)
        try
            chunk = readavailable(conn)
            n = length(chunk)
            n == 0 && return String(out), true
            n > length(buf) && resize!(buf, n)
            copyto!(buf, 1, chunk, 1, n)
            append!(out, @view(buf[1:n]))
        catch err
            err isa IOP.DeadlineExceededError && return String(out), false
            (err isa EOFError || HT._is_peer_close_error(err::Exception)) && return String(out), true
            rethrow(err)
        end
    end
end

@testset "HTTP server SSE helper" begin
    response = HT.sse_stream(200)
    @test response.body isa HT.SSEStream
    stream = response.body::HT.SSEStream
    @test HT.header(response.headers, "Content-Type") == "text/event-stream"
    @test HT.header(response.headers, "Cache-Control") == "no-cache"
    close(stream)
end

@testset "HTTP server SSE roundtrip" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            response = HT.sse_stream(200) do stream
                write(stream, HT.SSEEvent("first"))
                write(stream, HT.SSEEvent("second"; event = "update", id = "2", retry = 2500))
                write(stream, HT.SSEEvent("multi\nline\ndata"))
            end
            return response
        end
    address = HT.server_addr(server)
    try
        @test isopen(server)
        @test HT.port(server) > 0
        events = HT.SSEEvent[]
        response = HT.get("http://$(address)/"; sse_callback = event -> push!(events, event))
        @test response.status == 200
        @test response.body === HT.nobody
        @test length(events) == 3
        @test events[1].data == "first"
        @test events[1].event === nothing
        @test events[1].id === nothing
        @test events[2].data == "second"
        @test events[2].event == "update"
        @test events[2].id == "2"
        @test events[2].retry == 2500
        @test events[3].data == "multi\nline\ndata"
    finally
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
        @test !isopen(server)
    end
end

@testset "HTTP server top-level wrapper kwargs and stream abort state" begin
    aborted_states = Channel{Bool}(2)
    server = HT.listen!("127.0.0.1", 0;
        listenany = true,
        read_timeout_ns = 11_000_000_000,
        read_header_timeout_ns = 22_000_000_000,
        write_timeout_ns = 33_000_000_000,
        idle_timeout_ns = 44_000_000_000,
        max_header_bytes = 512,
    ) do stream
        _ = HT.startread(stream)
        put!(aborted_states, HT.isaborted(stream))
        HT.setstatus(stream, 500)
        HT.setheader(stream, "Connection", "close")
        put!(aborted_states, HT.isaborted(stream))
        HT.startwrite(stream)
        write(stream, "aborted")
        return nothing
    end
    address = HT.server_addr(server)
    try
        @test server.read_timeout_ns == 11_000_000_000
        @test server.read_header_timeout_ns == 22_000_000_000
        @test server.write_timeout_ns == 33_000_000_000
        @test server.idle_timeout_ns == 44_000_000_000
        @test server.max_header_bytes == 512

        response = HT.get("http://$(address)/"; retry = false, status_exception = false)
        @test response.status == 500
        @test String(response.body) == "aborted"
        @test take!(aborted_states) == false
        @test take!(aborted_states) == true
    finally
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server streams ordinary H1 response heads before body EOF" begin
    gate = Channel{Nothing}(1)
    payload = collect(codeunits("hello"))
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
        _ = request
        body = _BlockingResponseBody(gate, payload, false)
        return HT.Response(200, body; content_length = length(payload))
    end
    address = HT.server_addr(server)
    conn = ND.connect("tcp", address)
    try
        write(conn, Vector{UInt8}(codeunits("GET / HTTP/1.1\r\nHost: $(address)\r\n\r\n")))
        head = _read_until_quiet(conn; timeout_s = 2.0, quiet_timeout_s = 0.05)
        @test occursin("HTTP/1.1 200", head)
        @test occursin("\r\n\r\n", head)
        @test !occursin("hello", head)

        put!(gate, nothing)
        rest = _read_until_quiet(conn; timeout_s = 2.0, quiet_timeout_s = 0.05)
        @test occursin("hello", head * rest)
    finally
        HT.@try_ignore begin
            NC.close(conn)
        end
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server basic request handling" begin
    seen_targets = String[]
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            push!(seen_targets, request.target)
            payload = collect(codeunits("echo:" * request.target))
            return HT.Response(200, HT.BytesBody(payload); reason = "OK", content_length = length(payload))
        end
    address = HT.server_addr(server)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4))
    try
        @test isopen(server)
        @test HT.port(server) > 0
        response1 = HT.get!(client, address, "/one")
        @test response1.status == 200
        @test String(_read_all_server_bytes(response1.body)) == "echo:/one"
        response2 = HT.get!(client, address, "/two")
        @test response2.status == 200
        @test String(_read_all_server_bytes(response2.body)) == "echo:/two"
        @test seen_targets == ["/one", "/two"]
    finally
        close(client.transport)
        _run_with_timeout(() -> close(server); label = "server close")
        _run_with_timeout(() -> wait(server); label = "server task completion")
        @test !isopen(server)
    end
end

@testset "HTTP server request handlers support text response bodies" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
        _ = request
        return HT.Response(404, "Not found")
    end
    address = HT.server_addr(server)
    try
        response = HT.get("http://$(address)/missing"; retry = false, status_exception = false)
        @test response.status == 404
        @test String(response.body) == "Not found"
    finally
        _run_with_timeout(() -> close(server); label = "server close")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP servecontent direct conditionals and single ranges" begin
    payload = collect(codeunits("abcdef"))
    modtime = Dates.DateTime(2024, 1, 2, 3, 4, 5)

    range_headers = HT.Headers()
    HT.setheader(range_headers, "Range", "bytes=2-4")
    range_req = HT.Request("GET", "/"; headers = range_headers)
    range_resp = HT.servecontent(range_req, payload; name = "demo.txt", etag = "\"v1\"", modtime = modtime)
    @test range_resp.status == 206
    @test HT.header(range_resp.headers, "Accept-Ranges") == "bytes"
    @test HT.header(range_resp.headers, "Content-Range") == "bytes 2-4/6"
    @test HT.header(range_resp.headers, "Content-Type") == "text/plain; charset=utf-8"
    @test range_resp.content_length == 3
    @test String(_read_all_server_bytes(range_resp.body)) == "cde"

    io_range_resp = HT.servecontent(range_req, IOBuffer(copy(payload)); name = "demo.txt")
    @test io_range_resp.status == 206
    @test HT.header(io_range_resp.headers, "Content-Range") == "bytes 2-4/6"
    @test String(_read_all_server_bytes(io_range_resp.body)) == "cde"

    none_match_headers = HT.Headers()
    HT.setheader(none_match_headers, "If-None-Match", "\"v1\"")
    none_match_req = HT.Request("GET", "/"; headers = none_match_headers)
    none_match_resp = HT.servecontent(none_match_req, payload; name = "demo.txt", etag = "\"v1\"", modtime = modtime)
    @test none_match_resp.status == 304
    @test isempty(_read_all_server_bytes(none_match_resp.body))
    @test HT.header(none_match_resp.headers, "ETag") == "\"v1\""

    if_match_headers = HT.Headers()
    HT.setheader(if_match_headers, "If-Match", "\"other\"")
    if_match_req = HT.Request("GET", "/"; headers = if_match_headers)
    if_match_resp = HT.servecontent(if_match_req, payload; name = "demo.txt", etag = "\"v1\"", modtime = modtime)
    @test if_match_resp.status == 412
    @test isempty(_read_all_server_bytes(if_match_resp.body))

    invalid_range_headers = HT.Headers()
    HT.setheader(invalid_range_headers, "Range", "bytes=20-25")
    invalid_range_req = HT.Request("GET", "/"; headers = invalid_range_headers)
    invalid_range_resp = HT.servecontent(invalid_range_req, payload; name = "demo.txt")
    @test invalid_range_resp.status == 416
    @test HT.header(invalid_range_resp.headers, "Content-Range") == "bytes */6"
    @test isempty(_read_all_server_bytes(invalid_range_resp.body))
end

@testset "HTTP servecontent live HTTP/1.1 range and HEAD behavior" begin
    payload = collect(codeunits("abcdef"))
    modtime = Dates.DateTime(2024, 1, 2, 3, 4, 5)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            return HT.servecontent(request, payload; name = "demo.txt", etag = "\"v1\"", modtime = modtime)
        end
    address = HT.server_addr(server)
    try
        range_headers = HT.Headers()
        HT.setheader(range_headers, "Range", "bytes=1-3")
        partial = HT.request("GET", "http://$(address)/"; headers = range_headers)
        @test partial.status == 206
        @test HT.header(partial.headers, "Content-Range") == "bytes 1-3/6"
        @test HT.header(partial.headers, "Content-Length") == "3"
        @test String(partial.body) == "bcd"

        head = HT.request("HEAD", "http://$(address)/"; headers = range_headers)
        @test head.status == 206
        @test HT.header(head.headers, "Content-Length") == "3"
        @test isempty(head.body)
    finally
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP servefile and fileserver over HTTP/1.1" begin
    mktempdir() do dir
        hello_path = joinpath(dir, "hello.txt")
        write(hello_path, "hello world")
        blob_path = joinpath(dir, "blob.custom")
        write(blob_path, "blob")
        docs_dir = joinpath(dir, "docs")
        mkpath(docs_dir)
        write(joinpath(docs_dir, "index.html"), "<p>docs</p>")

        direct_req = HT.Request("GET", "/hello.txt")
        direct_resp = HT.servefile(direct_req, hello_path; etag = :weak_stat, cache_control = "public, max-age=60")
        try
            @test direct_resp.status == 200
            @test HT.header(direct_resp.headers, "Cache-Control") == "public, max-age=60"
            @test HT.header(direct_resp.headers, "Content-Type") == "text/plain; charset=utf-8"
            @test !isempty(HT.header(direct_resp.headers, "ETag", ""))
            @test String(_read_all_server_bytes(direct_resp.body)) == "hello world"
        finally
            HT.body_close!(direct_resp.body)
        end

        blob_resp = HT.servefile(HT.Request("GET", "/blob.custom"), blob_path)
        try
            @test blob_resp.status == 200
            @test HT.header(blob_resp.headers, "Content-Type") == "application/octet-stream"
        finally
            HT.body_close!(blob_resp.body)
        end

        server = HT.serve!(HT.fileserver(dir; etag = :weak_stat, cache_control = "public, max-age=60"), "127.0.0.1", 0; listenany = true)
        address = HT.server_addr(server)
        try
            range_headers = HT.Headers()
            HT.setheader(range_headers, "Range", "bytes=6-10")
            partial = HT.request("GET", "http://$(address)/hello.txt"; headers = range_headers)
            @test partial.status == 206
            @test HT.header(partial.headers, "Content-Range") == "bytes 6-10/11"
            @test String(partial.body) == "world"
            @test !isempty(HT.header(partial.headers, "ETag", ""))

            dir_redirect = HT.request("GET", "http://$(address)/docs"; redirect = false, status_exception = false)
            @test dir_redirect.status == 301
            @test HT.header(dir_redirect.headers, "Location") == "/docs/"

            index_redirect = HT.request("GET", "http://$(address)/docs/index.html"; redirect = false, status_exception = false)
            @test index_redirect.status == 301
            @test HT.header(index_redirect.headers, "Location") == "/docs/"

            file_redirect = HT.request("GET", "http://$(address)/hello.txt/"; redirect = false, status_exception = false)
            @test file_redirect.status == 301
            @test HT.header(file_redirect.headers, "Location") == "/hello.txt"

            index_resp = HT.get("http://$(address)/docs/"; status_exception = false)
            @test index_resp.status == 200
            @test String(index_resp.body) == "<p>docs</p>"

            post_resp = HT.request("POST", "http://$(address)/hello.txt"; status_exception = false)
            @test post_resp.status == 405
            @test HT.header(post_resp.headers, "Allow") == "GET, HEAD"

            traversal = _raw_http_request(
                HT.port(server),
                "GET /%2e%2e/secret HTTP/1.1\r\nHost: $(address)\r\n\r\n";
                settle_s = 0.1,
            )
            @test occursin("HTTP/1.1 400 Bad Request", traversal)
        finally
            _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
            _run_with_timeout(() -> wait(server); label = "server task completion")
        end
    end
end

@testset "HTTP fileserver SPA fallback over HTTP/1.1" begin
    mktempdir() do dir
        write(joinpath(dir, "index.html"), "<p>shell</p>")
        assets_dir = joinpath(dir, "assets")
        mkpath(assets_dir)
        write(joinpath(assets_dir, "app.js"), "console.log('ok');")

        @test_throws ArgumentError HT.fileserver(dir; spa_fallback = "../index.html")

        server = HT.serve!(HT.fileserver(dir; spa_fallback = "index.html"), "127.0.0.1", 0; listenany = true)
        address = HT.server_addr(server)
        try
            route_resp = HT.get("http://$(address)/gallery"; status_exception = false)
            @test route_resp.status == 200
            @test String(route_resp.body) == "<p>shell</p>"

            nested_resp = HT.get("http://$(address)/gallery/featured"; status_exception = false)
            @test nested_resp.status == 200
            @test String(nested_resp.body) == "<p>shell</p>"

            asset_resp = HT.get("http://$(address)/assets/app.js"; status_exception = false)
            @test asset_resp.status == 200
            @test String(asset_resp.body) == "console.log('ok');"

            missing_asset = HT.get("http://$(address)/assets/missing.js"; status_exception = false)
            @test missing_asset.status == 404

            dotted_route = HT.get("http://$(address)/gallery.v2"; status_exception = false)
            @test dotted_route.status == 404
        finally
            _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
            _run_with_timeout(() -> wait(server); label = "server task completion")
        end
    end
end

@testset "HTTP server request handler timeout middleware on HTTP/1.1" begin
    handler = HT.Handlers.handlertimeout(0.05)(request -> begin
        if request.target == "/fast"
            return HT.Response(200, HT.BytesBody(UInt8[0x6f, 0x6b]); content_length = 2)
        end
        sleep(0.15)
        return HT.Response(200, HT.BytesBody(UInt8[0x6c, 0x61, 0x74, 0x65]); content_length = 4)
    end)
    server = HT.serve!(handler, "127.0.0.1", 0; listenany = true)
    address = HT.server_addr(server)
    try
        slow = HT.get("http://$(address)/slow"; status_exception = false)
        @test slow.status == 503
        @test String(slow.body) == "handler timed out"

        fast = HT.get("http://$(address)/fast")
        @test fast.status == 200
        @test String(fast.body) == "ok"
    finally
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server wire-level parse and continue behavior" begin
    small_header_server = HT.Server(
        address = "127.0.0.1:0",
        stream = true,
        max_header_bytes = 512,
        handler = stream -> begin
            _ = HT.startread(stream)
            HT.setstatus(stream, 200)
            HT.startwrite(stream)
            return nothing
        end,
    )
    HT.listen!(small_header_server)
    server = HT.listen!("127.0.0.1", 0; listenany = true) do stream
        _ = HT.startread(stream)
        body = read(stream)
        HT.setstatus(stream, 200)
        HT.startwrite(stream)
        isempty(body) || write(stream, body)
        return nothing
    end
    address = HT.server_addr(server)
    small_header_address = HT.server_addr(small_header_server)
    try
        port_num = HT.port(server)
        large_header_resp = _raw_http_request(HT.port(small_header_server), "GET / HTTP/1.1\r\nHost: $(small_header_address)\r\n$(repeat("Foo: Bar\r\n", 200))\r\n")
        @test occursin("HTTP/1.1 431 Request Header Fields Too Large", large_header_resp)

        invalid_resp = _raw_http_request(port_num, "GET / HTP/1.1\r\n\r\n")
        @test occursin("HTTP/1.1 400 Bad Request", invalid_resp)

        no_target_resp = _raw_http_request(port_num, "SOMEMETHOD HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
        @test occursin("HTTP/1.1 400 Bad Request", no_target_resp)

        missing_host_resp = _raw_http_request(port_num, "GET / HTTP/1.1\r\n\r\n")
        @test occursin("HTTP/1.1 400 Bad Request", missing_host_resp)

        whitespace_host_resp = _raw_http_request(port_num, "GET / HTTP/1.1\r\nHost : $(address)\r\n\r\n")
        @test occursin("HTTP/1.1 400 Bad Request", whitespace_host_resp)

        duplicate_host_resp = _raw_http_request(port_num, "GET / HTTP/1.1\r\nHost: $(address)\r\nHost: $(address)\r\n\r\n")
        @test occursin("HTTP/1.1 400 Bad Request", duplicate_host_resp)

        invalid_target_resp = _raw_http_request(port_num, "GET foo HTTP/1.1\r\nHost: $(address)\r\n\r\n")
        @test occursin("HTTP/1.1 400 Bad Request", invalid_target_resp)

        sock = ND.connect("tcp", "127.0.0.1:$(port_num)")
        try
            write(sock, Vector{UInt8}(codeunits("POST / HTTP/1.1\r\nHost: $(address)\r\nContent-Length: 15\r\nExpect: 100-continue\r\n\r\n")))
            sleep(0.1)
            interim = _read_until_deadline(sock)
            @test interim == "HTTP/1.1 100 Continue\r\n\r\n"
            write(sock, Vector{UInt8}(codeunits("Body of Request")))
            sleep(0.1)
            final = _read_until_deadline(sock)
            @test occursin("HTTP/1.1 200 OK\r\n", final)
            @test occursin("Transfer-Encoding: chunked\r\n", final)
            @test occursin("Body of Request", final)
        finally
            NC.close(sock)
        end
    finally
        _run_with_timeout(() -> HT.forceclose(small_header_server); label = "small header server forceclose")
        _run_with_timeout(() -> wait(small_header_server); label = "small header server task completion")
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server rejects unsupported Expect headers" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            return HT.Response(200, HT.BytesBody(UInt8[0x6f, 0x6b]); content_length = 2)
    end
    address = HT.server_addr(server)
    try
        raw = _raw_http_request(HT.port(server), "POST / HTTP/1.1\r\nHost: $(address)\r\nContent-Length: 0\r\nExpect: fancy-feature\r\nConnection: close\r\n\r\n"; settle_s = 0.3)
        @test occursin("HTTP/1.1 417", raw)
    finally
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server stream handlers suppress bodies for HEAD, 204, and 304" begin
    server = HT.listen!("127.0.0.1", 0; listenany = true) do stream
            request = HT.startread(stream)
            if request.target == "/nocontent"
                HT.setstatus(stream, 204)
            elseif request.target == "/notmodified"
                HT.setstatus(stream, 304)
            else
                HT.setstatus(stream, 200)
            end
            HT.startwrite(stream)
            write(stream, "oops")
            return nothing
        end
    address = HT.server_addr(server)
    try
        head_raw = _raw_http_request(HT.port(server), "HEAD /head HTTP/1.1\r\nHost: $(address)\r\nConnection: close\r\n\r\n"; settle_s = 0.3)
        @test occursin("HTTP/1.1 200 OK", head_raw)
        @test !occursin("oops", head_raw)
        @test !occursin("transfer-encoding: chunked", lowercase(head_raw))

        no_content_raw = _raw_http_request(HT.port(server), "GET /nocontent HTTP/1.1\r\nHost: $(address)\r\nConnection: close\r\n\r\n"; settle_s = 0.3)
        @test occursin("HTTP/1.1 204 No Content", no_content_raw)
        @test !occursin("oops", no_content_raw)
        @test !occursin("transfer-encoding: chunked", lowercase(no_content_raw))

        not_modified_raw = _raw_http_request(HT.port(server), "GET /notmodified HTTP/1.1\r\nHost: $(address)\r\nConnection: close\r\n\r\n"; settle_s = 0.3)
        @test occursin("HTTP/1.1 304 Not Modified", not_modified_raw)
        @test !occursin("oops", not_modified_raw)
        @test !occursin("transfer-encoding: chunked", lowercase(not_modified_raw))
    finally
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server timeout and handler error responses" begin
    timeout_server = HT.Server(
        address = "127.0.0.1:0",
        stream = true,
        read_header_timeout_ns = 200_000_000,
        handler = stream -> begin
            _ = stream
            return nothing
        end,
    )
    HT.listen!(timeout_server)
    timeout_address = HT.server_addr(timeout_server)
    try
        sock = ND.connect("tcp", "127.0.0.1:$(HT.port(timeout_server))")
        try
            sleep(0.6)
            timed_out = _read_until_deadline(sock; timeout_s = 1.0)
            @test occursin("HTTP/1.1 408 Request Timeout", timed_out)
        finally
            NC.close(sock)
        end
    finally
        _run_with_timeout(() -> HT.forceclose(timeout_server); label = "timeout server forceclose")
        _run_with_timeout(() -> wait(timeout_server); label = "timeout server task completion")
    end

    error_server = HT.serve!("127.0.0.1", 0; listenany = true) do request
        _ = request
        error("boom")
    end
    error_address = HT.server_addr(error_server)
    try
        response = HT.get("http://$(error_address)/"; retry = false, status_exception = false)
        @test response.status == 500
    finally
        _run_with_timeout(() -> HT.forceclose(error_server); label = "error server forceclose")
        _run_with_timeout(() -> wait(error_server); label = "error server task completion")
    end
end

@testset "HTTP server idle timeout closes keep-alive connections" begin
    server = HT.Server(
        address = "127.0.0.1:0",
        stream = true,
        idle_timeout_ns = 200_000_000,
        handler = stream -> begin
            _ = HT.startread(stream)
            HT.setstatus(stream, 200)
            HT.startwrite(stream)
            write(stream, "ok")
            return nothing
        end,
    )
    HT.listen!(server)
    address = HT.server_addr(server)
    sock = ND.connect("tcp", "127.0.0.1:$(HT.port(server))")
    try
        write(sock, Vector{UInt8}(codeunits("GET /one HTTP/1.1\r\nHost: $(address)\r\n\r\n")))
        first = _read_until_quiet(sock; timeout_s = 2.0, quiet_timeout_s = 0.1)
        @test occursin("HTTP/1.1 200 OK", first)
        sleep(1.0)
        closed_after_idle = false
        try
            write(sock, Vector{UInt8}(codeunits("GET /two HTTP/1.1\r\nHost: $(address)\r\n\r\n")))
            second = _read_until_quiet(sock; timeout_s = 0.5, quiet_timeout_s = 0.1)
            closed_after_idle = !occursin("HTTP/1.1 200 OK", second)
        catch err
            closed_after_idle = err isa EOFError || err isa SystemError || err isa IOP.DeadlineExceededError
        end
        @test closed_after_idle
    finally
        HT.@try_ignore begin
            NC.close(sock)
        end
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server write timeout aborts stalled responses" begin
    timeout_seen = Channel{Bool}(1)
    server = HT.Server(
        address = "127.0.0.1:0",
        stream = true,
        write_timeout_ns = 200_000_000,
        handler = stream -> begin
            _ = HT.startread(stream)
            HT.setstatus(stream, 200)
            HT.startwrite(stream)
            chunk = fill(UInt8('x'), 64 * 1024)
            try
                while true
                    write(stream, chunk)
                end
            catch err
                put!(timeout_seen, err isa IOP.DeadlineExceededError)
            end
            return nothing
        end,
    )
    HT.listen!(server)
    address = HT.server_addr(server)
    sock = ND.connect("tcp", "127.0.0.1:$(HT.port(server))")
    try
        write(sock, Vector{UInt8}(codeunits("GET / HTTP/1.1\r\nHost: $(address)\r\n\r\n")))
        status = timedwait(() -> isready(timeout_seen), 5.0; pollint = 0.001)
        @test status != :timed_out
        @test take!(timeout_seen)
    finally
        HT.@try_ignore begin
            NC.close(sock)
        end
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server ordinary handlers suppress bodies for HEAD" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            return HT.Response(
                200,
                HT.BytesBody(collect(codeunits("oops")));
                content_length = 4,
                request = request,
            )
        end
    address = HT.server_addr(server)
    try
        head_raw = _raw_http_request(HT.port(server), "HEAD /head HTTP/1.1\r\nHost: $(address)\r\nConnection: close\r\n\r\n"; settle_s = 0.3)
        @test occursin("HTTP/1.1 200 OK", head_raw)
        @test occursin("Content-Length: 4\r\n", head_raw)
        @test !occursin("transfer-encoding: chunked", lowercase(head_raw))
        parts = split(head_raw, "\r\n\r\n"; limit = 2)
        @test length(parts) == 2
        @test parts[2] == ""
    finally
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server ordinary handlers receive buffered request bodies" begin
    seen_buffered = Channel{Bool}(2)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            put!(seen_buffered, request.body isa HT.BytesBody)
            return HT.Response(200, String(request.body))
        end
    address = HT.server_addr(server)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 1, max_idle_total = 1), cookiejar = nothing)
    try
        resp1 = HT.post("http://$(address)/echo"; body = "echo", client = client)
        @test resp1.status == 200
        @test String(resp1.body) == "echo"
        @test take!(seen_buffered)

        resp2 = HT.post("http://$(address)/again"; body = "again", client = client)
        @test resp2.status == 200
        @test String(resp2.body) == "again"
        @test take!(seen_buffered)
    finally
        close(client)
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server stream handler request and response flow" begin
    server = HT.listen!("127.0.0.1", 0; listenany = true) do stream
            _ = HT.startread(stream)
            body = String(read(stream))
            HT.setstatus(stream, 200)
            HT.setheader(stream, "Content-Type", "text/plain")
            HT.startwrite(stream)
            write(stream, isempty(body) ? "ping" : body)
            return nothing
        end
    address = HT.server_addr(server)
    try
        resp1 = HT.get("http://$(address)/")
        @test resp1.status == 200
        @test String(resp1.body) == "ping"

        resp2 = HT.post("http://$(address)/"; body = "echo")
        @test resp2.status == 200
        @test String(resp2.body) == "echo"
    finally
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server stream handlers reject fixed-length mismatches before writing malformed bodies" begin
    server = HT.listen!("127.0.0.1", 0; listenany = true) do stream
            request = HT.startread(stream)
            if request.target == "/overflow"
                HT.setheader(stream, "Content-Length", "2")
                HT.startwrite(stream)
                write(stream, "toolong")
                return nothing
            end
            HT.setheader(stream, "Content-Length", "5")
            HT.startwrite(stream)
            write(stream, "hi")
            return nothing
        end
    address = HT.server_addr(server)
    try
        overflow_raw = _raw_http_request(HT.port(server), "GET /overflow HTTP/1.1\r\nHost: $(address)\r\nConnection: close\r\n\r\n"; settle_s = 0.3)
        @test !occursin("toolong", overflow_raw)
        @test !occursin("content-length: 2", lowercase(overflow_raw))

        underflow_raw = _raw_http_request(HT.port(server), "GET /underflow HTTP/1.1\r\nHost: $(address)\r\nConnection: close\r\n\r\n"; settle_s = 0.3)
        @test !occursin("hi", underflow_raw)
        @test !occursin("content-length: 5", lowercase(underflow_raw))
    finally
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server stream handler emits chunked trailers" begin
    server = HT.listen!("127.0.0.1", 0; listenany = true) do stream
            _ = HT.startread(stream)
            _ = read(stream)
            HT.setstatus(stream, 200)
            HT.startwrite(stream)
            write(stream, "hello")
            HT.addtrailer(stream, "X-Trailer" => "ok")
            return nothing
        end
    address = HT.server_addr(server)
    try
        raw = _raw_http_request(HT.port(server), "GET / HTTP/1.1\r\nHost: $(address)\r\nConnection: close\r\n\r\n"; settle_s = 0.3)
        lower_raw = lowercase(raw)
        @test occursin("transfer-encoding: chunked", lower_raw)
        @test occursin("hello", raw)
        @test occursin("\r\n0\r\nx-trailer: ok\r\n\r\n", lower_raw)
    finally
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server shutdown rejects new requests" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            return HT.Response(200, HT.BytesBody(UInt8[0x6f, 0x6b]); reason = "OK", content_length = 2)
        end
    address = HT.server_addr(server)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4))
    try
        response = _run_with_timeout(() -> HT.get!(client, address, "/live"); label = "live request")
        @test response.status == 200
        @test String(_read_all_server_bytes(response.body)) == "ok"
        _run_with_timeout(() -> close(server); label = "server close")
        _run_with_timeout(() -> wait(server); label = "server task completion")
        @test !isopen(server)
        # Bound the post-shutdown probe so Windows CI cannot hang indefinitely
        # if a stale keep-alive conn does not surface close immediately.
        probe = HT.Request("GET", "/after-shutdown"; host = address, body = HT.EmptyBody(), content_length = 0)
        HT.set_deadline!(HT.get_request_context(probe), Int64(time_ns()) + Int64(2_000_000_000))
        @test_throws Exception _run_with_timeout(() -> HT.do!(client, address, probe); timeout_s = 3.0, label = "post-shutdown request")
    finally
        close(client.transport)
    end
end

@testset "HTTP server close waits for active requests to finish" begin
    started = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            _ = request
            put!(started, nothing)
            take!(release)
            return HT.Response(200, HT.BytesBody(UInt8[0x6f, 0x6b]); content_length = 2)
        end
    address = HT.server_addr(server)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4))
    close_task = nothing
    try
        response_task = Threads.@spawn HT.get!(client, address, "/slow")
        take!(started)
        close_task = Threads.@spawn close(server)
        sleep(0.1)
        @test !istaskdone(close_task::Task)
        put!(release, nothing)
        response = fetch(response_task)
        @test response.status == 200
        @test String(_read_all_server_bytes(response.body)) == "ok"
        _run_with_timeout(() -> fetch(close_task::Task); label = "graceful close task")
        @test !isopen(server)
    finally
        close(client.transport)
        close_task === nothing || HT.@try_ignore begin
            fetch(close_task::Task)
        end
        isopen(server) && HT.forceclose(server)
        _run_with_timeout(() -> wait(server); label = "server task completion")
    end
end

@testset "HTTP server closes keep-alive when request body is unread" begin
    server = HT.listen!("127.0.0.1", 0; listenany = true) do stream
            request = HT.startread(stream)
            payload = collect(codeunits("ok:" * request.target))
            HT.setstatus(stream, 200)
            HT.startwrite(stream)
            write(stream, payload)
            return nothing
        end
    address = HT.server_addr(server)
    try
        post_response, post_closed = _raw_http_request_until_close(
            HT.port(server),
            "POST /one HTTP/1.1\r\nHost: $(address)\r\nContent-Length: 3\r\n\r\nabc";
            timeout_s = Sys.iswindows() ? 5.0 : 2.0,
        )
        @test occursin("HTTP/1.1 200", post_response)
        @test occursin("ok:/one", post_response)
        @test post_closed

        get_response, get_closed = _raw_http_request_until_close(
            HT.port(server),
            "GET /two HTTP/1.1\r\nHost: $(address)\r\nConnection: close\r\n\r\n";
            timeout_s = Sys.iswindows() ? 5.0 : 2.0,
        )
        @test occursin("HTTP/1.1 200", get_response)
        @test occursin("ok:/two", get_response)
        @test get_closed
    finally
        _run_with_timeout(() -> HT.forceclose(server); label = "server forceclose")
        _run_with_timeout(() -> wait(server); label = "server task completion")
        @test !isopen(server)
    end
end
