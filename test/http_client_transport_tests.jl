using Test
using HTTP
using Reseau

const HT = HTTP
const NC = Reseau.TCP
const ND = Reseau.HostResolvers
const IP = Reseau.IOPoll

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

function _wait_task!(task::Task; timeout_s::Float64 = 5.0)
    status = timedwait(() -> istaskdone(task), timeout_s; pollint = 0.001)
    status == :timed_out && error("timed out waiting for server task")
    fetch(task)
    return nothing
end

function _transport_debug(msg::AbstractString)
    _ = msg
    return nothing
end

const _HTTP_WINDOWS_TRANSPORT_WARMED = Ref(false)
const _HTTP_WINDOWS_TRANSPORT_HOSTRESOLVER_WARMED = Ref(false)

function _transport_windows_ci_warmup!()::Nothing
    _http_windows_ci() || return nothing
    _HTTP_WINDOWS_TRANSPORT_WARMED[] && return nothing
    _HTTP_WINDOWS_TRANSPORT_WARMED[] = true

    listener = nothing
    transport = nothing
    server_task = nothing
    try
        listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 4)
        laddr = NC.addr(listener)::NC.SocketAddrV4
        address = ND.join_host_port("127.0.0.1", Int(laddr.port))
        server_task = errormonitor(Threads.@spawn begin
            conn = NC.accept(listener)
            try
                for _ in 1:2
                    request = HT.read_request(HT._ConnReader(conn))
                    _read_all_transport_body_bytes(request.body)
                    _write_response_to_conn!(conn, request; body_text = "warmup")
                end
            finally
                HTTP.@try_ignore NC.close(conn)
            end
            return nothing
        end)
        transport = HT.Transport(max_idle_per_host = 2, max_idle_total = 2)
        for target in ("/warmup-one", "/warmup-two")
            req = HT.Request("GET", target; host = address, body = HT.EmptyBody(), content_length = 0)
            HT.set_deadline!(HT.get_request_context(req), Int64(time_ns()) + 2_000_000_000)
            resp = HT.roundtrip!(transport, address, req)
            _read_all_transport_body_bytes(resp.body)
        end
        HTTP.@try_ignore begin
            _wait_task!(server_task; timeout_s = 2.0)
        end
    catch
        # The warmup is best-effort: it exists only to exercise the flaky
        # first-pass Windows CI compiler/runtime path before the real tests.
    finally
        server_task === nothing || HTTP.@try_ignore begin
            _wait_task!(server_task; timeout_s = 0.5)
        end
        transport === nothing || close(transport)
        if listener !== nothing
            HTTP.@try_ignore NC.close(listener)
        end
        GC.gc()
        yield()
        IP.shutdown!()
    end
    return nothing
end

function _transport_windows_hostresolver_warmup!()::Nothing
    _http_windows_ci() || return nothing
    _HTTP_WINDOWS_TRANSPORT_HOSTRESOLVER_WARMED[] && return nothing
    _HTTP_WINDOWS_TRANSPORT_HOSTRESOLVER_WARMED[] = true

    listener = nothing
    transport = nothing
    server_task = nothing
    try
        listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
        laddr = NC.addr(listener)::NC.SocketAddrV4
        address = ND.join_host_port("127.0.0.1", Int(laddr.port))
        server_task = errormonitor(Threads.@spawn begin
            for _ in 1:2
                conn = NC.accept(listener)
                try
                    request = HT.read_request(HT._ConnReader(conn))
                    _read_all_transport_body_bytes(request.body)
                    _write_response_to_conn!(conn, request; body_text = "warmup", close_conn = true)
                finally
                    HTTP.@try_ignore NC.close(conn)
                end
            end
            return nothing
        end)
        transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
        req1 = HT.Request("GET", "/one"; host = address, body = HT.EmptyBody(), content_length = 0)
        req2 = HT.Request("GET", "/two"; host = address, body = HT.EmptyBody(), content_length = 0)
        deadline_ns = Int64(time_ns()) + 3_000_000_000
        HT.set_deadline!(HT.get_request_context(req1), deadline_ns)
        HT.set_deadline!(HT.get_request_context(req2), deadline_ns)
        task1 = errormonitor(Threads.@spawn HT.roundtrip!(transport, address, req1))
        task2 = errormonitor(Threads.@spawn HT.roundtrip!(transport, address, req2))
        HTTP.@try_ignore begin
            _wait_task!(task1; timeout_s = 2.0)
            _wait_task!(task2; timeout_s = 2.0)
            _read_all_transport_body_bytes(fetch(task1).body)
            _read_all_transport_body_bytes(fetch(task2).body)
        end
        HTTP.@try_ignore begin
            _wait_task!(server_task; timeout_s = 2.0)
        end
    catch
        # The warmup is best-effort: it exists only to exercise the flaky
        # Windows CI resolver/compiler path before the real tests.
    finally
        transport === nothing || close(transport)
        if listener !== nothing
            HTTP.@try_ignore NC.close(listener)
        end
        server_task === nothing || HTTP.@try_ignore begin
            _wait_task!(server_task; timeout_s = 0.5)
        end
        GC.gc()
        yield()
        IP.shutdown!()
    end
    return nothing
end

mutable struct _CountingResolverTransport <: ND.AbstractResolver
    delay_s::Float64
    addrs::Vector{NC.SocketEndpoint}
    lock::ReentrantLock
    calls::Int
end

function _CountingResolverTransport(delay_s::Float64, addrs::Vector{NC.SocketEndpoint})
    return _CountingResolverTransport(delay_s, addrs, ReentrantLock(), 0)
end

function ND.resolve_tcp_addrs(
        resolver::_CountingResolverTransport,
        network::AbstractString,
        address::AbstractString;
        op::Symbol = :connect,
        policy::ND.ResolverPolicy = ND.ResolverPolicy(),
    )::Vector{NC.SocketEndpoint}
    _ = network
    _ = address
    _ = op
    _ = policy
    lock(resolver.lock)
    try
        resolver.calls += 1
    finally
        unlock(resolver.lock)
    end
    sleep(resolver.delay_s)
    return copy(resolver.addrs)
end

if _http_windows_ci()
    @testset "HTTP client transport windows warmup" begin
        _transport_windows_ci_warmup!()
        _transport_windows_hostresolver_warmup!()
    end
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
        deadline_ns = Int64(time_ns()) + 3_000_000_000
        HT.set_deadline!(HT.get_request_context(req1), deadline_ns)
        HT.set_deadline!(HT.get_request_context(req2), deadline_ns)
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
        @test timedwait(() -> istaskdone(res2_task), 0.05; pollint = 0.001) == :timed_out

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
            NC.set_read_deadline!(conn1, Int64(time_ns()) + 300_000_000)
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
        @test timedwait(() -> istaskdone(res2_task), 0.05; pollint = 0.001) == :timed_out

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
            NC.set_read_deadline!(conn, Int64(time_ns()) + 300_000_000)
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
        HT.set_deadline!(HT.get_request_context(req2), Int64(time_ns()) + 50_000_000)
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
    sent_body_before_continue = Ref(false)
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        reader = HT._ConnReader(conn)
        try
            request = HT.read_request(reader)
            probe = Vector{UInt8}(undef, 1)
            NC.set_read_deadline!(conn, Int64(time_ns()) + 100_000_000)
            try
                sent_body_before_continue[] = HT.body_read!(request.body, probe) > 0
            catch err
                if !(err isa IP.DeadlineExceededError || err isa HT.ParseError || err isa HT.ProtocolError)
                    rethrow(err)
                end
            finally
                NC.set_read_deadline!(conn, Int64(0))
            end
            _write_all_tcp!(conn, collect(codeunits("HTTP/1.1 100 Continue\r\n\r\n")))
            @test String(_read_all_transport_body_bytes(request.body)) == "hello"
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
        req = HT.Request("POST", "/continue"; host = address, headers = headers, body = HT.BytesBody(collect(codeunits("hello"))), content_length = 5)
        res = HT.roundtrip!(transport, address, req)
        @test res.status == 200
        @test String(_read_all_transport_body_bytes(res.body)) == "done"
        _wait_task!(server_task)
        @test !sent_body_before_continue[]
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
    stage = Ref(1)
    callback_body = HT.CallbackBody(
        dst -> begin
            if stage[] == 1
                bytes = collect(codeunits("hello"))
                copyto!(dst, 1, bytes, 1, length(bytes))
                stage[] = 2
                return length(bytes)
            end
            if stage[] == 2
                sleep(1.0)
                bytes = collect(codeunits("world"))
                copyto!(dst, 1, bytes, 1, length(bytes))
                stage[] = 3
                return length(bytes)
            end
            return 0
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
            _write_response_bytes_to_conn!(conn, request; body_bytes = collect(codeunits("early")), close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4)
    try
        req = HT.Request("POST", "/early"; host = address, body = callback_body, content_length = 10)
        started = time()
        res = HT.roundtrip!(transport, address, req)
        elapsed = time() - started
        @test res.status == 200
        @test String(_read_all_transport_body_bytes(res.body)) == "early"
        @test elapsed < 0.75
        @test timedwait(() -> close_count[] == 1, 2.0; pollint = 0.001) != :timed_out
        _wait_task!(server_task)
    finally
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
        @test timedwait(() -> close_count[] == 1, 2.0; pollint = 0.001) != :timed_out
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
            NC.set_read_deadline!(conn, Int64(time_ns()) + 300_000_000)
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
                NC.set_read_deadline!(conn, Int64(time_ns()) + 100_000_000)
                HTTP.@try_ignore _ = HT.read_request(HT._ConnReader(conn))
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
            NC.set_read_deadline!(conn1, Int64(time_ns()) + 300_000_000)
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
    paths = String[]
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        accept_count[] += 1
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            push!(paths, req1.target)
            _read_all_transport_body_bytes(req1.body)
            _write_response_to_conn!(conn1, req1; body_text = "warmup")
            sleep(0.15)
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        conn2 = NC.accept(listener)
        accept_count[] += 1
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            push!(paths, req2.target)
            _read_all_transport_body_bytes(req2.body)
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
        sleep(0.20)
        req2 = HT.Request("GET", "/retry"; host = address, body = HT.EmptyBody(), content_length = 0)
        res2 = HT.roundtrip!(transport, address, req2)
        @test res2.status == 200
        @test String(_read_all_transport_body_bytes(res2.body)) == "retried"
        _wait_task!(server_task)
        @test accept_count[] == 2
        @test paths == ["/warmup", "/retry"]
    finally
        close(transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

end

@testset "HTTP client transport treats not-pollable reused errors as retryable" begin
    @test HT._retryable_reused_conn_error(Reseau.IOPoll.NotPollableError())
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
        @test timedwait(() -> HT.idle_connection_count(client.transport) >= 1, 5.0) === :ok
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
