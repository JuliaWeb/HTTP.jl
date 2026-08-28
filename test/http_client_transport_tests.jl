using Test
using HTTP
using Reseau

const HT = HTTP
const NC = Reseau.TCP
const ND = Reseau.HostResolvers
const IP = Reseau.IOPoll
const TL = Reseau.TLS

if !isdefined(@__MODULE__, :_http_windows_ci)
    @inline function _http_windows_ci()::Bool
        return Sys.iswindows() && get(ENV, "GITHUB_ACTIONS", "false") == "true"
    end
end

function _read_all_transport_body_bytes(body::HT.AbstractBody)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 32)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
end

function _write_all_tcp!(conn::NC.Conn, bytes::Vector{UInt8})::Nothing
    total = 0
    while total < length(bytes)
        n = write(conn, bytes[(total + 1):end])
        n > 0 || error("expected write progress")
        total += n
    end
    return nothing
end

function _write_response_to_conn!(conn::NC.Conn, request::HT.Request; body_text::String, close_conn::Bool = false)::Nothing
    payload = collect(codeunits(body_text))
    return _write_response_bytes_to_conn!(conn, request; body_bytes = payload, close_conn = close_conn)
end

function _write_response_bytes_to_conn!(conn::NC.Conn, request::HT.Request; body_bytes::Vector{UInt8}, headers::HT.Headers = HT.Headers(), close_conn::Bool = false)::Nothing
    headers_copy = copy(headers)
    close_conn && HT.setheader(headers_copy, "Connection", "close")
    response = HT.Response(
        200,
        HT.BytesBody(body_bytes);
        reason = "OK",
        headers = headers_copy,
        content_length = length(body_bytes),
        close = close_conn,
        request = request,
    )
    io = IOBuffer()
    HT.write_response!(io, response)
    _write_all_tcp!(conn, take!(io))
    return nothing
end

function _gzip_bytes_transport(text::String)::Vector{UInt8}
    return transcode(HTTP.CodecZlib.GzipCompressor, collect(codeunits(text)))
end

function _deflate_bytes_transport(text::String)::Vector{UInt8}
    return transcode(HTTP.CodecZlib.ZlibCompressor, collect(codeunits(text)))
end

function _wait_task!(task::Task)
    fetch(task)
    return nothing
end

function _wait_for_transport_waiter!(transport::HT.Transport, key::String)::Nothing
    lock(transport.lock)
    try
        while isempty(get(() -> HT._ConnWaiter[], transport.waiters, key))
            wait(transport.waiter_condition)
        end
    finally
        unlock(transport.lock)
    end
    return nothing
end

function _wait_for_transport_waiter_or_task!(transport::HT.Transport, key::String, task::Task)::Bool
    lock(transport.lock)
    try
        while isempty(get(() -> HT._ConnWaiter[], transport.waiters, key)) && !istaskdone(task)
            wait(transport.waiter_condition)
        end
        return !isempty(get(() -> HT._ConnWaiter[], transport.waiters, key))
    finally
        unlock(transport.lock)
    end
end

function _transport_debug(msg::AbstractString)
    _ = msg
    return nothing
end

@testset "_read_all_response_bytes caps eager preallocation" begin
    payload = collect(codeunits("ok"))
    body = HT.BytesBody(payload)
    bytes = HT._read_all_response_bytes(body, HT._MAX_EAGER_RESPONSE_PREALLOC + 1)
    @test bytes == payload
end

@testset "HTTP transport constructor validates max_conns_per_host" begin
    @test_throws ArgumentError HT.Transport(max_conns_per_host = -1)
end

@testset "HTTP transport waiter uses deterministic wake state" begin
    transport = HT.Transport()
    waiter = HT._ConnWaiter("http://waiter.test")
    wait_calls = Ref(0)
    wait_for = (predicate, _timeout_seconds; kwargs...) -> begin
        wait_calls[] += 1
        @atomic :release waiter.state = HT._CONN_WAITER_DIAL
        @test predicate()
        return :ok
    end
    try
        result = HT._wait_for_conn!(
            transport,
            waiter,
            Int64(10);
            clock_ns = () -> Int64(0),
            wait_for = wait_for,
        )
        @test result === :dial
        @test wait_calls[] == 1
    finally
        close(transport)
    end
end

@testset "HTTP client transport handles duplicate concurrent requests" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:2
            conn = NC.accept(listener)
            try
                request = HT.read_request(HT._ConnReader(conn))
                _read_all_transport_body_bytes(request.body)
                _write_response_to_conn!(conn, request; body_text = "ok", close_conn = true)
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    try
        req1 = HT.Request("GET", "/one"; host = address, body = HT.EmptyBody(), content_length = 0)
        req2 = HT.Request("GET", "/two"; host = address, body = HT.EmptyBody(), content_length = 0)
        task1 = errormonitor(Threads.@spawn HT.roundtrip!(transport, address, req1))
        task2 = errormonitor(Threads.@spawn HT.roundtrip!(transport, address, req2))
        @test _wait_task!(task1) === nothing
        @test _wait_task!(task2) === nothing
        res1 = fetch(task1)
        res2 = fetch(task2)
        @test String(_read_all_transport_body_bytes(res1.body)) == "ok"
        @test String(_read_all_transport_body_bytes(res2.body)) == "ok"
        _wait_task!(server_task)
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "_ConnReader uses buffered reads for HTTP/1 parsing" begin
    raw = collect(codeunits("POST /upload HTTP/1.1\r\nHost: example.test\r\nContent-Length: 5\r\n\r\nhello"))
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 1)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    client = nothing
    conn = nothing
    try
        client = ND.connect("tcp", address)
        conn = NC.accept(listener)
        offset = 1
        while offset <= length(raw)
            stop = min(offset + 7, length(raw))
            write(client, raw[offset:stop])
            offset = stop + 1
        end
        HTTP.@try_ignore NC.closewrite(client)
        reader = HT._ConnReader(conn, 32)
        request = HT.read_request(reader)
        @test request.method == "POST"
        @test request.target == "/upload"
        @test request.content_length == 5
        @test String(_read_all_transport_body_bytes(request.body)) == "hello"
    finally
        client === nothing || HTTP.@try_ignore NC.close(client)
        conn === nothing || HTTP.@try_ignore NC.close(conn)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "_ConnReader reads a byte through the refill path" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 1)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    client = nothing
    conn = nothing
    try
        client = ND.connect("tcp", address)
        conn = NC.accept(listener)
        write(client, UInt8('x'))
        @test HT._read_u8(HT._ConnReader(conn, 1)) == UInt8('x')
    finally
        client === nothing || HTTP.@try_ignore NC.close(client)
        conn === nothing || HTTP.@try_ignore NC.close(conn)
        HTTP.@try_ignore NC.close(listener)
    end
end

if _http_windows_ci()
    @testset "HTTP client transport keep-alive reuse" begin
        @test_skip true
    end

    @testset "HTTP client transport no reuse on Connection close" begin
        @test_skip true
    end

    @testset "HTTP client transport keep-alive reuse with gzip decompression" begin
        @test_skip true
    end

    @testset "HTTP client transport keep-alive reuse with deflate decompression" begin
        @test_skip true
    end

    @testset "HTTP client transport hands off waiting acquire under host cap" begin
        @test_skip true
    end

    @testset "HTTP client transport wakes waiter to redial after early close under host cap" begin
        @test_skip true
    end

    @testset "HTTP client transport waiter honors request deadline under host cap" begin
        @test_skip true
    end

    @testset "HTTP client transport skips interim 1xx responses" begin
        @test_skip true
    end

    @testset "HTTP client transport closes request body after send" begin
        @test_skip true
    end

    @testset "HTTP client transport does not reuse conn after early response close" begin
        @test_skip true
    end

    @testset "HTTP client transport retries idempotent request on stale reused conn" begin
        @test_skip true
    end

    @testset "HTTP client transport force-fresh acquire replaces reused conns" begin
        @test_skip true
    end

    @testset "HTTP client transport retries stale PUT and DELETE requests" begin
        @test_skip true
    end
else
@testset "HTTP client transport keep-alive reuse" begin
    _transport_debug("keep-alive reuse: start")
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    lock_obj = ReentrantLock()
    accept_count = Ref(0)
    paths = String[]
    server_task = errormonitor(Threads.@spawn begin
        _transport_debug("keep-alive reuse: server waiting accept")
        conn = NC.accept(listener)
        _transport_debug("keep-alive reuse: server accepted")
        lock(lock_obj)
        try
            accept_count[] += 1
        finally
            unlock(lock_obj)
        end
        try
            for _ in 1:2
                _transport_debug("keep-alive reuse: server read_request begin")
                request = HT.read_request(HT._ConnReader(conn))
                _transport_debug("keep-alive reuse: server read_request done")
                push!(paths, request.target)
                _read_all_transport_body_bytes(request.body)
                _write_response_to_conn!(conn, request; body_text = "ok")
                _transport_debug("keep-alive reuse: server response written")
            end
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    try
        _transport_debug("keep-alive reuse: client req1 begin")
        _transport_debug("keep-alive reuse: client req1 build request")
        req1 = HT.Request("GET", "/one"; host = address, body = HT.EmptyBody(), content_length = 0)
        _transport_debug("keep-alive reuse: client req1 build done")
        _transport_debug("keep-alive reuse: client req1 roundtrip call")
        res1 = HT.roundtrip!(transport, address, req1)
        _transport_debug("keep-alive reuse: client req1 roundtrip done")
        @test String(_read_all_transport_body_bytes(res1.body)) == "ok"
        _transport_debug("keep-alive reuse: client req2 begin")
        req2 = HT.Request("GET", "/two"; host = address, body = HT.EmptyBody(), content_length = 0)
        res2 = HT.roundtrip!(transport, address, req2)
        _transport_debug("keep-alive reuse: client req2 roundtrip done")
        @test String(_read_all_transport_body_bytes(res2.body)) == "ok"
        _transport_debug("keep-alive reuse: waiting server task")
        _wait_task!(server_task)
        _transport_debug("keep-alive reuse: server task done")
        @test accept_count[] == 1
        @test paths == ["/one", "/two"]
        @test HT.idle_connection_count(transport; key = "http://$address") == 1
        HT.close_idle_connections!(transport)
        @test HT.idle_connection_count(transport) == 0
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport no reuse on Connection close" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    lock_obj = ReentrantLock()
    accept_count = Ref(0)
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:2
            conn = NC.accept(listener)
            lock(lock_obj)
            try
                accept_count[] += 1
            finally
                unlock(lock_obj)
            end
            try
                request = HT.read_request(HT._ConnReader(conn))
                _read_all_transport_body_bytes(request.body)
                _write_response_to_conn!(conn, request; body_text = "bye", close_conn = true)
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    try
        req1 = HT.Request("GET", "/a"; host = address, body = HT.EmptyBody(), content_length = 0)
        res1 = HT.roundtrip!(transport, address, req1)
        @test String(_read_all_transport_body_bytes(res1.body)) == "bye"
        req2 = HT.Request("GET", "/b"; host = address, body = HT.EmptyBody(), content_length = 0)
        res2 = HT.roundtrip!(transport, address, req2)
        @test String(_read_all_transport_body_bytes(res2.body)) == "bye"
        _wait_task!(server_task)
        @test accept_count[] == 2
        @test HT.idle_connection_count(transport) == 0
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport keep-alive reuse with gzip decompression" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    accept_count = Ref(0)
    paths = String[]
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        accept_count[] += 1
        try
            for _ in 1:2
                request = HT.read_request(HT._ConnReader(conn))
                push!(paths, request.target)
                _read_all_transport_body_bytes(request.body)
                headers = HT.Headers()
                HT.setheader(headers, "Content-Encoding", "gzip")
                _write_response_bytes_to_conn!(
                    conn,
                    request;
                    body_bytes = _gzip_bytes_transport("gzip-ok"),
                    headers = headers,
                )
            end
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    client = HT.Client(transport = transport)
    try
        res1 = HT.get("$(base_url)/one"; client = client)
        @test String(res1.body) == "gzip-ok"
        res2 = HT.get("$(base_url)/two"; client = client)
        @test String(res2.body) == "gzip-ok"
        _wait_task!(server_task)
        @test accept_count[] == 1
        @test paths == ["/one", "/two"]
        @test HT.idle_connection_count(transport; key = "http://$address") == 1
    finally
        close(client)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport keep-alive reuse with deflate decompression" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    accept_count = Ref(0)
    paths = String[]
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        accept_count[] += 1
        try
            for _ in 1:2
                request = HT.read_request(HT._ConnReader(conn))
                push!(paths, request.target)
                _read_all_transport_body_bytes(request.body)
                headers = HT.Headers()
                HT.setheader(headers, "Content-Encoding", "deflate")
                _write_response_bytes_to_conn!(
                    conn,
                    request;
                    body_bytes = _deflate_bytes_transport("deflate-ok"),
                    headers = headers,
                )
            end
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    client = HT.Client(transport = transport)
    try
        res1 = HT.get("$(base_url)/one"; client = client)
        @test String(res1.body) == "deflate-ok"
        res2 = HT.get("$(base_url)/two"; client = client)
        @test String(res2.body) == "deflate-ok"
        _wait_task!(server_task)
        @test accept_count[] == 1
        @test paths == ["/one", "/two"]
        @test HT.idle_connection_count(transport; key = "http://$address") == 1
    finally
        close(client)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport hands off waiting acquire under host cap" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    accept_count = Ref(0)
    paths = String[]
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        accept_count[] += 1
        try
            req1 = HT.read_request(HT._ConnReader(conn))
            push!(paths, req1.target)
            _read_all_transport_body_bytes(req1.body)
            _write_response_to_conn!(conn, req1; body_text = "first")
            req2 = HT.read_request(HT._ConnReader(conn))
            push!(paths, req2.target)
            _read_all_transport_body_bytes(req2.body)
            _write_response_to_conn!(conn, req2; body_text = "second", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 1, max_idle_total = 1, max_conns_per_host = 1)
    try
        req1 = HT.Request("GET", "/one"; host = address, body = HT.EmptyBody(), content_length = 0)
        res1 = HT.roundtrip!(transport, address, req1)
        @test res1.status == 200

        req2 = HT.Request("GET", "/two"; host = address, body = HT.EmptyBody(), content_length = 0)
        res2_task = errormonitor(Threads.@spawn HT.roundtrip!(transport, address, req2))

        _wait_for_transport_waiter!(transport, "http://$address")

        @test String(_read_all_transport_body_bytes(res1.body)) == "first"

        res2 = fetch(res2_task)
        @test res2.status == 200
        @test String(_read_all_transport_body_bytes(res2.body)) == "second"
        _wait_task!(server_task)
        @test accept_count[] == 1
        @test paths == ["/one", "/two"]
        @test HT.idle_connection_count(transport) == 0
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport wakes waiter to redial after early close under host cap" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    accept_count = Ref(0)
    same_conn_second_request = Ref(false)
    first_body = fill(UInt8('x'), 4096)
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        accept_count[] += 1
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            _read_all_transport_body_bytes(req1.body)
            _write_response_bytes_to_conn!(conn1, req1; body_bytes = first_body)
            try
                req_maybe = HT.read_request(HT._ConnReader(conn1))
                same_conn_second_request[] = true
                _read_all_transport_body_bytes(req_maybe.body)
                _write_response_to_conn!(conn1, req_maybe; body_text = "unexpected")
            catch err
                if !(err isa EOFError || err isa SystemError || err isa Reseau.IOPoll.DeadlineExceededError || err isa Reseau.IOPoll.NetClosingError || err isa HT.ParseError || err isa HT.ProtocolError)
                    rethrow(err)
                end
            end
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        conn2 = NC.accept(listener)
        accept_count[] += 1
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            _read_all_transport_body_bytes(req2.body)
            _write_response_to_conn!(conn2, req2; body_text = "second-response", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 1, max_idle_total = 1, max_conns_per_host = 1)
    try
        req1 = HT.Request("GET", "/one"; host = address, body = HT.EmptyBody(), content_length = 0)
        res1 = HT.roundtrip!(transport, address, req1)
        @test res1.status == 200

        req2 = HT.Request("GET", "/two"; host = address, body = HT.EmptyBody(), content_length = 0)
        res2_task = errormonitor(Threads.@spawn HT.roundtrip!(transport, address, req2))

        _wait_for_transport_waiter!(transport, "http://$address")

        first_byte = Vector{UInt8}(undef, 1)
        @test HT.body_read!(res1.body, first_byte) == 1
        HT.body_close!(res1.body)

        res2 = fetch(res2_task)
        @test res2.status == 200
        @test String(_read_all_transport_body_bytes(res2.body)) == "second-response"
        _wait_task!(server_task)
        @test accept_count[] == 2
        @test !same_conn_second_request[]
        @test HT.idle_connection_count(transport) == 0
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport waiter honors request deadline under host cap" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    accept_count = Ref(0)
    second_request_seen = Ref(false)
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        accept_count[] += 1
        try
            req1 = HT.read_request(HT._ConnReader(conn))
            _read_all_transport_body_bytes(req1.body)
            _write_response_to_conn!(conn, req1; body_text = "first")
            try
                req2 = HT.read_request(HT._ConnReader(conn))
                second_request_seen[] = true
                _read_all_transport_body_bytes(req2.body)
            catch err
                if !(err isa EOFError || err isa SystemError || err isa Reseau.IOPoll.DeadlineExceededError || err isa Reseau.IOPoll.NetClosingError || err isa HT.ParseError || err isa HT.ProtocolError)
                    rethrow(err)
                end
            end
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 1, max_idle_total = 1, max_conns_per_host = 1)
    try
        req1 = HT.Request("GET", "/one"; host = address, body = HT.EmptyBody(), content_length = 0)
        res1 = HT.roundtrip!(transport, address, req1)
        @test res1.status == 200

        req2 = HT.Request("GET", "/two"; host = address, body = HT.EmptyBody(), content_length = 0)
        HT.set_deadline!(HT.get_request_context(req2), Int64(1))
        err = try
            HT.roundtrip!(transport, address, req2)
            nothing
        catch caught
            caught
        end
        @test err isa Reseau.IOPoll.DeadlineExceededError

        HT.body_close!(res1.body)
        _wait_task!(server_task)
        @test accept_count[] == 1
        @test !second_request_seen[]
        @test HT.idle_connection_count(transport) == 0
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport skips interim 1xx responses" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            request = HT.read_request(HT._ConnReader(conn))
            _read_all_transport_body_bytes(request.body)
            payload = collect(codeunits("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
            _write_all_tcp!(conn, payload)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    try
        req = HT.Request("POST", "/one"; host = address, body = HT.BytesBody(UInt8[0x78]), content_length = 1)
        res = HT.roundtrip!(transport, address, req)
        @test res.status == 200
        @test String(_read_all_transport_body_bytes(res.body)) == "ok"
        _wait_task!(server_task)
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport waits for 100-continue before sending body" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    body_requested = Channel{Nothing}(1)
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        reader = HT._ConnReader(conn)
        try
            request = HT.read_request(reader)
            @test !isready(body_requested)
            _write_all_tcp!(conn, collect(codeunits("HTTP/1.1 100 Continue\r\n\r\n")))
            @test String(_read_all_transport_body_bytes(request.body)) == "hello"
            take!(body_requested)
            _write_response_to_conn!(conn, request; body_text = "done", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    try
        headers = HT.Headers()
        HT.setheader(headers, "Expect", "100-continue")
        body_sent = Ref(false)
        body = HT.CallbackBody(
            dst -> begin
                body_sent[] && return 0
                put!(body_requested, nothing)
                bytes = collect(codeunits("hello"))
                copyto!(dst, 1, bytes, 1, length(bytes))
                body_sent[] = true
                return length(bytes)
            end,
            () -> nothing,
        )
        req = HT.Request("POST", "/continue"; host = address, headers = headers, body = body, content_length = 5)
        res = HT.roundtrip!(transport, address, req)
        @test res.status == 200
        @test String(_read_all_transport_body_bytes(res.body)) == "done"
        _wait_task!(server_task)
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport returns early final responses before upload completes" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    close_count = Ref(0)
    body_closed = Base.Event()
    stage = Ref(1)
    second_chunk_started = Channel{Nothing}(1)
    release_second_chunk = Channel{Nothing}(1)
    callback_body = HT.CallbackBody(
        dst -> begin
            if stage[] == 1
                bytes = collect(codeunits("hello"))
                copyto!(dst, 1, bytes, 1, length(bytes))
                stage[] = 2
                return length(bytes)
            end
            if stage[] == 2
                isready(second_chunk_started) || put!(second_chunk_started, nothing)
                take!(release_second_chunk)
                bytes = collect(codeunits("world"))
                copyto!(dst, 1, bytes, 1, length(bytes))
                stage[] = 3
                return length(bytes)
            end
            return 0
        end,
        () -> begin
            close_count[] += 1
            notify(body_closed)
            return nothing
        end,
    )
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            request = HT.read_request(HT._ConnReader(conn))
            take!(second_chunk_started)
            _write_response_bytes_to_conn!(conn, request; body_bytes = collect(codeunits("early")), close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    try
        req = HT.Request("POST", "/early"; host = address, body = callback_body, content_length = 10)
        res_task = errormonitor(Threads.@spawn HT.roundtrip!(transport, address, req))
        res = fetch(res_task)
        isready(release_second_chunk) || put!(release_second_chunk, nothing)
        wait(body_closed)
        @test res.status == 200
        @test String(_read_all_transport_body_bytes(res.body)) == "early"
        @test close_count[] == 1
        _wait_task!(server_task)
    finally
        isready(release_second_chunk) || put!(release_second_chunk, nothing)
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport closes request body after send" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    body_data = collect(codeunits("ping"))
    body_index = Ref(1)
    close_count = Ref(0)
    callback_body = HT.CallbackBody(
        dst -> begin
            idx = body_index[]
            idx > length(body_data) && return 0
            n = min(length(dst), length(body_data) - idx + 1)
            copyto!(dst, 1, body_data, idx, n)
            body_index[] += n
            return n
        end,
        () -> begin
            close_count[] += 1
            return nothing
        end,
    )
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            request = HT.read_request(HT._ConnReader(conn))
            @test String(_read_all_transport_body_bytes(request.body)) == "ping"
            _write_response_to_conn!(conn, request; body_text = "done", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    try
        req = HT.Request("POST", "/close"; host = address, body = callback_body, content_length = 4)
        res = HT.roundtrip!(transport, address, req)
        @test res.status == 200
        @test String(_read_all_transport_body_bytes(res.body)) == "done"
        _wait_task!(server_task)
        @test close_count[] == 1
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport redials after early close on bounded body" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    accept_count = Ref(0)
    paths = String[]
    same_conn_second_request = Ref(false)
    first_body = fill(UInt8('a'), 32 * 1024)
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        accept_count[] += 1
        try
            req1 = HT.read_request(HT._ConnReader(conn))
            push!(paths, req1.target)
            _read_all_transport_body_bytes(req1.body)
            _write_response_bytes_to_conn!(conn, req1; body_bytes = first_body)
            try
                req2 = HT.read_request(HT._ConnReader(conn))
                same_conn_second_request[] = true
                push!(paths, req2.target)
                _read_all_transport_body_bytes(req2.body)
                _write_response_to_conn!(conn, req2; body_text = "unexpected")
            catch err
                if !(err isa EOFError || err isa SystemError || err isa Reseau.IOPoll.DeadlineExceededError || err isa Reseau.IOPoll.NetClosingError || err isa HT.ParseError || err isa HT.ProtocolError)
                    rethrow(err)
                end
            end
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        conn2 = NC.accept(listener)
        accept_count[] += 1
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            push!(paths, req2.target)
            _read_all_transport_body_bytes(req2.body)
            _write_response_to_conn!(conn2, req2; body_text = "second", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    try
        req1 = HT.Request("GET", "/one"; host = address, body = HT.EmptyBody(), content_length = 0)
        res1 = HT.roundtrip!(transport, address, req1)
        first_byte = Vector{UInt8}(undef, 1)
        @test HT.body_read!(res1.body, first_byte) == 1
        HT.body_close!(res1.body)
        req2 = HT.Request("GET", "/two"; host = address, body = HT.EmptyBody(), content_length = 0)
        res2 = HT.roundtrip!(transport, address, req2)
        @test res2.status == 200
        @test String(_read_all_transport_body_bytes(res2.body)) == "second"
        _wait_task!(server_task)
        @test accept_count[] == 2
        @test !same_conn_second_request[]
        @test paths == ["/one", "/two"]
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport respects request Connection close" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    accept_count = Ref(0)
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:2
            conn = NC.accept(listener)
            accept_count[] += 1
            try
                request = HT.read_request(HT._ConnReader(conn))
                _read_all_transport_body_bytes(request.body)
                _write_response_to_conn!(conn, request; body_text = "ok")
                probe = Vector{UInt8}(undef, 1)
                @test readbytes!(conn, probe, 1; all = true) == 0
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    try
        headers = HT.Headers()
        HT.setheader(headers, "Connection", "close")
        req1 = HT.Request("GET", "/one"; host = address, headers = headers, body = HT.EmptyBody(), content_length = 0)
        res1 = HT.roundtrip!(transport, address, req1)
        @test String(_read_all_transport_body_bytes(res1.body)) == "ok"
        req2 = HT.Request("GET", "/two"; host = address, headers = headers, body = HT.EmptyBody(), content_length = 0)
        res2 = HT.roundtrip!(transport, address, req2)
        @test String(_read_all_transport_body_bytes(res2.body)) == "ok"
        _wait_task!(server_task)
        @test accept_count[] == 2
        @test HT.idle_connection_count(transport) == 0
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport does not reuse conn after early response close" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    accept_count = Ref(0)
    same_conn_second_request = Ref(false)
    first_body = fill(UInt8('x'), 4096)
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        accept_count[] += 1
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            _read_all_transport_body_bytes(req1.body)
            _write_response_bytes_to_conn!(conn1, req1; body_bytes = first_body)
            try
                req_maybe = HT.read_request(HT._ConnReader(conn1))
                same_conn_second_request[] = true
                _read_all_transport_body_bytes(req_maybe.body)
                _write_response_to_conn!(conn1, req_maybe; body_text = "unexpected")
            catch err
                if !(err isa EOFError || err isa SystemError || err isa Reseau.IOPoll.DeadlineExceededError || err isa Reseau.IOPoll.NetClosingError || err isa HT.ParseError || err isa HT.ProtocolError)
                    rethrow(err)
                end
            end
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        conn2 = NC.accept(listener)
        accept_count[] += 1
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            _read_all_transport_body_bytes(req2.body)
            _write_response_to_conn!(conn2, req2; body_text = "second-response", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    try
        req1 = HT.Request("GET", "/one"; host = address, body = HT.EmptyBody(), content_length = 0)
        res1 = HT.roundtrip!(transport, address, req1)
        first_byte = Vector{UInt8}(undef, 1)
        @test HT.body_read!(res1.body, first_byte) == 1
        HT.body_close!(res1.body)
        @test HT.idle_connection_count(transport) == 0

        req2 = HT.Request("GET", "/two"; host = address, body = HT.EmptyBody(), content_length = 0)
        res2 = HT.roundtrip!(transport, address, req2)
        @test res2.status == 200
        @test String(_read_all_transport_body_bytes(res2.body)) == "second-response"
        _wait_task!(server_task)
        @test accept_count[] == 2
        @test !same_conn_second_request[]
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport retries idempotent request on stale reused conn" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    accept_count = Ref(0)
    methods = String[]
    paths = String[]
    bodies = String[]
    first_conn_closed = Channel{Nothing}(1)
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        accept_count[] += 1
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            push!(methods, req1.method)
            push!(paths, req1.target)
            push!(bodies, String(_read_all_transport_body_bytes(req1.body)))
            _write_response_to_conn!(conn1, req1; body_text = "warmup")
        finally
            HTTP.@try_ignore NC.close(conn1)
            put!(first_conn_closed, nothing)
        end
        conn2 = NC.accept(listener)
        accept_count[] += 1
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            push!(methods, req2.method)
            push!(paths, req2.target)
            push!(bodies, String(_read_all_transport_body_bytes(req2.body)))
            _write_response_to_conn!(conn2, req2; body_text = "retried", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    try
        req1 = HT.Request("GET", "/warmup"; host = address, body = HT.EmptyBody(), content_length = 0)
        res1 = HT.roundtrip!(transport, address, req1)
        @test String(_read_all_transport_body_bytes(res1.body)) == "warmup"
        take!(first_conn_closed)
        req2 = HT.Request(
            "QUERY",
            "/retry";
            host = address,
            body = HT.BytesBody(collect(codeunits("select=1"))),
            content_length = 8,
        )
        res2 = HT.roundtrip!(transport, address, req2)
        @test res2.status == 200
        @test String(_read_all_transport_body_bytes(res2.body)) == "retried"
        _wait_task!(server_task)
        @test accept_count[] == 2
        @test methods == ["GET", "QUERY"]
        @test paths == ["/warmup", "/retry"]
        @test bodies == ["", "select=1"]
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport force-fresh acquire replaces reused conns" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address = ND.join_host_port("127.0.0.1", Int((NC.addr(listener)::NC.SocketAddrV4).port))
    accepted = Channel{NC.Conn}(3)
    server_task = Threads.@spawn begin
        for _ in 1:3
            put!(accepted, NC.accept(listener))
        end
        return nothing
    end
    transport = HT.Transport(max_idle_per_host = 1, max_idle_total = 1, max_conns_per_host = 1)
    plan = HT._proxy_plan(transport.proxy, false, address)
    server_conns = NC.Conn[]
    first_conn = nothing
    fresh_conn = nothing
    replacement_conn = nothing
    try
        first_conn = HT._acquire_conn!(transport, plan, address, false, nothing)
        push!(server_conns, take!(accepted))

        acquire_task = Threads.@spawn try
            HT._acquire_conn!(
                transport,
                plan,
                address,
                false,
                nothing;
                force_fresh = true,
            )
        finally
            lock(transport.lock)
            try
                notify(transport.waiter_condition)
            finally
                unlock(transport.lock)
            end
        end
        queued = _wait_for_transport_waiter_or_task!(transport, plan.pool_key, acquire_task)
        if !queued
            unexpected_conn = fetch(acquire_task)
            HT._close_owned_conn!(transport, unexpected_conn::HT.Conn)
        end
        @test queued

        # The normal handoff path offers `first_conn` to the waiter. A
        # force-fresh acquire must transfer that counted slot to a fresh dial.
        HT._put_idle_conn!(transport, first_conn::HT.Conn)
        first_conn = nothing
        fresh_conn = fetch(acquire_task)
        @test !(fresh_conn::HT.Conn).reused
        @test lock(transport.lock) do
            HT._conn_slots_locked(transport, plan.pool_key) == 1 && isempty(transport.waiters)
        end
        push!(server_conns, take!(accepted))
        @test length(server_conns) == 2

        # Exercise the other acquisition branch. This time the force-fresh
        # caller finds a reused connection already parked in the idle pool.
        HT._put_idle_conn!(transport, fresh_conn::HT.Conn)
        fresh_conn = nothing
        replacement_conn = HT._acquire_conn!(
            transport,
            plan,
            address,
            false,
            nothing,
            Int64(1);
            force_fresh = true,
        )
        @test !(replacement_conn::HT.Conn).reused
        @test lock(transport.lock) do
            HT._conn_slots_locked(transport, plan.pool_key) == 1 && isempty(transport.waiters)
        end
        push!(server_conns, take!(accepted))
        @test length(server_conns) == 3
        _wait_task!(server_task)
    finally
        first_conn === nothing || HT._close_owned_conn!(transport, first_conn::HT.Conn)
        fresh_conn === nothing || HT._close_owned_conn!(transport, fresh_conn::HT.Conn)
        replacement_conn === nothing || HT._close_owned_conn!(transport, replacement_conn::HT.Conn)
        for conn in server_conns
            HTTP.@try_ignore NC.close(conn)
        end
        close(transport)
        HTTP.@try_ignore NC.close(listener)
        HTTP.@try_ignore wait(server_task)
    end
end

@testset "HTTP client transport keeps a fresh idle conn while evicting an expired peer" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address = ND.join_host_port("127.0.0.1", Int((NC.addr(listener)::NC.SocketAddrV4).port))
    accepted = Channel{NC.Conn}(2)
    server_task = Threads.@spawn begin
        for _ in 1:2
            put!(accepted, NC.accept(listener))
        end
        return nothing
    end
    transport = HT.Transport(
        max_idle_per_host = 2,
        max_idle_total = 2,
        max_conns_per_host = 2,
        idle_timeout_ns = 1,
    )
    plan = HT._proxy_plan(transport.proxy, false, address)
    stale_conn = nothing
    fresh_conn = nothing
    acquired_conn = nothing
    server_conns = NC.Conn[]
    try
        stale_conn = HT._acquire_conn!(transport, plan, address, false, nothing)
        push!(server_conns, take!(accepted))
        fresh_conn = HT._acquire_conn!(transport, plan, address, false, nothing)
        push!(server_conns, take!(accepted))
        _wait_task!(server_task)

        HT._put_idle_conn!(transport, stale_conn::HT.Conn)
        HT._put_idle_conn!(transport, fresh_conn::HT.Conn)
        (stale_conn::HT.Conn).last_used_ns = 0
        (fresh_conn::HT.Conn).last_used_ns = typemax(Int64)

        acquired_conn = HT._acquire_conn!(transport, plan, address, false, nothing)
        @test acquired_conn === fresh_conn
        @test HT._conn_closed(stale_conn::HT.Conn)
        @test (@atomic transport.idle_total) == 0
        @test lock(transport.lock) do
            HT._conn_slots_locked(transport, plan.pool_key) == 1
        end

        HT._close_owned_conn!(transport, acquired_conn::HT.Conn)
        acquired_conn = nothing
        fresh_conn = nothing
        @test lock(transport.lock) do
            HT._conn_slots_locked(transport, plan.pool_key) == 0
        end
    finally
        acquired_conn === nothing || HT._close_owned_conn!(transport, acquired_conn::HT.Conn)
        fresh_conn === nothing || HT._close_owned_conn!(transport, fresh_conn::HT.Conn)
        stale_conn === nothing || HT._close_owned_conn!(transport, stale_conn::HT.Conn)
        close(transport)
        for conn in server_conns
            HTTP.@try_ignore NC.close(conn)
        end
        HTTP.@try_ignore NC.close(listener)
        HTTP.@try_ignore wait(server_task)
    end
end

@testset "HTTP client transport releases a slot after an earlier raw close" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address = ND.join_host_port("127.0.0.1", Int((NC.addr(listener)::NC.SocketAddrV4).port))
    accepted = Channel{NC.Conn}(1)
    server_task = Threads.@spawn put!(accepted, NC.accept(listener))
    transport = HT.Transport(max_idle_per_host = 1, max_idle_total = 1, max_conns_per_host = 1)
    plan = HT._proxy_plan(transport.proxy, false, address)
    conn = nothing
    server_conn = nothing
    try
        conn = HT._acquire_conn!(transport, plan, address, false, nothing)
        server_conn = take!(accepted)
        _wait_task!(server_task)
        @test HT._close_conn!(conn::HT.Conn)
        HT._close_owned_conn!(transport, conn::HT.Conn)
        conn = nothing
        @test lock(transport.lock) do
            HT._conn_slots_locked(transport, plan.pool_key) == 0
        end
    finally
        conn === nothing || HT._close_owned_conn!(transport, conn::HT.Conn)
        close(transport)
        server_conn === nothing || HTTP.@try_ignore NC.close(server_conn::NC.Conn)
        HTTP.@try_ignore NC.close(listener)
        HTTP.@try_ignore wait(server_task)
    end
end

@testset "HTTP client transport retries stale PUT and DELETE requests" begin
    for (method, payload) in (("PUT", "payload"), ("DELETE", ""))
        listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
        address = ND.join_host_port("127.0.0.1", Int((NC.addr(listener)::NC.SocketAddrV4).port))
        first_conn_closed = Channel{Nothing}(1)
        seen = Tuple{String,String}[]
        server_task = Threads.@spawn begin
            conn1 = NC.accept(listener)
            try
                warmup = HT.read_request(HT._ConnReader(conn1))
                push!(seen, (warmup.method, String(_read_all_transport_body_bytes(warmup.body))))
                _write_response_to_conn!(conn1, warmup; body_text = "warmup")
            finally
                HTTP.@try_ignore NC.close(conn1)
                put!(first_conn_closed, nothing)
            end

            conn2 = NC.accept(listener)
            try
                retried = HT.read_request(HT._ConnReader(conn2))
                push!(seen, (retried.method, String(_read_all_transport_body_bytes(retried.body))))
                _write_response_to_conn!(conn2, retried; body_text = "recovered", close_conn = true)
            finally
                HTTP.@try_ignore NC.close(conn2)
            end
            return nothing
        end
        transport = HT.Transport(max_idle_per_host = 1, max_idle_total = 1)
        try
            warmup = HT.Request("GET", "/warmup"; host = address, body = HT.EmptyBody(), content_length = 0)
            warmup_response = HT.roundtrip!(transport, address, warmup)
            @test String(_read_all_transport_body_bytes(warmup_response.body)) == "warmup"
            take!(first_conn_closed)

            body = isempty(payload) ? HT.EmptyBody() : HT.BytesBody(collect(codeunits(payload)))
            request = HT.Request(method, "/retry"; host = address, body = body, content_length = ncodeunits(payload))
            response = HT.roundtrip!(transport, address, request)
            @test String(_read_all_transport_body_bytes(response.body)) == "recovered"
            _wait_task!(server_task)
            @test seen == [("GET", ""), (method, payload)]
        finally
            close(transport)
            HTTP.@try_ignore NC.close(listener)
            HTTP.@try_ignore wait(server_task)
        end
    end
end

end

@testset "HTTP client transport treats not-pollable reused errors as retryable" begin
    @test HT._retryable_method("QUERY")
    @test HT._retryable_request(HT.Request("PUT", "/"; body = HT.BytesBody(UInt8[0x78]), content_length = 1))
    @test HT._retryable_request(HT.Request("DELETE", "/"; body = HT.EmptyBody(), content_length = 0))
    @test HT._retryable_reused_conn_error(Reseau.IOPoll.NotPollableError())
end

@testset "HTTP client transport types TLS dial failures as handshake errors (#1353)" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address = ND.join_host_port("127.0.0.1", Int((NC.addr(listener)::NC.SocketAddrV4).port))
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            # Not a TLS server: answer the ClientHello with plaintext so the
            # client's record parsing fails during the handshake.
            _write_all_tcp!(conn, collect(codeunits("HTTP/1.1 400 Bad Request\r\ncontent-length: 0\r\n\r\n")))
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    transport = HT.Transport(tls_config = Reseau.TLS.Config(verify_peer = false, verify_hostname = true))
    try
        req = HT.Request("GET", "/handshake"; host = address, body = HT.EmptyBody(), content_length = 0)
        err = try
            HT.roundtrip!(transport, address, req; secure = true, server_name = "localhost")
            nothing
        catch e
            e
        end
        @test err isa HT.TLSHandshakeError
        @test (err::HT.TLSHandshakeError).cause isa Reseau.TLS.TLSError
        _wait_task!(server_task)
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client transport classifies TLS-wrapped reused errors by cause (#1353)" begin
    # A dead reused TLS connection surfaces reads/writes as TLSError wrapping
    # the underlying transport failure (e.g. an RST as SystemError); classify
    # by the cause so the reused-connection retry engages.
    @test HT._retryable_reused_conn_error(
        Reseau.TLS.TLSError("read", Int32(0), "unexpected TLS failure", SystemError("read", 0)),
    )
    @test HT._retryable_reused_conn_error(
        Reseau.TLS.TLSError("read", Int32(0), "unexpected EOF", EOFError()),
    )
    # Reproduce Reseau's private mid-record EOF sentinel. Production code must
    # classify the public TLSError message instead of naming this private type.
    unexpected_eof_cause = ErrorException("opaque TLS record EOF cause")
    @test HT._retryable_reused_conn_error(
        Reseau.TLS.TLSError("read", Int32(0), "unexpected EOF", unexpected_eof_cause),
    )
    # Causeless TLS protocol failures and deadline expiries are not dead-conn
    # signatures.
    @test !HT._retryable_reused_conn_error(
        Reseau.TLS.TLSError("read", Int32(0), "bad record mac", nothing),
    )
    @test !HT._retryable_reused_conn_error(
        Reseau.TLS.TLSError("read", Int32(0), "i/o timeout", Reseau.IOPoll.DeadlineExceededError()),
    )
end

@testset "HTTP public client APIs wrap established TLS record truncation" begin
    cert_file = joinpath(@__DIR__, "resources", "unittests.crt")
    key_file = joinpath(@__DIR__, "resources", "unittests.key")
    listener = TL.listen(
        "tcp",
        "127.0.0.1:0",
        TL.Config(
            verify_peer = false,
            cert_file = cert_file,
            key_file = key_file,
        );
        backlog = 8,
    )
    port = Int((TL.addr(listener)::NC.SocketAddrV4).port)
    address = ND.join_host_port("localhost", port)
    partial_record = UInt8[0x17, 0x03, 0x03, 0x00, 0x10, 0x00]
    server_task = Threads.@spawn begin
        for _ in 1:4
            tls_conn = nothing
            try
                tls_conn = TL.accept(listener)
                TL.handshake!(tls_conn::TL.Conn)
                request = HT.read_request(HT._ConnReader(tls_conn::TL.Conn))
                if startswith(request.target, "/body")
                    write(tls_conn::TL.Conn, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n")
                    flush(tls_conn::TL.Conn)
                end
                tcp = TL.net_conn(tls_conn::TL.Conn)::NC.Conn
                _write_all_tcp!(tcp, partial_record)
                HTTP.@try_ignore NC.close(tcp)
            finally
                tls_conn === nothing || HTTP.@try_ignore TL.close(tls_conn::TL.Conn)
            end
        end
        return nothing
    end
    transport = HT.Transport(
        tls_config = TL.Config(verify_peer = false, verify_hostname = false),
        max_idle_per_host = 1,
        max_idle_total = 1,
    )
    client = HT.Client(transport = transport, cookiejar = nothing, prefer_http2 = false)
    try
        for api in (:roundtrip, :open), phase in (:head, :body)
            target = "/$(phase)-$(api)"
            err = if api === :roundtrip
                response = nothing
                try
                    request = HT.Request("GET", target; host = address, body = HT.EmptyBody(), content_length = 0)
                    response = HT.roundtrip!(transport, address, request; secure = true, server_name = "localhost")
                    phase === :body && HT.body_read!(response.body, Vector{UInt8}(undef, 5))
                    nothing
                catch caught
                    caught
                finally
                    response === nothing || HTTP.@try_ignore HT.body_close!(response.body)
                end
            else
                stream = HT.open(
                    :GET,
                    "https://$(address)$(target)";
                    client = client,
                    protocol = :h1,
                    retry = false,
                )
                try
                    HT.startread(stream)
                    phase === :body && read(stream)
                    nothing
                catch caught
                    caught
                finally
                    close(stream)
                end
            end
            @test err isa HT.TLSTransportError
            @test (err::HT.TLSTransportError).cause isa TL.TLSError
        end
        _wait_task!(server_task)
    finally
        close(client)
        HTTP.@try_ignore TL.close(listener)
        HTTP.@try_ignore wait(server_task)
    end
end

@testset "HTTP client transport survives a fully poisoned idle pool (#1353)" begin
    # Pooled connections can die in correlated batches (dialed together, then
    # discarded together by the peer while parked). The reused-connection retry
    # must keep retrying while failures land on reused connections — through
    # every dead pooled connection — until it reaches a fresh dial, instead of
    # giving up after a single retry.
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    accept_count = Ref(0)
    paths = String[]
    both_warmups_read = Channel{Nothing}(2)
    warmup_conns_closed = Channel{Nothing}(1)
    server_task = errormonitor(Threads.@spawn begin
        # Hold both warmup responses until both requests have arrived so the
        # client provably opens two separate connections.
        conn1 = NC.accept(listener)
        accept_count[] += 1
        req1 = HT.read_request(HT._ConnReader(conn1))
        push!(paths, req1.target)
        put!(both_warmups_read, nothing)
        conn2 = NC.accept(listener)
        accept_count[] += 1
        req2 = HT.read_request(HT._ConnReader(conn2))
        push!(paths, req2.target)
        put!(both_warmups_read, nothing)
        # Keep-alive responses so the client parks both connections.
        _write_response_to_conn!(conn1, req1; body_text = "warmup1")
        _write_response_to_conn!(conn2, req2; body_text = "warmup2")
        # Correlated death: discard both parked connections at once.
        take!(warmup_conns_closed)
        HTTP.@try_ignore NC.close(conn1)
        HTTP.@try_ignore NC.close(conn2)
        conn3 = NC.accept(listener)
        accept_count[] += 1
        try
            req3 = HT.read_request(HT._ConnReader(conn3))
            push!(paths, req3.target)
            _write_response_to_conn!(conn3, req3; body_text = "recovered", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn3)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    try
        warmup1 = errormonitor(Threads.@spawn begin
            req = HT.Request("GET", "/warmup1"; host = address, body = HT.EmptyBody(), content_length = 0)
            res = HT.roundtrip!(transport, address, req)
            String(_read_all_transport_body_bytes(res.body))
        end)
        warmup2 = errormonitor(Threads.@spawn begin
            take!(both_warmups_read)  # conn1's request is in: this dials conn2
            req = HT.Request("GET", "/warmup2"; host = address, body = HT.EmptyBody(), content_length = 0)
            res = HT.roundtrip!(transport, address, req)
            String(_read_all_transport_body_bytes(res.body))
        end)
        @test fetch(warmup1) == "warmup1"
        @test fetch(warmup2) == "warmup2"
        take!(both_warmups_read)
        put!(warmup_conns_closed, nothing)
        # Both parked connections are now dead; the FINs may take a moment to
        # be delivered, but reads observe them either way once we try to reuse.
        req = HT.Request("GET", "/poisoned"; host = address, body = HT.EmptyBody(), content_length = 0)
        res = HT.roundtrip!(transport, address, req)
        @test res.status == 200
        @test String(_read_all_transport_body_bytes(res.body)) == "recovered"
        _wait_task!(server_task)
        @test accept_count[] == 3
        @test paths == ["/warmup1", "/warmup2", "/poisoned"]
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

if _http_windows_ci()
    @testset "HTTP client transport forces a fresh final retry during concurrent handoff" begin
        @test_skip true
    end
else
@testset "HTTP client transport forces a fresh final retry during concurrent handoff" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address = ND.join_host_port("127.0.0.1", Int((NC.addr(listener)::NC.SocketAddrV4).port))
    first_request_read = Channel{Nothing}(1)
    blocker_parked = Channel{Nothing}(1)
    accept_count = Ref(0)
    paths = String[]
    server_task = Threads.@spawn begin
        conn_a = NC.accept(listener)
        accept_count[] += 1
        conn_b = nothing
        try
            warmup = HT.read_request(HT._ConnReader(conn_a))
            push!(paths, warmup.target)
            _read_all_transport_body_bytes(warmup.body)
            put!(first_request_read, nothing)

            conn_b = NC.accept(listener)
            accept_count[] += 1
            blocker = HT.read_request(HT._ConnReader(conn_b::NC.Conn))
            push!(paths, blocker.target)
            _read_all_transport_body_bytes(blocker.body)

            # Return A first so it becomes the victim's reused connection.
            _write_response_to_conn!(conn_a, warmup; body_text = "warmup")
            victim = HT.read_request(HT._ConnReader(conn_a))
            push!(paths, victim.target)
            _read_all_transport_body_bytes(victim.body)

            # Return B while the victim is blocked on A. After B is parked,
            # close both connections before allowing the victim to retry.
            _write_response_to_conn!(conn_b::NC.Conn, blocker; body_text = "blocker")
            take!(blocker_parked)
            HTTP.@try_ignore NC.close(conn_b::NC.Conn)
            conn_b = nothing
            HTTP.@try_ignore NC.close(conn_a)

            conn_c = NC.accept(listener)
            accept_count[] += 1
            try
                recovered = HT.read_request(HT._ConnReader(conn_c))
                push!(paths, recovered.target)
                _read_all_transport_body_bytes(recovered.body)
                _write_response_to_conn!(conn_c, recovered; body_text = "recovered", close_conn = true)
            finally
                HTTP.@try_ignore NC.close(conn_c)
            end
        finally
            conn_b === nothing || HTTP.@try_ignore NC.close(conn_b::NC.Conn)
            HTTP.@try_ignore NC.close(conn_a)
        end
        return nothing
    end
    transport = HT.Transport(
        max_idle_per_host = 1,
        max_idle_total = 2,
        max_conns_per_host = 2,
    )
    blocker_task = nothing
    try
        warmup_task = errormonitor(Threads.@spawn begin
            request = HT.Request("GET", "/warmup"; host = address, body = HT.EmptyBody(), content_length = 0)
            response = HT.roundtrip!(transport, address, request)
            return String(_read_all_transport_body_bytes(response.body))
        end)
        take!(first_request_read)
        blocker_task = errormonitor(Threads.@spawn begin
            request = HT.Request("GET", "/blocker"; host = address, body = HT.EmptyBody(), content_length = 0)
            response = HT.roundtrip!(transport, address, request)
            body = String(_read_all_transport_body_bytes(response.body))
            put!(blocker_parked, nothing)
            return body
        end)
        @test fetch(warmup_task) == "warmup"

        victim = HT.Request("GET", "/victim"; host = address, body = HT.EmptyBody(), content_length = 0)
        response = HT.roundtrip!(transport, address, victim)
        @test String(_read_all_transport_body_bytes(response.body)) == "recovered"
        @test fetch(blocker_task::Task) == "blocker"
        _wait_task!(server_task)
        @test accept_count[] == 3
        @test paths == ["/warmup", "/blocker", "/victim", "/victim"]
    finally
        isready(blocker_parked) || put!(blocker_parked, nothing)
        close(transport)
        HTTP.@try_ignore NC.close(listener)
        HTTP.@try_ignore wait(server_task)
    end
end
end

@testset "close_idle_connections! clears the default and per-client pools" begin
    server = HTTP.serve!("127.0.0.1", 0) do req
        return HTTP.Response(200, "ok")
    end
    try
        url = "http://127.0.0.1:$(HTTP.port(server))/"
        # A default-client GET leaves a reusable idle connection in the pool.
        HTTP.get(url)
        client = HTTP._DEFAULT_CLIENT[]
        @test client !== nothing
        @test HT.idle_connection_count(client.transport) >= 1
        # No-arg form closes the default client's idle connections.
        @test HTTP.close_idle_connections!() === nothing
        @test HT.idle_connection_count(client.transport) == 0
        # The Client overload delegates to its transport.
        @test HTTP.close_idle_connections!(client) === nothing
    finally
        close(server)
    end
end

@testset "local_addr binds outbound connections to a source IP (#834)" begin
    # Normalizer: IP-literal strings become ephemeral-port endpoints; ready-made
    # SocketEndpoints pass through; junk is rejected (Go net.Dialer.LocalAddr model).
    n = HT._normalize_local_addr
    @test n(nothing) === nothing
    a4 = n("127.0.0.1")
    @test a4 isa NC.SocketAddrV4 && a4.ip == (0x7f, 0x00, 0x00, 0x01) && a4.port == 0x0000
    a6 = n("::1")
    @test a6 isa NC.SocketAddrV6 && a6.port == 0x0000
    fixed = NC.SocketAddrV4((10, 0, 0, 1), 5555)
    @test n(fixed) === fixed
    @test_throws ArgumentError n("not-an-ip")
    @test_throws ArgumentError n("")
    @test_throws ArgumentError n(12345)

    server = HTTP.serve!("127.0.0.1", 0) do req
        return HTTP.Response(200, "bound")
    end
    try
        url = "http://127.0.0.1:$(HTTP.port(server))/"

        # Client-level binding to a valid local source succeeds.
        client = HTTP.Client(local_addr = "127.0.0.1")
        resp = HTTP.get(url; client = client)
        @test resp.status == 200
        @test String(resp.body) == "bound"

        # Transport-level binding is the canonical form and behaves identically.
        tclient = HTTP.Client(transport = HTTP.Transport(local_addr = "127.0.0.1"))
        @test HTTP.get(url; client = tclient).status == 200

        # Binding to an address not assigned to any interface must fail at bind()
        # (EADDRNOTAVAIL) — proof the source address is actually applied, not ignored.
        @test_throws Exception HTTP.get(
            url;
            client = HTTP.Client(local_addr = "203.0.113.7"),  # TEST-NET-3, never local
            retry = false,
            connect_timeout = 5,
        )

        # local_addr is ambiguous alongside an explicit transport.
        @test_throws ArgumentError HTTP.Client(transport = HTTP.Transport(), local_addr = "127.0.0.1")
    finally
        HTTP.forceclose(server)
        wait(server)
    end
end
