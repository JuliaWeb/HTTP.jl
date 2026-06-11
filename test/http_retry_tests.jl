using Test
using HTTP
using Reseau

const HT = HTTP
const NC = Reseau.TCP
const ND = Reseau.HostResolvers

function _read_all_body_bytes_retry(body::HT.AbstractBody)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 32)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
end

function _write_all_tcp_retry!(conn::NC.Conn, bytes::Vector{UInt8})::Nothing
    total = 0
    while total < length(bytes)
        n = write(conn, bytes[(total + 1):end])
        n > 0 || error("expected write progress")
        total += n
    end
    return nothing
end

function _send_response_retry!(
        conn::NC.Conn,
        request::HT.Request;
        status::Int,
        reason::String,
        body_text::String = "",
        headers::HT.Headers = HT.Headers(),
        close_conn::Bool = true,
    )::Nothing
    payload = collect(codeunits(body_text))
    response = HT.Response(
        status,
        HT.BytesBody(payload);
        reason = reason,
        headers = headers,
        content_length = length(payload),
        close = close_conn,
        request = request,
    )
    io = IOBuffer()
    HT.write_response!(io, response)
    _write_all_tcp_retry!(conn, take!(io))
    return nothing
end

function _wait_task_retry!(task::Task; timeout_s::Float64 = 5.0)
    status = timedwait(() -> istaskdone(task), timeout_s; pollint = 0.001)
    status == :timed_out && error("timed out waiting for retry test task")
    fetch(task)
    return nothing
end

function _serve_retry_sequence(listener, scenarios, seen)
    return errormonitor(Threads.@spawn begin
        for scenario in scenarios
            conn = NC.accept(listener)
            try
                request = HT.read_request(HT._ConnReader(conn))
                body = String(_read_all_body_bytes_retry(request.body))
                push!(seen, (request.method, request.target, body))
                headers = HT.Headers()
                retry_after = get(scenario, :retry_after, nothing)
                retry_after === nothing || HT.setheader(headers, "Retry-After", retry_after)
                _send_response_retry!(
                    conn,
                    request;
                    status = scenario.status,
                    reason = scenario.reason,
                    body_text = get(scenario, :body_text, ""),
                    headers = headers,
                    close_conn = get(scenario, :close_conn, true),
                )
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
end

mutable struct _OneShotIO <: IO
    data::Vector{UInt8}
    next::Int
end

function _OneShotIO(data::AbstractString)
    return _OneShotIO(collect(codeunits(String(data))), 1)
end

function Base.readbytes!(io::_OneShotIO, dst::Vector{UInt8}, n::Integer)
    io.next > length(io.data) && return 0
    count = min(Int(n), length(dst), length(io.data) - io.next + 1)
    copyto!(dst, 1, io.data, io.next, count)
    io.next += count
    return count
end

@testset "HTTP retry bucket defaults and validation" begin
    bucket = HT.RetryBucket()
    @test bucket.backoff_scale_factor_ms == 25
    @test bucket.max_backoff_secs == 20
    @test bucket.capacity == 500
    @test isempty(bucket.partitions)

    @test_throws ArgumentError HT.RetryBucket(capacity = 0)
    @test_throws ArgumentError HT.RetryBucket(backoff_scale_factor_ms = -1)
    @test_throws ArgumentError HT.RetryBucket(max_backoff_secs = -1)
end

@testset "HTTP retry bucket acquire/release is partitioned and case-insensitive" begin
    bucket = HT.RetryBucket(capacity = 15)

    token = Base.acquire(bucket, "Example.COM")
    @test token.partition == "example.com"
    @test_throws HT.RetryDeniedError Base.acquire(bucket, "example.com")

    other = Base.acquire(bucket, "other.example.com")
    @test other.partition == "other.example.com"

    Base.release(bucket, token, 0)
    token2 = Base.acquire(bucket, "EXAMPLE.com")
    @test token2.partition == "example.com"

    Base.release(bucket, token2, 0)
    Base.release(bucket, other, 0)
end

@testset "HTTP retry bucket successful release restores reserved capacity" begin
    bucket = HT.RetryBucket(capacity = 20)

    token = Base.acquire(bucket, "svc.example")
    Base.release(bucket, token, 0)
    Base.release(bucket, token, 0)

    token1 = Base.acquire(bucket, "svc.example")
    token2 = Base.acquire(bucket, "svc.example")
    @test_throws HT.RetryDeniedError Base.acquire(bucket, "svc.example")

    Base.release(bucket, token1, 0)
    Base.release(bucket, token2, 0)
end

@testset "HTTP retry bucket response failure release keeps partial cost" begin
    bucket = HT.RetryBucket(capacity = 25)

    token = Base.acquire(bucket, "svc.example")
    Base.release(bucket, token, HT._RETRY_BUCKET_RETRYABLE_RESPONSE_COST)

    token1 = Base.acquire(bucket, "svc.example")
    token2 = Base.acquire(bucket, "svc.example")
    @test_throws HT.RetryDeniedError Base.acquire(bucket, "svc.example")

    Base.release(bucket, token1, 0)
    Base.release(bucket, token2, 0)
end

@testset "HTTP retry bucket exception failure release keeps full transient cost" begin
    bucket = HT.RetryBucket(capacity = 25)

    token = Base.acquire(bucket, "svc.example")
    Base.release(bucket, token, HT._RETRY_BUCKET_ACQUIRE_COST)

    token1 = Base.acquire(bucket, "svc.example")
    @test_throws HT.RetryDeniedError Base.acquire(bucket, "svc.example")

    Base.release(bucket, token1, 0)
end

@testset "HTTP transport owns an optional default retry bucket" begin
    default_transport = HT.Transport()
    @test default_transport.retry_bucket isa HT.RetryBucket

    custom_bucket = HT.RetryBucket(capacity = 30)
    custom_transport = HT.Transport(retry_bucket = custom_bucket)
    @test custom_transport.retry_bucket === custom_bucket

    disabled_transport = HT.Transport(retry_bucket = nothing)
    @test disabled_transport.retry_bucket === nothing

    close(default_transport)
    close(custom_transport)
    close(disabled_transport)
end

@testset "HTTP request retries idempotent responses and honors status_exception after retries" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    seen = Tuple{String, String, String}[]
    scenarios = [
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 200, reason = "OK", body_text = "ok"),
    ]
    server_task = _serve_retry_sequence(listener, scenarios, seen)
    try
        response = HT.get("$(base_url)/idempotent"; retries = 1, status_exception = false)
        @test response.status == 200
        @test String(response.body) == "ok"
        _wait_task_retry!(server_task)
        @test seen == [("GET", "/idempotent", ""), ("GET", "/idempotent", "")]
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP retry_attempts reports client retries (#1011, #1019)" begin
    # retried request: 503 -> 503 -> 200 with retries = 2
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen = Tuple{String, String, String}[]
    scenarios = [
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 200, reason = "OK", body_text = "ok"),
    ]
    server_task = _serve_retry_sequence(listener, scenarios, seen)
    try
        response = HT.get("http://$(address)/attempts"; retries = 2, status_exception = false)
        @test response.status == 200
        @test HT.retry_attempts(response) == 2
        @test HT.retry_attempts(response.request) == 2
        # 1.x-compatible context location still works
        @test get(HT.get_request_context(response.request), :retryattempt, 0) == 2
        _wait_task_retry!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end

    # no retries needed: count stays 0
    listener2 = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr2 = NC.addr(listener2)::NC.SocketAddrV4
    address2 = ND.join_host_port("127.0.0.1", Int(laddr2.port))
    seen2 = Tuple{String, String, String}[]
    server_task2 = _serve_retry_sequence(listener2, [(status = 200, reason = "OK", body_text = "ok")], seen2)
    try
        response = HT.get("http://$(address2)/noretry"; retries = 2)
        @test response.status == 200
        @test HT.retry_attempts(response) == 0
        _wait_task_retry!(server_task2)
    finally
        HTTP.@try_ignore NC.close(listener2)
    end

    # exhausted retries: StatusError message reports the retry count
    listener3 = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr3 = NC.addr(listener3)::NC.SocketAddrV4
    address3 = ND.join_host_port("127.0.0.1", Int(laddr3.port))
    seen3 = Tuple{String, String, String}[]
    scenarios3 = [
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
    ]
    server_task3 = _serve_retry_sequence(listener3, scenarios3, seen3)
    try
        err = try
            HT.get("http://$(address3)/exhausted"; retries = 1)
            nothing
        catch e
            e
        end
        @test err isa HT.StatusError
        @test err !== nothing && HT.retry_attempts((err::HT.StatusError).response) == 1
        @test err !== nothing && occursin("(after 1 retry)", sprint(showerror, err::HT.StatusError))
        _wait_task_retry!(server_task3)
    finally
        HTTP.@try_ignore NC.close(listener3)
    end
end

@testset "HTTP request trace emits retry events" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    seen = Tuple{String, String, String}[]
    events = Any[]
    scenarios = [
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 200, reason = "OK", body_text = "ok"),
    ]
    server_task = _serve_retry_sequence(listener, scenarios, seen)
    try
        response = HT.request(event -> push!(events, event), "GET", "$(base_url)/retry"; retries = 1, status_exception = false)
        @test response.status == 200
        @test String(response.body) == "ok"
        _wait_task_retry!(server_task)
        @test seen == [("GET", "/retry", ""), ("GET", "/retry", "")]
        @test typeof.(events) == [
            HT.RequestEvent,
            HT.ResponseHeadEvent,
            HT.RetryEvent,
            HT.RequestEvent,
            HT.ResponseHeadEvent,
            HT.DoneEvent,
        ]
        retry_event = events[3]::HT.RetryEvent
        @test retry_event.attempt == 1
        @test retry_event.next_attempt == 2
        @test retry_event.redirect_count == 0
        @test retry_event.response !== nothing
        @test retry_event.err === nothing
        @test (retry_event.response::HT.Response).status == 503
        @test retry_event.delay_ns == 0
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP request treats PUT and DELETE as idempotent for retries" begin
    for (method, body_arg) in [("PUT", "payload"), ("DELETE", nothing)]
        listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
        laddr = NC.addr(listener)::NC.SocketAddrV4
        address = ND.join_host_port("127.0.0.1", Int(laddr.port))
        base_url = "http://$(address)"
        seen = Tuple{String, String, String}[]
        scenarios = [
            (status = 503, reason = "Service Unavailable", retry_after = "0"),
            (status = 200, reason = "OK", body_text = "ok"),
        ]
        server_task = _serve_retry_sequence(listener, scenarios, seen)
        try
            response = HT.request(method, "$(base_url)/method"; body = body_arg, retries = 1, status_exception = false)
            @test response.status == 200
            _wait_task_retry!(server_task)
            expected_body = body_arg === nothing ? "" : "payload"
            @test seen == [(method, "/method", expected_body), (method, "/method", expected_body)]
        finally
            HTTP.@try_ignore NC.close(listener)
        end
    end
end

@testset "HTTP request gates POST retries on retry_non_idempotent or Idempotency-Key" begin
    listener1 = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address1 = ND.join_host_port("127.0.0.1", Int((NC.addr(listener1)::NC.SocketAddrV4).port))
    base_url1 = "http://$(address1)"
    seen1 = Tuple{String, String, String}[]
    server_task1 = _serve_retry_sequence(listener1, [(status = 503, reason = "Service Unavailable", retry_after = "0")], seen1)
    try
        response = HT.post("$(base_url1)/post"; body = "payload", retries = 1, status_exception = false)
        @test response.status == 503
        _wait_task_retry!(server_task1)
        @test seen1 == [("POST", "/post", "payload")]
    finally
        HTTP.@try_ignore NC.close(listener1)
    end

    listener2 = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address2 = ND.join_host_port("127.0.0.1", Int((NC.addr(listener2)::NC.SocketAddrV4).port))
    base_url2 = "http://$(address2)"
    seen2 = Tuple{String, String, String}[]
    server_task2 = _serve_retry_sequence(listener2, [
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 200, reason = "OK", body_text = "ok"),
    ], seen2)
    try
        response = HT.post("$(base_url2)/post"; body = "payload", retries = 1, retry_non_idempotent = true, status_exception = false)
        @test response.status == 200
        _wait_task_retry!(server_task2)
        @test seen2 == [("POST", "/post", "payload"), ("POST", "/post", "payload")]
    finally
        HTTP.@try_ignore NC.close(listener2)
    end

    listener3 = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address3 = ND.join_host_port("127.0.0.1", Int((NC.addr(listener3)::NC.SocketAddrV4).port))
    base_url3 = "http://$(address3)"
    seen3 = Tuple{String, String, String}[]
    server_task3 = _serve_retry_sequence(listener3, [
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 200, reason = "OK", body_text = "ok"),
    ], seen3)
    try
        response = HT.post(
            "$(base_url3)/post",
            ["Idempotency-Key" => "abc123"],
            "payload";
            retries = 1,
            status_exception = false,
        )
        @test response.status == 200
        _wait_task_retry!(server_task3)
        @test seen3 == [("POST", "/post", "payload"), ("POST", "/post", "payload")]
    finally
        HTTP.@try_ignore NC.close(listener3)
    end
end

@testset "HTTP request retry_if can force or suppress retries" begin
    listener1 = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address1 = ND.join_host_port("127.0.0.1", Int((NC.addr(listener1)::NC.SocketAddrV4).port))
    base_url1 = "http://$(address1)"
    seen1 = Tuple{String, String, String}[]
    server_task1 = _serve_retry_sequence(listener1, [
        (status = 418, reason = "I'm a teapot", retry_after = "0"),
        (status = 200, reason = "OK", body_text = "ok"),
    ], seen1)
    force_retry = (attempt, err, req, resp) -> resp !== nothing && resp.status == 418 ? true : nothing
    try
        response = HT.get("$(base_url1)/hook"; retries = 1, retry_if = force_retry, status_exception = false, retry_bucket = HT.RetryBucket(backoff_scale_factor_ms = 0, max_backoff_secs = 0))
        @test response.status == 200
        _wait_task_retry!(server_task1)
        @test seen1 == [("GET", "/hook", ""), ("GET", "/hook", "")]
    finally
        HTTP.@try_ignore NC.close(listener1)
    end

    listener2 = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address2 = ND.join_host_port("127.0.0.1", Int((NC.addr(listener2)::NC.SocketAddrV4).port))
    base_url2 = "http://$(address2)"
    seen2 = Tuple{String, String, String}[]
    server_task2 = _serve_retry_sequence(listener2, [(status = 503, reason = "Service Unavailable", retry_after = "0")], seen2)
    suppress_retry = (attempt, err, req, resp) -> false
    try
        response = HT.get("$(base_url2)/hook"; retries = 1, retry_if = suppress_retry, status_exception = false)
        @test response.status == 503
        _wait_task_retry!(server_task2)
        @test seen2 == [("GET", "/hook", "")]
    finally
        HTTP.@try_ignore NC.close(listener2)
    end
end

@testset "HTTP retry_if sees RequestRetryError for request-path failures" begin
    seen_err = Ref{Any}(nothing)
    hook = (attempt, err, req, resp) -> begin
        seen_err[] = err
        return false
    end
    client = HT.Client(transport = HT.Transport(retry_bucket = nothing, max_idle_per_host = 1, max_idle_total = 1), cookiejar = nothing)
    try
        controller = HT._retry_controller(client, true, 1, false, hook, true, false)
        request = HT.Request("GET", "/hook"; host = "example.com", body = HT.EmptyBody(), content_length = 0)
        @test !HT._should_retry_request_attempt(controller, 1, request, HT.RequestRetryError(EOFError()), nothing)
        @test seen_err[] isa HT.RequestRetryError
        @test (seen_err[]::HT.RequestRetryError).err isa EOFError
    finally
        close(client)
    end
end

@testset "HTTP request does not retry unreplayable IO bodies" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address = ND.join_host_port("127.0.0.1", Int((NC.addr(listener)::NC.SocketAddrV4).port))
    base_url = "http://$(address)"
    seen = Tuple{String, String, String}[]
    server_task = _serve_retry_sequence(listener, [(status = 503, reason = "Service Unavailable", retry_after = "0")], seen)
    try
        response = HT.post(
            "$(base_url)/streaming";
            body = _OneShotIO("payload"),
            retries = 1,
            retry_non_idempotent = true,
            status_exception = false,
        )
        @test response.status == 503
        _wait_task_retry!(server_task)
        @test seen == [("POST", "/streaming", "payload")]
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP request retry bucket can constrain retries or be disabled" begin
    listener1 = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address1 = ND.join_host_port("127.0.0.1", Int((NC.addr(listener1)::NC.SocketAddrV4).port))
    base_url1 = "http://$(address1)"
    seen1 = Tuple{String, String, String}[]
    server_task1 = _serve_retry_sequence(listener1, [
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
    ], seen1)
    try
        bucket = HT.RetryBucket(capacity = 10, backoff_scale_factor_ms = 0, max_backoff_secs = 0)
        response = HT.get("$(base_url1)/bucket"; retries = 2, retry_bucket = bucket, status_exception = false)
        @test response.status == 503
        _wait_task_retry!(server_task1)
        @test seen1 == [("GET", "/bucket", ""), ("GET", "/bucket", "")]
    finally
        HTTP.@try_ignore NC.close(listener1)
    end

    listener2 = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address2 = ND.join_host_port("127.0.0.1", Int((NC.addr(listener2)::NC.SocketAddrV4).port))
    base_url2 = "http://$(address2)"
    seen2 = Tuple{String, String, String}[]
    server_task2 = _serve_retry_sequence(listener2, [
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 200, reason = "OK", body_text = "ok"),
    ], seen2)
    try
        response = HT.get("$(base_url2)/bucket"; retries = 2, retry_bucket = false, status_exception = false)
        @test response.status == 200
        @test String(response.body) == "ok"
        _wait_task_retry!(server_task2)
        @test seen2 == [("GET", "/bucket", ""), ("GET", "/bucket", ""), ("GET", "/bucket", "")]
    finally
        HTTP.@try_ignore NC.close(listener2)
    end
end

@testset "HTTP.open retries idempotent buffered requests" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address = ND.join_host_port("127.0.0.1", Int((NC.addr(listener)::NC.SocketAddrV4).port))
    base_url = "http://$(address)"
    seen = Tuple{String, String, String}[]
    server_task = _serve_retry_sequence(listener, [
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 200, reason = "OK", body_text = "ok"),
    ], seen)
    try
        response = HT.open(:GET, "$(base_url)/open"; retries = 1, status_exception = false) do stream
            meta = HT.startread(stream)
            @test meta.status == 200
            @test String(read(stream)) == "ok"
            return nothing
        end
        @test response.status == 200
        @test response.body === nothing
        _wait_task_retry!(server_task)
        @test seen == [("GET", "/open", ""), ("GET", "/open", "")]
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP.open retries buffered POST requests when enabled" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address = ND.join_host_port("127.0.0.1", Int((NC.addr(listener)::NC.SocketAddrV4).port))
    base_url = "http://$(address)"
    seen = Tuple{String, String, String}[]
    server_task = _serve_retry_sequence(listener, [
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 200, reason = "OK", body_text = "ok"),
    ], seen)
    try
        response = HT.open(:POST, "$(base_url)/open-post"; retries = 1, retry_non_idempotent = true, status_exception = false) do stream
            write(stream, "payload")
            meta = HT.startread(stream)
            @test meta.status == 200
            @test String(read(stream)) == "ok"
        end
        @test response.status == 200
        @test response.body === nothing
        _wait_task_retry!(server_task)
        @test seen == [("POST", "/open-post", "payload"), ("POST", "/open-post", "payload")]
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP retry-after parsing handles seconds and dates" begin
    headers = HT.Headers(["Retry-After" => "0"])
    @test HT._retry_after_delay_ns(headers) == 0

    future = HTTP.Dates.now(HTTP.Dates.UTC) + HTTP.Dates.Second(1)
    headers_date = HT.Headers(["Retry-After" => HTTP.Dates.format(future, HTTP.Dates.RFC1123Format) * " GMT"])
    delay_ns = HT._retry_after_delay_ns(headers_date)
    @test delay_ns !== nothing
    @test delay_ns >= 0

    invalid_headers = HT.Headers(["Retry-After" => "nonsense"])
    @test HT._retry_after_delay_ns(invalid_headers) === nothing
end
