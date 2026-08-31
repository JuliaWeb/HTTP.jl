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

function _wait_task_retry!(task::Task)
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

    partitions = Dict{String,HT._RetryPartition}("depleted.example" => HT._RetryPartition(5))
    positional = HT.RetryBucket(25, 20, 10, partitions, ReentrantLock())
    @test positional.partitions === partitions
    @test (@atomic :acquire positional.depleted_partitions) == 1

    six_field = HT.RetryBucket(25, 20, 10, partitions, ReentrantLock(), Set(["depleted.example"]))
    @test (@atomic :acquire six_field.depleted_partitions) == 1

    # The six-field constructor derives the count from the partition states;
    # a stale legacy set must not break the count invariant.
    stale_set = HT.RetryBucket(25, 20, 10, partitions, ReentrantLock(), Set{String}())
    @test (@atomic :acquire stale_set.depleted_partitions) == 1

    converted = HT.RetryBucket(Int32(25), Int16(20), Int8(10), copy(partitions), ReentrantLock())
    @test converted.backoff_scale_factor_ms === 25
    @test converted.max_backoff_secs === 20
    @test converted.capacity === 10
    @test converted.partitions == partitions
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

@testset "HTTP retry bucket refunds retried attempts that reach a final response (#1353)" begin
    # A retried attempt that reached a non-retryable response refunds its
    # reservation in full; retryable responses keep the partial cost; `nothing`
    # (the retry never launched) refunds in full.
    @test HT._retry_bucket_failure_cost(nothing) == 0
    @test HT._retry_bucket_failure_cost(200) == 0
    @test HT._retry_bucket_failure_cost(404) == 0
    @test HT._retry_bucket_failure_cost(501) == 0
    for retryable_status in (408, 429, 500, 502, 503, 504)
        @test HT._retry_bucket_failure_cost(retryable_status) == HT._RETRY_BUCKET_RETRYABLE_RESPONSE_COST
        @test HT._retryable_status(retryable_status)
    end
    @test HT._retry_bucket_response_cost(true) == HT._RETRY_BUCKET_RETRYABLE_RESPONSE_COST
    @test HT._retry_bucket_response_cost(false) == 0

    # Full refund on success: with capacity for exactly one reservation, a
    # second acquire only succeeds because the first returned its cost.
    bucket = HT.RetryBucket(capacity = 10)
    token = Base.acquire(bucket, "svc.example")
    Base.release(bucket, token, HT._retry_bucket_failure_cost(200))
    token2 = Base.acquire(bucket, "svc.example")
    Base.release(bucket, token2, 0)
end

@testset "HTTP retry bucket replenishes consumed capacity (#1353)" begin
    bucket = HT.RetryBucket(capacity = 20)
    @test (@atomic :acquire bucket.depleted_partitions) == 0

    # Replenish before any capacity was ever spent is a lock-free no-op and
    # creates no partitions.
    HT._retry_bucket_replenish!(bucket, "svc.example")
    @test isempty(bucket.partitions)

    token = Base.acquire(bucket, "svc.example")
    @test (@atomic :acquire bucket.depleted_partitions) == 1
    Base.release(bucket, token, HT._RETRY_BUCKET_ACQUIRE_COST)
    @test bucket.partitions["svc.example"].capacity == 10

    for _ in 1:5
        HT._retry_bucket_replenish!(bucket, "svc.example")
    end
    @test bucket.partitions["svc.example"].capacity == 15
    @test (@atomic :acquire bucket.depleted_partitions) == 1

    # Case-insensitive, and capped at full capacity.
    for _ in 1:10
        HT._retry_bucket_replenish!(bucket, "SVC.example")
    end
    @test bucket.partitions["svc.example"].capacity == 20
    @test (@atomic :acquire bucket.depleted_partitions) == 0

    # Untouched partitions are not affected by another partition's depletion.
    other = Base.acquire(bucket, "other.example")
    HT._retry_bucket_replenish!(bucket, "svc.example")
    @test bucket.partitions["svc.example"].capacity == 20
    @test (@atomic :acquire bucket.depleted_partitions) == 1
    Base.release(bucket, other, 0)
    @test (@atomic :acquire bucket.depleted_partitions) == 0
end

@testset "HTTP retry bucket uses a pointer-free concurrent fast path (#1355)" begin
    bucket = HT.RetryBucket(capacity = 20)
    @test isbitstype(fieldtype(HT.RetryBucket, :depleted_partitions))
    workers = max(4, 2 * Threads.nthreads())
    @sync begin
        for worker in 1:workers
            Threads.@spawn begin
                key = "svc-$worker.example"
                for _ in 1:2_000
                    token = Base.acquire(bucket, key)
                    Base.release(bucket, token, HT._RETRY_BUCKET_ACQUIRE_COST)
                    for _ in 1:HT._RETRY_BUCKET_ACQUIRE_COST
                        HT._retry_bucket_replenish!(bucket, key)
                    end
                end
            end
        end
        Threads.@spawn for _ in 1:100
            GC.gc(false)
            yield()
        end
    end
    @test all(state.capacity == bucket.capacity for state in values(bucket.partitions))
    @test (@atomic :acquire bucket.depleted_partitions) == 0
end

@testset "HTTP retry bucket heals only after successful responses" begin
    server = HT.serve!("127.0.0.1", 0; listenany = true) do request
        return request.target == "/healthy" ? HT.Response(200) : HT.Response(404)
    end
    bucket = HT.RetryBucket(capacity = 20, backoff_scale_factor_ms = 0, max_backoff_secs = 0)
    spent = Base.acquire(bucket, "127.0.0.1")
    Base.release(bucket, spent, HT._RETRY_BUCKET_ACQUIRE_COST)
    client = HT.Client(transport = HT.Transport(retry_bucket = bucket), cookiejar = nothing)
    try
        failed = HT.get(client, "http://127.0.0.1:$(HT.port(server))/missing"; retries = 1, status_exception = false)
        @test failed.status == 404
        @test bucket.partitions["127.0.0.1"].capacity == 10

        healthy = HT.get(client, "http://127.0.0.1:$(HT.port(server))/healthy"; retries = 1)
        @test healthy.status == 200
        @test bucket.partitions["127.0.0.1"].capacity == 11
    finally
        close(client)
        HT.forceclose(server)
    end
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
    policy_attempts = Int[]
    force_retry = (attempt, err, req, resp) -> begin
        push!(policy_attempts, attempt)
        return resp !== nothing && resp.status == 418 ? true : nothing
    end
    try
        response = HT.get("$(base_url1)/hook"; retries = 1, retry_if = force_retry, status_exception = false, retry_bucket = HT.RetryBucket(backoff_scale_factor_ms = 0, max_backoff_secs = 0))
        @test response.status == 200
        _wait_task_retry!(server_task1)
        @test seen1 == [("GET", "/hook", ""), ("GET", "/hook", "")]
        @test policy_attempts == [1]
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

@testset "HTTP retry bucket accounts for retry_if decisions" begin
    attempts = Ref(0)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do _
        attempts[] += 1
        return HT.Response(418, "still retryable by policy")
    end
    events = Any[]
    policy_attempts = Int[]
    bucket = HT.RetryBucket(capacity = 10, backoff_scale_factor_ms = 0, max_backoff_secs = 0)
    retry_if = (attempt, _, _, response) -> begin
        push!(policy_attempts, attempt)
        return response !== nothing && response.status == 418
    end
    try
        response = HT.request(
            event -> push!(events, event),
            "GET",
            "http://127.0.0.1:$(HT.port(server))/custom";
            retries = 3,
            retry_if = retry_if,
            retry_bucket = bucket,
            status_exception = false,
        )
        @test response.status == 418
        @test attempts[] == 2
        @test policy_attempts == [1, 2]
        skipped = [event for event in events if event isa HT.RetrySkippedEvent]
        @test length(skipped) == 1
        @test (only(skipped)::HT.RetrySkippedEvent).reason === :retry_bucket
        @test bucket.partitions["127.0.0.1"].capacity == 5
    finally
        HT.forceclose(server)
    end

    # A custom policy can suppress a built-in response retry. The effective
    # policy result must also decide whether the prior reservation keeps cost.
    attempts[] = 0
    empty!(policy_attempts)
    suppressing_server = HT.serve!("127.0.0.1", 0; listenany = true) do _
        attempts[] += 1
        return HT.Response(503, "built-in retryable")
    end
    suppressing_bucket = HT.RetryBucket(capacity = 10, backoff_scale_factor_ms = 0, max_backoff_secs = 0)
    suppress_second = (attempt, _, _, response) -> begin
        push!(policy_attempts, attempt)
        return response !== nothing && attempt == 1
    end
    try
        response = HT.get(
            "http://127.0.0.1:$(HT.port(suppressing_server))/suppressed";
            retries = 3,
            retry_if = suppress_second,
            retry_bucket = suppressing_bucket,
            status_exception = false,
        )
        @test response.status == 503
        @test attempts[] == 2
        @test policy_attempts == [1, 2]
        @test suppressing_bucket.partitions["127.0.0.1"].capacity == 10
    finally
        HT.forceclose(suppressing_server)
    end
end

@testset "HTTP retry bucket preserves terminal built-in response charging" begin
    attempts = Ref(0)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do _
        attempts[] += 1
        return HT.Response(503, "still unavailable")
    end
    bucket = HT.RetryBucket(capacity = 10, backoff_scale_factor_ms = 0, max_backoff_secs = 0)
    events = Any[]
    url = "http://127.0.0.1:$(HT.port(server))/terminal-failure"
    try
        first = HT.get(url; retries = 1, retry_bucket = bucket, status_exception = false)
        @test first.status == 503
        @test attempts[] == 2
        @test bucket.partitions["127.0.0.1"].capacity == 5

        second = HT.request(
            event -> push!(events, event),
            "GET",
            url;
            retries = 1,
            retry_bucket = bucket,
            status_exception = false,
        )
        @test second.status == 503
        @test attempts[] == 3
        skipped = [event for event in events if event isa HT.RetrySkippedEvent]
        @test length(skipped) == 1
        @test (only(skipped)::HT.RetrySkippedEvent).reason === :retry_bucket
    finally
        HT.forceclose(server)
    end
end

@testset "HTTP retry bucket charges terminal custom-only response failures" begin
    attempts = Ref(0)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do _
        attempts[] += 1
        return HT.Response(418, "custom retry failure")
    end
    bucket = HT.RetryBucket(capacity = 10, backoff_scale_factor_ms = 0, max_backoff_secs = 0)
    retry_if = (_, _, _, response) -> response !== nothing && response.status == 418
    url = "http://127.0.0.1:$(HT.port(server))/terminal-custom-failure"
    try
        first = HT.get(
            url;
            retries = 1,
            retry_if = retry_if,
            retry_bucket = bucket,
            status_exception = false,
        )
        @test first.status == 418
        @test attempts[] == 2
        @test bucket.partitions["127.0.0.1"].capacity == 5

        second = HT.get(
            url;
            retries = 1,
            retry_if = retry_if,
            retry_bucket = bucket,
            status_exception = false,
        )
        @test second.status == 418
        @test attempts[] == 3
    finally
        HT.forceclose(server)
    end
end

@testset "HTTP retry bucket carries an explicit custom decision to the terminal response" begin
    attempts = Ref(0)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do _
        attempts[] += 1
        return isodd(attempts[]) ? HT.Response(503, "built-in and custom") : HT.Response(418, "custom only")
    end
    bucket = HT.RetryBucket(capacity = 10, backoff_scale_factor_ms = 0, max_backoff_secs = 0)
    retry_if = (_, _, _, response) -> response !== nothing && response.status >= 400
    url = "http://127.0.0.1:$(HT.port(server))/mixed-terminal-failure"
    try
        first = HT.get(
            url;
            retries = 1,
            retry_if = retry_if,
            retry_bucket = bucket,
            status_exception = false,
        )
        @test first.status == 418
        @test attempts[] == 2
        @test bucket.partitions["127.0.0.1"].capacity == 5

        second = HT.get(
            url;
            retries = 1,
            retry_if = retry_if,
            retry_bucket = bucket,
            status_exception = false,
        )
        @test second.status == 503
        @test attempts[] == 3
    finally
        HT.forceclose(server)
    end
end

@testset "HTTP retry tracing failures release reserved capacity" begin
    for throw_on in (HT.RetryEvent, HT.RequestEvent, HT.ResponseHeadEvent)
        attempts = Ref(0)
        server = HT.serve!("127.0.0.1", 0; listenany = true) do _
            attempts[] += 1
            return attempts[] == 1 ? HT.Response(503, "retry") : HT.Response(200, "ok")
        end
        bucket = HT.RetryBucket(capacity = 10, backoff_scale_factor_ms = 0, max_backoff_secs = 0)
        transport = HT.Transport(
            retry_bucket = bucket,
            max_conns_per_host = 1,
            max_idle_per_host = 1,
            max_idle_total = 1,
        )
        client = HT.Client(transport = transport, cookiejar = nothing)
        trace_err = ErrorException("trace failed")
        trace = event -> begin
            if event isa throw_on
                matching_attempt = throw_on === HT.RetryEvent || getfield(event, :attempt) == 2
                matching_attempt && throw(trace_err)
            end
            return nothing
        end
        try
            err = try
                HT.request(
                    trace,
                    "GET",
                    "http://127.0.0.1:$(HT.port(server))/trace";
                    client = client,
                    retries = 1,
                    status_exception = false,
                )
                nothing
            catch caught
                caught
            end
            @test err === trace_err
            @test bucket.partitions["127.0.0.1"].capacity == 10
            @test (@atomic :acquire bucket.depleted_partitions) == 0
            @test lock(transport.lock) do
                isempty(transport.conns_per_host)
            end
        finally
            close(client)
            HT.forceclose(server)
        end
    end
end

@testset "HTTP retry policy failures preserve response ownership cleanup" begin
    attempts = Ref(0)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do _
        attempts[] += 1
        return attempts[] == 1 ? HT.Response(503, "retry") : HT.Response(200, "ok")
    end
    bucket = HT.RetryBucket(capacity = 10, backoff_scale_factor_ms = 0, max_backoff_secs = 0)
    transport = HT.Transport(
        retry_bucket = bucket,
        max_conns_per_host = 1,
        max_idle_per_host = 1,
        max_idle_total = 1,
    )
    client = HT.Client(transport = transport, cookiejar = nothing)
    policy_err = ErrorException("policy failed")
    retry_if = (attempt, _, _, response) -> begin
        attempt == 2 && response !== nothing && throw(policy_err)
        return response !== nothing && response.status == 503
    end
    try
        err = try
            HT.get(
                client,
                "http://127.0.0.1:$(HT.port(server))/policy";
                retries = 2,
                retry_if = retry_if,
                status_exception = false,
            )
            nothing
        catch caught
            caught
        end
        @test err === policy_err
        @test bucket.partitions["127.0.0.1"].capacity == 10
        @test (@atomic :acquire bucket.depleted_partitions) == 0
        @test lock(transport.lock) do
            isempty(transport.conns_per_host)
        end
    finally
        close(client)
        HT.forceclose(server)
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
    hook_calls = Ref(0)
    force_retry = (_, _, _, _) -> begin
        hook_calls[] += 1
        return true
    end
    server_task = _serve_retry_sequence(listener, [(status = 503, reason = "Service Unavailable", retry_after = "0")], seen)
    try
        response = HT.post(
            "$(base_url)/streaming";
            body = _OneShotIO("payload"),
            retries = 1,
            retry_non_idempotent = true,
            retry_if = force_retry,
            status_exception = false,
        )
        @test response.status == 503
        _wait_task_retry!(server_task)
        @test seen == [("POST", "/streaming", "payload")]
        @test hook_calls[] == 0
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

@testset "retry arming refunds the bucket when the deadline preempts the backoff" begin
    bucket = HT.RetryBucket(capacity=15, backoff_scale_factor_ms=60_000, max_backoff_secs=60)
    controller = HT._RetryController(true, 2, false, nothing, true, bucket)
    request = HT.Request("GET", "/deadline"; host="example.com", context=HT.RequestContext(deadline_ns=1))
    response = HT.Response(503; headers=["Retry-After" => "60"])

    armed, token, delay_ns, skip_reason = HT._arm_request_retry!(controller, "example.com:80", request, 1, response)
    @test !armed
    @test token === nothing
    @test delay_ns == 60_000_000_000
    @test skip_reason === :deadline

    # Full refund: with capacity 15 a second reservation (cost 10) only
    # succeeds if the abandoned one returned its 10.
    refunded = Base.acquire(bucket, only(keys(bucket.partitions)))
    Base.release(bucket, refunded, 0)
end

@testset "retry delay rejects a deadline crossed during sleep" begin
    request = HT.Request("GET", "/deadline"; host = "example.com", context = HT.RequestContext(deadline_ns = 200))
    ticks = Int64[100, 201]
    tick_index = Ref(0)
    clock_ns = () -> begin
        tick_index[] += 1
        return ticks[tick_index[]]
    end
    slept = Ref{Int64}(0)
    sleep_ns = delay_ns -> (slept[] = delay_ns)

    @test !HT._sleep_retry_delay!(request, Int64(100); clock_ns = clock_ns, sleep_ns = sleep_ns)
    @test slept[] == 100
end

@testset "HTTP request retry that recovers refunds the retry bucket (#1353)" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address = ND.join_host_port("127.0.0.1", Int((NC.addr(listener)::NC.SocketAddrV4).port))
    seen = Tuple{String, String, String}[]
    scenarios = [
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 200, reason = "OK", body_text = "ok"),
    ]
    server_task = _serve_retry_sequence(listener, scenarios, seen)
    try
        bucket = HT.RetryBucket(capacity = 20, backoff_scale_factor_ms = 0, max_backoff_secs = 0)
        response = HT.get("http://$(address)/refund"; retries = 2, retry_bucket = bucket, status_exception = false)
        @test response.status == 200
        _wait_task_retry!(server_task)
        # The armed retry reserved 10 and recovered with a 200, so the
        # reservation was refunded in full instead of consumed (#1353).
        @test bucket.partitions["127.0.0.1"].capacity == 20
        @test (@atomic :acquire bucket.depleted_partitions) == 0
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP request trace emits RetrySkippedEvent when the bucket denies (#1353)" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address = ND.join_host_port("127.0.0.1", Int((NC.addr(listener)::NC.SocketAddrV4).port))
    seen = Tuple{String, String, String}[]
    scenarios = [
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
        (status = 503, reason = "Service Unavailable", retry_after = "0"),
    ]
    server_task = _serve_retry_sequence(listener, scenarios, seen)
    events = Any[]
    try
        # Capacity for exactly one reservation: the first retry consumes 10 and
        # releases 5 back after the retried attempt's 503, so arming the second
        # retry (cost 10 > 5) is denied by the bucket.
        bucket = HT.RetryBucket(capacity = 10, backoff_scale_factor_ms = 0, max_backoff_secs = 0)
        response = HT.request(event -> push!(events, event), "GET", "http://$(address)/denied"; retries = 2, retry_bucket = bucket, status_exception = false)
        @test response.status == 503
        _wait_task_retry!(server_task)
        skipped = [event for event in events if event isa HT.RetrySkippedEvent]
        @test length(skipped) == 1
        skip_event = skipped[1]::HT.RetrySkippedEvent
        @test skip_event.reason === :retry_bucket
        @test skip_event.attempt == 2
        @test skip_event.err === nothing
        @test (skip_event.response::HT.Response).status == 503
        @test skip_event.redirect_count == 0
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP request trace emits RetrySkippedEvent for request-path failures (#1353)" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    address = ND.join_host_port("127.0.0.1", Int((NC.addr(listener)::NC.SocketAddrV4).port))
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            # Read the request, then close without responding: the request
            # fails with a retryable request-path error on a fresh connection.
            _ = HT.read_request(HT._ConnReader(conn))
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    events = Any[]
    bucket = HT.RetryBucket(capacity = 10, backoff_scale_factor_ms = 0, max_backoff_secs = 0)
    drained = Base.acquire(bucket, "127.0.0.1")  # empty the partition up front
    try
        err = try
            HT.request(event -> push!(events, event), "GET", "http://$(address)/skip"; retries = 2, retry_bucket = bucket)
            nothing
        catch e
            e
        end
        @test err isa Exception
        @test HT.isrecoverable(err::Exception)
        _wait_task_retry!(server_task)
        skipped = [event for event in events if event isa HT.RetrySkippedEvent]
        @test length(skipped) == 1
        skip_event = skipped[1]::HT.RetrySkippedEvent
        @test skip_event.reason === :retry_bucket
        @test skip_event.attempt == 1
        @test skip_event.response === nothing
        @test skip_event.err isa Exception
    finally
        Base.release(bucket, drained, 0)
        HTTP.@try_ignore NC.close(listener)
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

    now = HTTP.Dates.DateTime(2026, 1, 2, 3, 4, 5)
    future = now + HTTP.Dates.Second(1)
    headers_date = HT.Headers(["Retry-After" => HTTP.Dates.format(future, HTTP.Dates.RFC1123Format) * " GMT"])
    @test HT._parse_retry_after_delay_ns(HT.header(headers_date, "Retry-After"); now=now) == 1_000_000_000

    invalid_headers = HT.Headers(["Retry-After" => "nonsense"])
    @test HT._retry_after_delay_ns(invalid_headers) === nothing
end

@testset "isrecoverable classifies retryable request exceptions (#1245)" begin
    # recoverable: transient transport / protocol failures
    @test HT.isrecoverable(EOFError())
    @test HT.isrecoverable(HT.ParseError("bad"))
    @test HT.isrecoverable(SystemError("connect"))
    @test HT.isrecoverable(ND.DialTimeoutError("host:80"))

    # non-recoverable: a deadline being hit, and unrelated exceptions
    @test !HT.isrecoverable(Reseau.IOPoll.DeadlineExceededError())
    @test !HT.isrecoverable(ArgumentError("nope"))
    @test !HT.isrecoverable(ErrorException("boom"))

    # accepts the RequestRetryError wrapper handed to retry_if, unwrapping it
    @test HT.isrecoverable(HT.RequestRetryError(EOFError()))
    @test !HT.isrecoverable(HT.RequestRetryError(ArgumentError("nope")))

    # unwraps the public TLS wrappers (and TLSError causes inside them) so
    # downstream retry loops can classify wrapped errors caught from
    # HTTP.request (#1353)
    reset_tls = Reseau.TLS.TLSError("read", Int32(0), "unexpected TLS failure", SystemError("read", 0))
    @test HT.isrecoverable(reset_tls)
    @test HT.isrecoverable(HT.TLSTransportError(reset_tls))
    @test HT.isrecoverable(HT.TLSHandshakeError(reset_tls))
    @test !HT.isrecoverable(HT.TLSTransportError(Reseau.TLS.TLSError("read", Int32(0), "bad record mac", nothing)))
    @test !HT.isrecoverable(HT.TLSHandshakeError(ErrorException("cert rejected")))

    unexpected_eof_cause = ErrorException("opaque TLS record EOF cause")
    unexpected_eof = Reseau.TLS.TLSError("read", Int32(0), "unexpected EOF", unexpected_eof_cause)
    @test HT.isrecoverable(HT.TLSTransportError(unexpected_eof))

    h2_tls = Reseau.TLS.TLSError("read", Int32(0), "unexpected TLS failure", SystemError("read", 0))
    h2_read_error = HT.ProtocolError("HTTP/2 read loop failed", h2_tls)
    @test HT.isrecoverable(h2_read_error)
    wrapped_h2 = HT._wrap_client_transport_error(h2_read_error)
    @test wrapped_h2 isa HT.TLSTransportError
    @test (wrapped_h2::HT.TLSTransportError).cause === h2_tls

    # matches the internal classifier the built-in policy uses
    for err in (EOFError(), HT.ParseError("x"), ArgumentError("y"), Reseau.IOPoll.DeadlineExceededError())
        @test HT.isrecoverable(err) == HT._retryable_request_error(err)
    end
end
