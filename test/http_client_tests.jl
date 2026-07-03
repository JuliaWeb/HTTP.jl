using Test
using HTTP
using Reseau

const HT = HTTP
const NC = Reseau.TCP
const ND = Reseau.HostResolvers
const TL = Reseau.TLS

if !isdefined(@__MODULE__, :_http_windows_ci)
    @inline function _http_windows_ci()::Bool
        return Sys.iswindows() && get(ENV, "GITHUB_ACTIONS", "false") == "true"
    end
end

function _read_all_body_bytes_client(body::HT.AbstractBody)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 32)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
end

function _write_all_tcp_client!(conn::NC.Conn, bytes::Vector{UInt8})::Nothing
    total = 0
    while total < length(bytes)
        n = write(conn, bytes[(total + 1):end])
        n > 0 || error("expected write progress")
        total += n
    end
    return nothing
end

function _send_response_client!(conn::NC.Conn, request::HT.Request; status::Int = 200, reason::String = "OK", body_text::String = "", headers::HT.Headers = HT.Headers(), close_conn::Bool = false)::Nothing
    payload = collect(codeunits(body_text))
    return _send_response_bytes_client!(conn, request; status = status, reason = reason, body_bytes = payload, headers = headers, close_conn = close_conn)
end

function _send_response_bytes_client!(conn::NC.Conn, request::HT.Request; status::Int = 200, reason::String = "OK", body_bytes::Vector{UInt8}, headers::HT.Headers = HT.Headers(), close_conn::Bool = false)::Nothing
    response = HT.Response(
        status,
        HT.BytesBody(body_bytes);
        reason = reason,
        headers = headers,
        content_length = length(body_bytes),
        close = close_conn,
        request = request,
    )
    io = IOBuffer()
    HT.write_response!(io, response)
    _write_all_tcp_client!(conn, take!(io))
    return nothing
end

function _gzip_bytes_client(text::String)::Vector{UInt8}
    return transcode(HTTP.CodecZlib.GzipCompressor, collect(codeunits(text)))
end

function _deflate_bytes_client(text::String)::Vector{UInt8}
    return transcode(HTTP.CodecZlib.ZlibCompressor, collect(codeunits(text)))
end

function _wait_task_client!(task::Task; timeout_s::Float64 = 5.0)
    status = timedwait(() -> istaskdone(task), timeout_s; pollint = 0.001)
    status == :timed_out && error("timed out waiting for server task")
    fetch(task)
    return nothing
end

function _is_timeout_error_client(err)::Bool
    err isa HT.TimeoutError && return true
    err isa Reseau.IOPoll.DeadlineExceededError && return true
    err isa TL.TLSHandshakeTimeoutError && return true
    err isa TL.TLSError || return false
    cause = (err::TL.TLSError).cause
    cause === nothing && return false
    return _is_timeout_error_client(cause::Exception)
end

function _capture_stdout_client(f)::String
    mktemp() do path, io
        redirect_stdout(io) do
            f()
        end
        flush(io)
        close(io)
        return read(path, String)
    end
end

@testset "HTTP @client macro supports single middlewares" begin
    @eval module ClientSingleMiddleware
        using HTTP

        function request_middleware(next)
            return function(method, url, headers=Pair{String,String}[], body=nothing; clienttoken=nothing, kw...)
                req_headers = HTTP.Headers(headers)
                clienttoken === nothing || HTTP.setheader(req_headers, "X-Client-Token", String(clienttoken))
                response = next(method, url, req_headers, body; kw...)
                HTTP.setheader(response, "X-Client-Request", "handled")
                return response
            end
        end

        function stream_middleware(next)
            return function(method::Symbol, url, headers=Pair{String,String}[]; streamtoken=nothing, kw...)
                req_headers = HTTP.Headers(headers)
                streamtoken === nothing || HTTP.setheader(req_headers, "X-Stream-Token", String(streamtoken))
                return next(method, url, req_headers; kw...)
            end
        end

        HTTP.@client request_middleware stream_middleware
    end

    listener = ND.listen("tcp", "127.0.0.1:0"; backlog=8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    seen_tokens = String[]
    seen_query_body = Ref("")
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            push!(seen_tokens, HT.header(req1.headers, "X-Client-Token", ""))
            _send_response_client!(conn1, req1; body_text="request")
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            push!(seen_tokens, HT.header(req2.headers, "X-Client-Token", ""))
            seen_query_body[] = String(_read_all_body_bytes_client(req2.body))
            _send_response_client!(conn2, req2; body_text="query:" * seen_query_body[])
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        conn3 = NC.accept(listener)
        try
            req3 = HT.read_request(HT._ConnReader(conn3))
            push!(seen_tokens, HT.header(req3.headers, "X-Stream-Token", ""))
            _send_response_client!(conn3, req3; body_text="stream")
        finally
            HTTP.@try_ignore NC.close(conn3)
        end
        return nothing
    end)
    try
        response = ClientSingleMiddleware.get("$(base_url)/request"; clienttoken="abc123", retry=false)
        @test response.status == 200
        @test String(response.body) == "request"
        @test HT.header(response, "X-Client-Request") == "handled"

        response = ClientSingleMiddleware.query(
            "$(base_url)/query";
            clienttoken = "query-abc",
            body = (name = "value",),
            retry = false,
        )
        @test response.status == 200
        @test String(response.body) == "query:name=value"
        @test HT.header(response, "X-Client-Request") == "handled"

        seen_body = Ref("")
        response = ClientSingleMiddleware.open(:GET, "$(base_url)/stream"; streamtoken="stream-xyz", retry=false) do stream
            meta = HT.startread(stream)
            @test meta.status == 200
            seen_body[] = String(read(stream))
        end
        @test response.status == 200
        @test seen_body[] == "stream"
        @test seen_query_body[] == "name=value"
        @test seen_tokens == ["abc123", "query-abc", "stream-xyz"]
        _wait_task_client!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP @client macro supports tuple middlewares" begin
    @eval module ClientTupleMiddlewares
        using HTTP

        function outer_request(next)
            return function(method, url, headers=Pair{String,String}[], body=nothing; events=nothing, kw...)
                events === nothing || push!(events, "request-outer-before")
                response = next(method, url, headers, body; events=events, kw...)
                events === nothing || push!(events, "request-outer-after")
                return response
            end
        end

        function inner_request(next)
            return function(method, url, headers=Pair{String,String}[], body=nothing; events=nothing, kw...)
                events === nothing || push!(events, "request-inner-before")
                response = next(method, url, headers, body; kw...)
                events === nothing || push!(events, "request-inner-after")
                return response
            end
        end

        function outer_stream(next)
            return function(method::Symbol, url, headers=Pair{String,String}[]; events=nothing, kw...)
                events === nothing || push!(events, "stream-outer-before")
                stream = next(method, url, headers; events=events, kw...)
                events === nothing || push!(events, "stream-outer-after")
                return stream
            end
        end

        function inner_stream(next)
            return function(method::Symbol, url, headers=Pair{String,String}[]; events=nothing, kw...)
                events === nothing || push!(events, "stream-inner-before")
                stream = next(method, url, headers; kw...)
                events === nothing || push!(events, "stream-inner-after")
                return stream
            end
        end

        HTTP.@client (outer_request, inner_request) (outer_stream, inner_stream)
    end

    listener = ND.listen("tcp", "127.0.0.1:0"; backlog=8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    server_task = errormonitor(Threads.@spawn begin
        for body_text in ("request", "stream")
            conn = NC.accept(listener)
            try
                req = HT.read_request(HT._ConnReader(conn))
                _send_response_client!(conn, req; body_text=body_text)
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    try
        request_events = String[]
        response = ClientTupleMiddlewares.get("$(base_url)/tuple-request"; events=request_events, retry=false)
        @test response.status == 200
        @test String(response.body) == "request"
        @test request_events == [
            "request-outer-before",
            "request-inner-before",
            "request-inner-after",
            "request-outer-after",
        ]

        stream_events = String[]
        response = ClientTupleMiddlewares.open(:GET, "$(base_url)/tuple-stream"; events=stream_events, retry=false) do stream
            meta = HT.startread(stream)
            @test meta.status == 200
            @test String(read(stream)) == "stream"
        end
        @test response.status == 200
        @test stream_events == [
            "stream-outer-before",
            "stream-inner-before",
            "stream-inner-after",
            "stream-outer-after",
        ]
        _wait_task_client!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP request trace emits request response and done events" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    events = Any[]
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            req = HT.read_request(HT._ConnReader(conn))
            _send_response_client!(conn, req; body_text = "ok", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    try
        response = HT.request(event -> push!(events, event), "GET", "$(base_url)/trace"; retry = false)
        @test response.status == 200
        @test String(response.body) == "ok"
        _wait_task_client!(server_task)
        @test typeof.(events) == [HT.RequestEvent, HT.ResponseHeadEvent, HT.DoneEvent]
        @test events[1].request.method == "GET"
        @test events[1].url == "$(base_url)/trace"
        @test events[1].attempt == 1
        @test events[1].redirect_count == 0
        @test events[1].protocol == :h1
        @test events[2].response.status == 200
        @test events[2].url == "$(base_url)/trace"
        @test events[3].response.status == 200
        @test events[3].err === nothing
        @test events[3].url == "$(base_url)/trace"
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP verbose wraps a request trace and prints to stdout" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    events = Any[]
    response_ref = Ref{Union{Nothing, HT.Response}}(nothing)
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            req = HT.read_request(HT._ConnReader(conn))
            _send_response_client!(conn, req; body_text = "ok", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    try
        output = _capture_stdout_client() do
            response_ref[] = HT.request(event -> push!(events, event), "GET", "$(base_url)/verbose"; retry = false, verbose = 2)
        end
        response = response_ref[]::HT.Response
        @test response.status == 200
        @test String(response.body) == "ok"
        _wait_task_client!(server_task)
        @test typeof.(events) == [HT.RequestEvent, HT.ResponseHeadEvent, HT.DoneEvent]
        @test occursin("[http] request attempt 1 GET $(base_url)/verbose via h1", output)
        @test occursin("[http] request", output)
        @test occursin("GET /verbose HTTP/1.1", output)
        @test occursin("[http] response attempt 1 200 for $(base_url)/verbose", output)
        @test occursin("[http] response", output)
        @test occursin("HTTP/1.1 200 OK", output)
        @test occursin("[http] done 200 for $(base_url)/verbose", output)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client redirect rewrites method" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen_methods = String[]
    seen_targets = String[]
    redirected_content_type = Ref{Union{Nothing, String}}(nothing)
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            push!(seen_methods, req1.method)
            push!(seen_targets, req1.target)
            _ = _read_all_body_bytes_client(req1.body)
            headers1 = HT.Headers()
            HT.setheader(headers1, "Location", "/final")
            HT.setheader(headers1, "Connection", "close")
            _send_response_client!(conn1, req1; status = 302, reason = "Found", headers = headers1, close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            push!(seen_methods, req2.method)
            push!(seen_targets, req2.target)
            redirected_content_type[] = HT.header(req2.headers, "Content-Type", nothing)
            _send_response_client!(conn2, req2; body_text = "final")
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        return nothing
    end)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4))
    try
        headers = HT.Headers()
        HT.setheader(headers, "Content-Type", "application/json")
        req = HT.Request("POST", "/start"; host = address, headers = headers, body = HT.BytesBody(collect(codeunits("abc"))), content_length = 3)
        resp = HT.do!(client, address, req)
        @test resp.status == 200
        @test String(_read_all_body_bytes_client(resp.body)) == "final"
        _wait_task_client!(server_task)
        @test seen_methods == ["POST", "GET"]
        @test seen_targets == ["/start", "/final"]
        @test redirected_content_type[] === nothing
    finally
        close(client.transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client QUERY redirect preserves method and replayable body" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    seen_methods = String[]
    seen_bodies = String[]
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            push!(seen_methods, req1.method)
            push!(seen_bodies, String(_read_all_body_bytes_client(req1.body)))
            headers = HT.Headers()
            HT.setheader(headers, "Location", "/final")
            HT.setheader(headers, "Connection", "close")
            _send_response_client!(conn1, req1; status = 302, reason = "Found", headers = headers, close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            push!(seen_methods, req2.method)
            push!(seen_bodies, String(_read_all_body_bytes_client(req2.body)))
            _send_response_client!(conn2, req2; body_text = "ok", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        return nothing
    end)
    client = HT.Client()
    try
        policy = HT._redirect_policy(client)
        override_method, preserve_method = HT._normalize_redirect_method_override("QUERY")
        @test override_method == "QUERY"
        @test !preserve_method
        @test HT._rewrite_method_for_redirect("QUERY", 301, policy) == "QUERY"
        @test HT._rewrite_method_for_redirect("QUERY", 302, policy) == "QUERY"
        @test HT._rewrite_method_for_redirect("QUERY", 303, policy) == "GET"
        @test HT._rewrite_method_for_redirect("QUERY", 307, policy) == "QUERY"
        @test HT._rewrite_method_for_redirect("QUERY", 308, policy) == "QUERY"

        response = HT.query(
            "$(base_url)/start",
            ["Content-Type" => "application/x-www-form-urlencoded"],
            "select=name";
            client = client,
        )
        @test response.status == 200
        @test String(response.body) == "ok"
        _wait_task_client!(server_task)
        @test seen_methods == ["QUERY", "QUERY"]
        @test seen_bodies == ["select=name", "select=name"]
    finally
        close(client)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP request trace emits redirect events" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    events = Any[]
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            headers1 = HT.Headers()
            HT.setheader(headers1, "Location", "/final")
            HT.setheader(headers1, "Connection", "close")
            _send_response_client!(conn1, req1; status = 302, reason = "Found", headers = headers1, close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            _send_response_client!(conn2, req2; body_text = "ok", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        return nothing
    end)
    try
        response = HT.request(event -> push!(events, event), "GET", "$(base_url)/start"; retry = false)
        @test response.status == 200
        @test String(response.body) == "ok"
        _wait_task_client!(server_task)
        @test typeof.(events) == [
            HT.RequestEvent,
            HT.ResponseHeadEvent,
            HT.RedirectEvent,
            HT.RequestEvent,
            HT.ResponseHeadEvent,
            HT.DoneEvent,
        ]
        redirect_event = events[3]::HT.RedirectEvent
        @test redirect_event.response.status == 302
        @test redirect_event.request.target == "/start"
        @test redirect_event.from_url == "$(base_url)/start"
        @test redirect_event.to_url == "$(base_url)/final"
        @test redirect_event.redirect_count == 1
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client request redirect_method override preserves replayable body" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    seen_methods = String[]
    seen_bodies = String[]
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            push!(seen_methods, req1.method)
            push!(seen_bodies, String(_read_all_body_bytes_client(req1.body)))
            headers = HT.Headers()
            HT.setheader(headers, "Location", "/final")
            HT.setheader(headers, "Connection", "close")
            _send_response_client!(conn1, req1; status = 302, reason = "Found", headers = headers, close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            push!(seen_methods, req2.method)
            push!(seen_bodies, String(_read_all_body_bytes_client(req2.body)))
            _send_response_client!(conn2, req2; body_text = "ok", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        return nothing
    end)
    try
        response = HT.request("POST", "$(base_url)/start", Pair{String, String}[], "payload"; redirect_method = :same)
        @test response.status == 200
        @test String(response.body) == "ok"
        _wait_task_client!(server_task)
        @test seen_methods == ["POST", "POST"]
        @test seen_bodies == ["payload", "payload"]
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client QUERY requests retry as idempotent" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    seen_methods = String[]
    seen_bodies = String[]
    server_task = errormonitor(Threads.@spawn begin
        for attempt in 1:2
            conn = NC.accept(listener)
            try
                req = HT.read_request(HT._ConnReader(conn))
                push!(seen_methods, req.method)
                push!(seen_bodies, String(_read_all_body_bytes_client(req.body)))
                if attempt == 1
                    _send_response_client!(
                        conn,
                        req;
                        status = 503,
                        reason = "Service Unavailable",
                        body_text = "retry",
                        close_conn = true,
                    )
                else
                    _send_response_client!(conn, req; body_text = "ok", close_conn = true)
                end
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    try
        response = HT.query(
            "$(base_url)/retry",
            ["Content-Type" => "application/sql"],
            "select 1";
            retries = 1,
        )
        @test response.status == 200
        @test String(response.body) == "ok"
        _wait_task_client!(server_task)
        @test seen_methods == ["QUERY", "QUERY"]
        @test seen_bodies == ["select 1", "select 1"]
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client 307 does not follow non-replayable body redirect" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    callback_body = HT.CallbackBody(
        dst -> begin
            isempty(dst) && return 0
            dst[1] = UInt8('x')
            return 1
        end,
        () -> nothing,
    )
    seen_methods = String[]
    server_close = Channel{Nothing}(1)
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            req = HT.read_request(HT._ConnReader(conn))
            push!(seen_methods, req.method)
            headers = HT.Headers()
            HT.setheader(headers, "Location", "/final")
            _send_response_client!(conn, req; status = 307, reason = "Temporary Redirect", headers = headers, body_text = "redirect")
            status = timedwait(() -> isready(server_close), 5.0; pollint = 0.001)
            status == :timed_out && error("timed out waiting for 307 test client to finish")
            take!(server_close)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4))
    try
        req = HT.Request("POST", "/start"; host = address, body = callback_body, content_length = 1)
        resp = HT.do!(client, address, req)
        @test resp.status == 307
        @test String(_read_all_body_bytes_client(resp.body)) == "redirect"
        put!(server_close, nothing)
        _wait_task_client!(server_task)
        @test seen_methods == ["POST"]
    finally
        isready(server_close) || HTTP.@try_ignore put!(server_close, nothing)
        close(client.transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client redirect referer behavior" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen_referer = Ref{Union{Nothing, String}}(nothing)
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            headers1 = HT.Headers()
            HT.setheader(headers1, "Location", "/next")
            HT.setheader(headers1, "Connection", "close")
            _send_response_client!(conn1, req1; status = 302, reason = "Found", headers = headers1, close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            seen_referer[] = HT.header(req2.headers, "Referer", nothing)
            _send_response_client!(conn2, req2; body_text = "ok", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        return nothing
    end)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4))
    try
        req = HT.Request("GET", "/start"; host = address, body = HT.EmptyBody(), content_length = 0)
        resp = HT.do!(client, address, req)
        @test resp.status == 200
        @test String(_read_all_body_bytes_client(resp.body)) == "ok"
        _wait_task_client!(server_task)
        @test seen_referer[] == "http://$(address)/start"
    finally
        close(client.transport)
        HTTP.@try_ignore NC.close(listener)
    end
    @test HT._redirect_referer(true, "example.com:443", "/secure", false, nothing) === nothing
    @test HT._redirect_referer(false, "example.com:80", "/plain", false, "custom-ref") == "custom-ref"
end

@testset "HTTP client redirect strips sensitive headers for untrusted hosts" begin
    listener1 = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    listener2 = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr1 = NC.addr(listener1)::NC.SocketAddrV4
    laddr2 = NC.addr(listener2)::NC.SocketAddrV4
    address1 = ND.join_host_port("127.0.0.1", Int(laddr1.port))
    address2 = ND.join_host_port("localhost", Int(laddr2.port))
    seen_auth_hop1 = Ref{Union{Nothing, String}}(nothing)
    seen_cookie_hop1 = Ref{Union{Nothing, String}}(nothing)
    seen_auth_hop2 = Ref{Union{Nothing, String}}(nothing)
    seen_cookie_hop2 = Ref{Union{Nothing, String}}(nothing)
    server_task1 = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener1)
        try
            req = HT.read_request(HT._ConnReader(conn))
            seen_auth_hop1[] = HT.header(req.headers, "Authorization", nothing)
            seen_cookie_hop1[] = HT.header(req.headers, "Cookie", nothing)
            headers = HT.Headers()
            HT.setheader(headers, "Location", "http://$(address2)/final")
            HT.setheader(headers, "Connection", "close")
            _send_response_client!(conn, req; status = 302, reason = "Found", headers = headers, close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    server_task2 = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener2)
        try
            req = HT.read_request(HT._ConnReader(conn))
            seen_auth_hop2[] = HT.header(req.headers, "Authorization", nothing)
            seen_cookie_hop2[] = HT.header(req.headers, "Cookie", nothing)
            _send_response_client!(conn, req; body_text = "ok", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4), cookiejar = nothing)
    try
        headers = HT.Headers()
        HT.setheader(headers, "Authorization", "Bearer abc")
        HT.setheader(headers, "Cookie", "session=abc")
        req = HT.Request("GET", "/start"; host = address1, headers = headers, body = HT.EmptyBody(), content_length = 0)
        response = HT.do!(client, address1, req)
        @test response.status == 200
        @test String(_read_all_body_bytes_client(response.body)) == "ok"
        _wait_task_client!(server_task1)
        _wait_task_client!(server_task2)
        @test seen_auth_hop1[] == "Bearer abc"
        @test seen_cookie_hop1[] == "session=abc"
        @test seen_auth_hop2[] === nothing
        @test seen_cookie_hop2[] === nothing
    finally
        close(client.transport)
        HTTP.@try_ignore NC.close(listener1)
        HTTP.@try_ignore NC.close(listener2)
    end
end

@testset "JLSEC redirect does not leak explicit cookies= across origins" begin
    # Two listeners on different ports of 127.0.0.1: a redirect between them is
    # cross-origin under the (scheme, host, port) check. The caller passes the
    # session secret via the `cookies=` kwarg, which the unpatched code
    # re-attached on every hop via `_cookie_header` even after the Cookie header
    # was stripped, leaking it to the redirect target. The fix drops the
    # explicit-kwarg cookies once the origin changes.
    listener1 = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    listener2 = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr1 = NC.addr(listener1)::NC.SocketAddrV4
    laddr2 = NC.addr(listener2)::NC.SocketAddrV4
    address1 = ND.join_host_port("127.0.0.1", Int(laddr1.port))
    address2 = ND.join_host_port("127.0.0.1", Int(laddr2.port))
    seen_cookie_hop1 = Ref{Union{Nothing, String}}(nothing)
    seen_cookie_hop2 = Ref{Union{Nothing, String}}(nothing)
    server_task1 = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener1)
        try
            req = HT.read_request(HT._ConnReader(conn))
            seen_cookie_hop1[] = HT.header(req.headers, "Cookie", nothing)
            headers = HT.Headers()
            HT.setheader(headers, "Location", "http://$(address2)/final")
            HT.setheader(headers, "Connection", "close")
            _send_response_client!(conn, req; status = 302, reason = "Found", headers = headers, close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    server_task2 = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener2)
        try
            req = HT.read_request(HT._ConnReader(conn))
            seen_cookie_hop2[] = HT.header(req.headers, "Cookie", nothing)
            _send_response_client!(conn, req; body_text = "ok", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    # cookiejar=nothing isolates the test from the shared jar; the secret flows
    # only through the explicit cookies= kwarg.
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4), cookiejar = nothing)
    try
        req = HT.Request("GET", "/start"; host = address1, body = HT.EmptyBody(), content_length = 0)
        response = HT.do!(client, address1, req; cookies = Dict("session" => "s3cr3t"))
        @test response.status == 200
        @test String(_read_all_body_bytes_client(response.body)) == "ok"
        _wait_task_client!(server_task1)
        _wait_task_client!(server_task2)
        # Original origin receives the explicit cookie...
        @test seen_cookie_hop1[] == "session=s3cr3t"
        # ...but the cross-origin redirect target must NOT.
        @test seen_cookie_hop2[] === nothing
    finally
        close(client.transport)
        HTTP.@try_ignore NC.close(listener1)
        HTTP.@try_ignore NC.close(listener2)
    end
end

@testset "HTTP client redirect helper strips all duplicate sensitive headers" begin
    headers = HT.Headers()
    push!(headers, "Authorization" => "Bearer one")
    push!(headers, "X-Test" => "keep")
    push!(headers, "Cookie" => "session=abc")
    push!(headers, "Authorization" => "Bearer two")
    push!(headers, "Proxy-Authorization" => "Basic xyz")
    push!(headers, "Cookie" => "session=def")

    HT._strip_sensitive_redirect_headers!(headers)

    @test collect(headers) == ["X-Test" => "keep"]
end

@testset "HTTP client redirect forwardheaders=false clears original headers and stale Host" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    hop1_host = Ref{Union{Nothing, String}}(nothing)
    hop2_host = Ref{Union{Nothing, String}}(nothing)
    hop2_header = Ref{Union{Nothing, String}}(nothing)
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            hop1_host[] = HT.header(req1.headers, "Host", nothing)
            headers = HT.Headers()
            HT.setheader(headers, "Location", "/final")
            HT.setheader(headers, "Connection", "close")
            _send_response_client!(conn1, req1; status = 302, reason = "Found", headers = headers, close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            hop2_host[] = HT.header(req2.headers, "Host", nothing)
            hop2_header[] = HT.header(req2.headers, "X-Test", nothing)
            _send_response_client!(conn2, req2; body_text = "ok", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        return nothing
    end)
    try
        headers = ["Host" => "stale.example", "X-Test" => "abc"]
        response = HT.request("GET", "$(base_url)/start", headers; forwardheaders = false)
        @test response.status == 200
        @test String(response.body) == "ok"
        _wait_task_client!(server_task)
        @test hop1_host[] == "stale.example"
        @test hop2_host[] == address
        @test hop2_header[] === nothing
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client redirect trusted host matching helper" begin
    # Same scheme + same host + same port: sensitive headers may be retained.
    @test HT._should_copy_sensitive_headers_on_redirect("foo.com:443", "foo.com:443", true, true)
    @test HT._should_copy_sensitive_headers_on_redirect("Foo.COM.:443", "foo.com:443", true, true)
    # Bare host vs host:default-port over the same scheme is the same origin.
    @test HT._should_copy_sensitive_headers_on_redirect("foo.com", "foo.com:443", true, true)
    # A child host is a different origin for caller-supplied credentials.
    @test !HT._should_copy_sensitive_headers_on_redirect("foo.com:443", "sub.foo.com:443", true, true)
    # Different host is a different origin.
    @test !HT._should_copy_sensitive_headers_on_redirect("foo.com:443", "bar.com:443", true, true)
end

@testset "JLSEC redirect sensitive-header origin (scheme/port/host) and cookie scoping" begin
    # Scheme downgrade on the same host:port must NOT retain credentials
    # (https -> http replays Authorization/Cookie over plaintext).
    @test !HT._should_copy_sensitive_headers_on_redirect("foo.com:443", "foo.com:80", true, false)
    @test !HT._should_copy_sensitive_headers_on_redirect("foo.com:443", "foo.com:443", true, false)
    # Port change on the same host+scheme must NOT retain credentials
    # (a different service may listen on the alternate port).
    @test !HT._should_copy_sensitive_headers_on_redirect("foo.com:443", "foo.com:8443", true, true)
    @test !HT._should_copy_sensitive_headers_on_redirect("foo.com:80", "foo.com:8080", false, false)
    # Identical full origin retains; same scheme http example.
    @test HT._should_copy_sensitive_headers_on_redirect("foo.com:80", "foo.com:80", false, false)
    # A scheme upgrade (http -> https) is still a scheme change -> strip.
    @test !HT._should_copy_sensitive_headers_on_redirect("foo.com:80", "foo.com:443", false, true)

    # Cross-origin redirect must strip the explicit-kwarg Cookie header so the
    # caller's cookies are not leaked to an attacker-controlled redirect target.
    headers = HT.Headers()
    HT.setheader(headers, "Cookie", "session=secret")
    HT.setheader(headers, "Authorization", "Bearer t0ken")
    HT.setheader(headers, "X-Keep", "keep")
    HT._strip_sensitive_redirect_headers!(headers)
    @test HT.header(headers, "Cookie", nothing) === nothing
    @test HT.header(headers, "Authorization", nothing) === nothing
    @test HT.header(headers, "X-Keep", nothing) == "keep"
end

@testset "HTTP client redirect absolute location default ports" begin
    # `_resolve_redirect_target` returns `(address, secure, target, host_header)`.
    # `address` keeps the dial port; `host_header` mirrors the next hop's authority
    # as written (default port never synthesized), so it feeds `request.host` on a
    # redirect just as `parsed.host_header` does on the initial request.
    address_h2, secure_h2, target_h2, host_h2 = HT._resolve_redirect_target("origin.com:443", true, "https://www.google.com/search", "/", "origin.com")
    @test address_h2 == "www.google.com:443"
    @test secure_h2
    @test target_h2 == "/search"
    @test host_h2 == "www.google.com"

    address_h1, secure_h1, target_h1, host_h1 = HT._resolve_redirect_target("origin.com:80", false, "http://example.com/next", "/", "origin.com")
    @test address_h1 == "example.com:80"
    @test !secure_h1
    @test target_h1 == "/next"
    @test host_h1 == "example.com"

    # An explicit default port in the Location is preserved in the Host header.
    address_exp, secure_exp, target_exp, host_exp = HT._resolve_redirect_target("origin.com:443", true, "https://example.com:443/next", "/", "origin.com")
    @test address_exp == "example.com:443"
    @test host_exp == "example.com:443"

    address_rel, secure_rel, target_rel, host_rel = HT._resolve_redirect_target("origin.com:443", true, "//cdn.example.com/assets", "/", "origin.com")
    @test address_rel == "cdn.example.com:443"
    @test secure_rel
    @test target_rel == "/assets"
    @test host_rel == "cdn.example.com"

    # A same-authority relative redirect carries the current host header through
    # verbatim (it must not regress a bare host back to a default-port form).
    address_dot, secure_dot, target_dot, host_dot = HT._resolve_redirect_target("origin.com:80", false, "../next", "/a/b/c", "origin.com")
    @test address_dot == "origin.com:80"
    @test !secure_dot
    @test target_dot == "/a/next"
    @test host_dot == "origin.com"

    address_query, secure_query, target_query, host_query = HT._resolve_redirect_target("origin.com:80", false, "?q=1", "/a/b/c", "origin.com")
    @test address_query == "origin.com:80"
    @test !secure_query
    @test target_query == "/a/b/c?q=1"
    @test host_query == "origin.com"

    address_frag, secure_frag, target_frag, host_frag = HT._resolve_redirect_target("origin.com:80", false, "#frag", "/a/b/c?x=1", "origin.com")
    @test address_frag == "origin.com:80"
    @test !secure_frag
    @test target_frag == "/a/b/c?x=1"
    @test host_frag == "origin.com"

    @test_throws HT.ProtocolError HT._resolve_redirect_target("origin.com:80", false, "ftp://example.com/file", "/", "origin.com")

    # Low-level `do!` callers may pin `Host` only in headers, leaving
    # `request.host === nothing`. `_resolve_redirect_target` must accept a
    # `nothing` current host (not throw a MethodError on the `::String` arg) and
    # never propagate `nothing` into `request.host` — otherwise the redirected
    # request would carry no `Host` header at all.
    address_nh, secure_nh, target_nh, host_nh = HT._resolve_redirect_target("origin.com:443", true, "https://www.google.com/search", "/", nothing)
    @test address_nh == "www.google.com:443"
    @test host_nh == "www.google.com"  # absolute redirect: from parsed Location
    address_nr, secure_nr, target_nr, host_nr = HT._resolve_redirect_target("origin.com:443", true, "../next", "/a/b/c", nothing)
    @test address_nr == "origin.com:443"
    @test host_nr == "origin.com:443"  # relative redirect, no parsed host: falls back to dial address
end

@testset "do! redirect with header-only Host (request.host === nothing)" begin
    # Low-level `do!` callers may set `Host` only in the request headers, leaving
    # `request.host === nothing`. A relative redirect must still be followed: the
    # threaded `current_host_header` is `nothing` here, and `_resolve_redirect_target`
    # must accept it (not throw a MethodError) and re-establish a `Host` for the
    # next hop rather than dropping it. Regression for PR #1318 review follow-up.
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen_host_hop1 = Ref{Union{Nothing, String}}(nothing)
    seen_host_hop2 = Ref{Union{Nothing, String}}(nothing)
    server_task = errormonitor(Threads.@spawn begin
        # Hop 1: /start -> 302 to a *relative* Location on the same authority.
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            seen_host_hop1[] = HT.header(req1.headers, "Host", nothing)
            headers = HT.Headers()
            HT.setheader(headers, "Location", "/final")
            HT.setheader(headers, "Connection", "close")
            _send_response_client!(conn1, req1; status = 302, reason = "Found", headers = headers, close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        # Hop 2: /final -> 200; capture the Host the client sent after redirect.
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            seen_host_hop2[] = HT.header(req2.headers, "Host", nothing)
            _send_response_client!(conn2, req2; body_text = "ok", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        return nothing
    end)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4), cookiejar = nothing)
    try
        headers = HT.Headers()
        HT.setheader(headers, "Host", address)
        req = HT.Request("GET", "/start"; headers = headers, body = HT.EmptyBody(), content_length = 0)
        @test req.host === nothing
        response = HT.do!(client, address, req; redirect_limit = 1, protocol = :h1)
        @test response.status == 200
        @test String(_read_all_body_bytes_client(response.body)) == "ok"
        _wait_task_client!(server_task)
        @test seen_host_hop1[] == address
        # The redirected request still carries a Host header (re-established from
        # the dial address since the caller provided no parsed host).
        @test seen_host_hop2[] == address
    finally
        close(client.transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "streaming request Host mirrors URL authority as written" begin
    # `HTTP.open`/streaming builds its `Request` from `_client_stream_request`,
    # which must use `host_header` (authority as written), not the dial
    # `address` (which always carries a port). Otherwise a default-port URL
    # leaks `Host: example.com:443` and breaks AWS SigV4, exactly as the
    # high-level path did.
    bare = HT._client_stream_request("PUT", HT._parse_http_url("https://example.com/upload"), HT.Headers(), Int64(0), nothing)
    @test bare.host == "example.com"

    explicit = HT._client_stream_request("PUT", HT._parse_http_url("https://example.com:443/upload"), HT.Headers(), Int64(0), nothing)
    @test explicit.host == "example.com:443"

    custom = HT._client_stream_request("PUT", HT._parse_http_url("http://minio:9000/bucket/key"), HT.Headers(), Int64(0), nothing)
    @test custom.host == "minio:9000"

    ipv6 = HT._client_stream_request("GET", HT._parse_http_url("https://[2001:db8::1]/x"), HT.Headers(), Int64(0), nothing)
    @test ipv6.host == "[2001:db8::1]"
end

@testset "HTTP high-level redirect derives TLS server name per hop" begin
    cert_file = joinpath(@__DIR__, "resources", "localhost-only.crt")
    key_file = joinpath(@__DIR__, "resources", "localhost-only.key")
    for api in (:request, :open)
        plain_listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
        tls_listener = TL.listen(
            "tcp",
            "127.0.0.1:0",
            TL.Config(
                verify_peer = false,
                cert_file = cert_file,
                key_file = key_file,
            );
            backlog = 8,
        )
        plain_addr = NC.addr(plain_listener)::NC.SocketAddrV4
        tls_addr = TL.addr(tls_listener)::NC.SocketAddrV4
        plain_address = ND.join_host_port("127.0.0.1", Int(plain_addr.port))
        tls_address = ND.join_host_port("localhost", Int(tls_addr.port))
        plain_task = errormonitor(Threads.@spawn begin
            conn = NC.accept(plain_listener)
            try
                req = HT.read_request(HT._ConnReader(conn))
                headers = HT.Headers()
                HT.setheader(headers, "Location", "https://$(tls_address)/final")
                HT.setheader(headers, "Connection", "close")
                _send_response_client!(conn, req; status = 302, reason = "Found", headers = headers, close_conn = true)
            finally
                HTTP.@try_ignore NC.close(conn)
            end
            return nothing
        end)
        tls_server = HT.serve!(tls_listener) do request
            return HT.Response(200, "ok:" * request.target)
        end
        client = HT.Client(
            transport = HT.Transport(
                tls_config = TL.Config(verify_peer = false, verify_hostname = true),
                max_idle_per_host = 4,
                max_idle_total = 4,
            ),
            prefer_http2 = false,
        )
        try
            url = "http://$(plain_address)/start"
            if api === :request
                response = HT.get(url; client = client, protocol = :h1)
                @test response.status == 200
                @test String(response.body) == "ok:/final"
            else
                response = HT.open(:GET, url; client = client, protocol = :h1) do stream
                    meta = HT.startread(stream)
                    @test meta.status == 200
                    @test String(read(stream)) == "ok:/final"
                end
                @test response.status == 200
            end
            _wait_task_client!(plain_task)
        finally
            close(client)
            HT.forceclose(tls_server)
            wait(tls_server)
            HTTP.@try_ignore NC.close(plain_listener)
        end
    end
end

@testset "HTTP high-level request redirect=false and redirect_limit=0 return redirect responses" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:2
            conn = NC.accept(listener)
            try
                req = HT.read_request(HT._ConnReader(conn))
                headers = HT.Headers()
                HT.setheader(headers, "Location", "/final")
                HT.setheader(headers, "Connection", "close")
                _send_response_client!(conn, req; status = 302, reason = "Found", headers = headers, body_text = "redirect", close_conn = true)
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    try
        resp_disabled = HT.get("$(base_url)/disabled"; redirect = false)
        @test resp_disabled.status == 302
        @test String(resp_disabled.body) == "redirect"
        @test resp_disabled.url == "$(base_url)/disabled"
        @test resp_disabled.redirect_count == 0
        @test resp_disabled.previous === nothing

        resp_limit0 = HT.get("$(base_url)/limit-zero"; redirect_limit = 0)
        @test resp_limit0.status == 302
        @test String(resp_limit0.body) == "redirect"
        @test resp_limit0.url == "$(base_url)/limit-zero"
        @test resp_limit0.redirect_count == 0
        @test resp_limit0.previous === nothing

        _wait_task_client!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client redirect metadata and limit errors" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:4
            conn = NC.accept(listener)
            try
                req = HT.read_request(HT._ConnReader(conn))
                headers = HT.Headers()
                if req.target == "/start"
                    HT.setheader(headers, "Location", "/final")
                    HT.setheader(headers, "Connection", "close")
                    _send_response_client!(conn, req; status = 302, reason = "Found", headers = headers, body_text = "hop1", close_conn = true)
                elseif req.target == "/final"
                    _send_response_client!(conn, req; body_text = "ok", close_conn = true)
                elseif req.target == "/limit-start"
                    HT.setheader(headers, "Location", "/limit-next")
                    HT.setheader(headers, "Connection", "close")
                    _send_response_client!(conn, req; status = 302, reason = "Found", headers = headers, body_text = "limit1", close_conn = true)
                elseif req.target == "/limit-next"
                    HT.setheader(headers, "Location", "/limit-last")
                    HT.setheader(headers, "Connection", "close")
                    _send_response_client!(conn, req; status = 302, reason = "Found", headers = headers, body_text = "limit2", close_conn = true)
                else
                    _send_response_client!(conn, req; status = 500, reason = "Unexpected", body_text = req.target, close_conn = true)
                end
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    try
        resp = HT.get("$(base_url)/start")
        @test resp.status == 200
        @test String(resp.body) == "ok"
        @test resp.url == "$(base_url)/final"
        @test resp.redirect_count == 1
        @test resp.request !== nothing
        @test resp.request.target == "/final"
        @test resp.previous !== nothing
        @test resp.previous.status == 302
        @test resp.previous.url == "$(base_url)/start"
        @test resp.previous.redirect_count == 0
        @test resp.previous.request !== nothing
        @test resp.previous.request.target == "/start"
        @test resp.request !== resp.previous.request

        err = try
            HT.get("$(base_url)/limit-start"; redirect_limit = 1)
            nothing
        catch caught
            caught
        end
        @test err isa HT.TooManyRedirectsError
        if err isa HT.TooManyRedirectsError
            @test err.limit == 1
            @test err.response.status == 302
            @test err.response.url == "$(base_url)/limit-next"
            @test err.response.redirect_count == 1
            @test err.response.previous !== nothing
            @test err.response.previous.url == "$(base_url)/limit-start"
        end

        _wait_task_client!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client cookie jar round-trip" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    cookie_header_seen = Ref{Union{Nothing, String}}(nothing)
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            _ = req1
            headers1 = HT.Headers()
            HT.appendheader(headers1, "Set-Cookie", "session=abc; Path=/")
            HT.setheader(headers1, "Connection", "close")
            _send_response_client!(conn1, req1; body_text = "set", headers = headers1, close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            cookie_header_seen[] = HT.header(req2.headers, "Cookie", nothing)
            _send_response_client!(conn2, req2; body_text = "ok")
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        return nothing
    end)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4), cookiejar = HT.CookieJar())
    try
        r1 = HT.get!(client, address, "/set")
        @test String(_read_all_body_bytes_client(r1.body)) == "set"
        r2 = HT.get!(client, address, "/check")
        @test String(_read_all_body_bytes_client(r2.body)) == "ok"
        _wait_task_client!(server_task)
        @test cookie_header_seen[] == "session=abc"
    finally
        close(client.transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP high-level request cookiejar and cookies kwargs" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    cookie_header_seen = Ref{Union{Nothing, String}}(nothing)
    cookie_header_disabled = Ref{Union{Nothing, String}}(nothing)
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            headers1 = HT.Headers()
            HT.appendheader(headers1, "Set-Cookie", "session=abc; Path=/")
            HT.setheader(headers1, "Connection", "close")
            _send_response_client!(conn1, req1; body_text = "set", headers = headers1, close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            cookie_header_seen[] = HT.header(req2.headers, "Cookie", nothing)
            _send_response_client!(conn2, req2; body_text = "check", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        conn3 = NC.accept(listener)
        try
            req3 = HT.read_request(HT._ConnReader(conn3))
            cookie_header_disabled[] = HT.header(req3.headers, "Cookie", nothing)
            _send_response_client!(conn3, req3; body_text = "disabled", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn3)
        end
        return nothing
    end)
    jar = HT.CookieJar()
    try
        r1 = HT.get("$(base_url)/set"; cookiejar = jar)
        @test String(r1.body) == "set"

        r2 = HT.get("$(base_url)/check"; cookiejar = jar, cookies = Dict("extra" => "1"))
        @test String(r2.body) == "check"

        r3 = HT.get("$(base_url)/disabled"; cookiejar = jar, cookies = false)
        @test String(r3.body) == "disabled"

        _wait_task_client!(server_task)
        @test cookie_header_seen[] == "session=abc; extra=1"
        @test cookie_header_disabled[] === nothing
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP.open respects cookiejar kwargs" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    cookie_header_seen = Ref{Union{Nothing, String}}(nothing)
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            headers1 = HT.Headers()
            HT.appendheader(headers1, "Set-Cookie", "streamcookie=abc; Path=/")
            HT.setheader(headers1, "Connection", "close")
            _send_response_client!(conn1, req1; body_text = "set", headers = headers1, close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn1)
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            cookie_header_seen[] = HT.header(req2.headers, "Cookie", nothing)
            _send_response_client!(conn2, req2; body_text = "stream", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn2)
        end
        return nothing
    end)
    jar = HT.CookieJar()
    try
        r1 = HT.get("$(base_url)/set"; cookiejar = jar)
        @test String(r1.body) == "set"

        r2 = HT.open(:GET, "$(base_url)/stream"; cookiejar = jar) do stream
            @test String(read(stream)) == "stream"
        end
        @test r2.status == 200

        _wait_task_client!(server_task)
        @test cookie_header_seen[] == "streamcookie=abc"
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end


@testset "HTTP high-level request interface" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    seen_targets = String[]
    seen_header = Ref{Union{Nothing, String}}(nothing)
    seen_auth = Union{Nothing, String}[]
    seen_query_methods = String[]
    seen_query_bodies = String[]
    seen_query_content_types = Union{Nothing, String}[]
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:17
            conn = NC.accept(listener)
            try
                req = HT.read_request(HT._ConnReader(conn))
                push!(seen_targets, req.target)
                if req.target == "/hello"
                    _send_response_client!(conn, req; body_text = "hello", close_conn = true)
                elseif startswith(req.target, "/query?")
                    _send_response_client!(conn, req; body_text = req.target, close_conn = true)
                elseif req.target == "/echo"
                    seen_header[] = HT.header(req.headers, "X-Token", nothing)
                    payload = String(_read_all_body_bytes_client(req.body))
                    _send_response_client!(conn, req; body_text = payload, close_conn = true)
                elseif req.target == "/body-query" || req.target == "/body-query-client"
                    push!(seen_query_methods, req.method)
                    push!(seen_query_bodies, String(_read_all_body_bytes_client(req.body)))
                    push!(seen_query_content_types, HT.header(req.headers, "Content-Type", nothing))
                    _send_response_client!(conn, req; body_text = "query:" * seen_query_bodies[end], close_conn = true)
                elseif startswith(req.target, "/encoded?")
                    _send_response_client!(conn, req; body_text = req.target, close_conn = true)
                elseif req.target == "/auth" || req.target == "/auth-url" || req.target == "/auth-url-uri" || req.target == "/auth-header"
                    push!(seen_auth, HT.header(req.headers, "Authorization", nothing))
                    _send_response_client!(conn, req; body_text = "auth-ok", close_conn = true)
                elseif req.target == "/missing"
                    _send_response_client!(conn, req; status = 404, reason = "Not Found", body_text = "missing", close_conn = true)
                else
                    _send_response_client!(conn, req; status = 500, reason = "Unexpected", body_text = req.target, close_conn = true)
                end
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    try
        resp_hello = HT.get("$(base_url)/hello")
        @test resp_hello.status == 200
        @test String(resp_hello.body) == "hello"

        uri_hello = HT.URI("$(base_url)/hello")
        resp_uri = HT.get(uri_hello)
        @test resp_uri.status == 200
        @test String(resp_uri.body) == "hello"

        resp_symbol = HT.request(:GET, "$(base_url)/hello")
        @test resp_symbol.status == 200
        @test String(resp_symbol.body) == "hello"

        resp_symbol_uri = HT.request(:GET, uri_hello)
        @test resp_symbol_uri.status == 200
        @test String(resp_symbol_uri.body) == "hello"

        resp_query = HT.get("$(base_url)/query"; query = Dict("a" => 1, "b" => 2))
        @test resp_query.status == 200
        @test String(resp_query.body) == "/query?a=1&b=2"

        resp_query_uri = HT.get(HT.URI("$(base_url)/query?x=0"); query = Dict("a" => 1, "b" => 2))
        @test resp_query_uri.status == 200
        @test String(resp_query_uri.body) == "/query?x=0&a=1&b=2"

        resp_encoded = HT.get("$(base_url)/encoded"; query = Dict("a b" => "c+d", "slash" => "/x"))
        @test resp_encoded.status == 200
        @test String(resp_encoded.body) == "/encoded?a%20b=c%2Bd&slash=%2Fx"

        resp_echo = HT.post("$(base_url)/echo", ["X-Token" => "abc123"], "payload")
        @test resp_echo.status == 200
        @test String(resp_echo.body) == "payload"
        @test seen_header[] == "abc123"

        resp_echo_uri = HT.post(HT.URI("$(base_url)/echo"), ["X-Token" => "xyz789"], "payload-uri")
        @test resp_echo_uri.status == 200
        @test String(resp_echo_uri.body) == "payload-uri"
        @test seen_header[] == "xyz789"

        resp_body_query = HT.query("$(base_url)/body-query"; body = (select = "name", limit = 10))
        @test resp_body_query.status == 200
        @test String(resp_body_query.body) == "query:select=name&limit=10"

        query_client = HT.Client()
        try
            resp_client_query = HT.query(
                query_client,
                "$(base_url)/body-query-client",
                ["Content-Type" => "application/sql"],
                "select 1",
            )
            @test resp_client_query.status == 200
            @test String(resp_client_query.body) == "query:select 1"
        finally
            close(query_client)
        end

        resp_auth = HT.get("$(base_url)/auth"; basicauth = ("alice", "secret"))
        @test resp_auth.status == 200
        @test String(resp_auth.body) == "auth-ok"

        resp_auth_url = HT.get("http://alice:secret@$(address)/auth-url")
        @test resp_auth_url.status == 200
        @test String(resp_auth_url.body) == "auth-ok"

        override_headers = HT.Headers()
        HT.setheader(override_headers, "Authorization", "Bearer override")
        resp_auth_header = HT.get("http://ignored:ignored@$(address)/auth-header", override_headers; basicauth = ("alice", "secret"))
        @test resp_auth_header.status == 200
        @test String(resp_auth_header.body) == "auth-ok"
        resp_auth_uri = HT.get(HT.URI("http://alice:secret@$(address)/auth-url-uri"))
        @test resp_auth_uri.status == 200
        @test String(resp_auth_uri.body) == "auth-ok"
        @test seen_auth == [
            "Basic YWxpY2U6c2VjcmV0",
            "Basic YWxpY2U6c2VjcmV0",
            "Bearer override",
            "Basic YWxpY2U6c2VjcmV0",
        ]

        resp_missing = HT.get("$(base_url)/missing"; status_exception = false)
        @test resp_missing.status == 404
        @test String(resp_missing.body) == "missing"

        status_err = try
            HT.get("$(base_url)/missing")
            nothing
        catch err
            err
        end
        @test status_err isa HT.StatusError
        if status_err isa HT.StatusError
            @test status_err.response.status == 404
            @test status_err.response.url == "$(base_url)/missing"
        end

        parsed = HT._parse_http_url("http://alice:secret@$(address)/lazy/path?x=1#frag", Dict("y" => 2))
        @test !parsed.secure
        @test parsed.address == "$(address)"
        @test parsed.address === parsed.address
        @test parsed.target == "/lazy/path?x=1&y=2"
        @test parsed.target === parsed.target
        @test parsed.server_name == "127.0.0.1"
        @test parsed.server_name === parsed.server_name
        @test parsed.url == "http://$(address)/lazy/path?x=1&y=2"
        @test parsed.url === parsed.url
        @test parsed.authorization == "Basic YWxpY2U6c2VjcmV0"
        @test parsed.authorization === parsed.authorization

        parsed_uri = HT._parse_http_url(HT.URI("http://alice:secret@$(address)/lazy/path?x=1#frag"), Dict("y" => 2))
        @test !parsed_uri.secure
        @test parsed_uri.address == "$(address)"
        @test parsed_uri.address === parsed_uri.address
        @test parsed_uri.target == "/lazy/path?x=1&y=2"
        @test parsed_uri.target === parsed_uri.target
        @test parsed_uri.server_name == "127.0.0.1"
        @test parsed_uri.server_name === parsed_uri.server_name
        @test parsed_uri.url == "http://$(address)/lazy/path?x=1&y=2"
        @test parsed_uri.url === parsed_uri.url
        @test parsed_uri.authorization == "Basic YWxpY2U6c2VjcmV0"
        @test parsed_uri.authorization === parsed_uri.authorization

        parsed_query = HT._parse_http_url("https://example.com?x=1", Dict("y" => 2))
        @test parsed_query.secure
        @test parsed_query.address == "example.com:443"
        @test parsed_query.target == "/?x=1&y=2"
        @test parsed_query.server_name == "example.com"
        @test parsed_query.url == "https://example.com:443/?x=1&y=2"
        @test parsed_query.authorization === nothing
        # `host_header` mirrors the URL authority: the synthesized default port
        # is never added (so the `Host` header stays `example.com`, matching the
        # bare host servers like AWS SigV4 sign over), while `address` keeps the
        # port for dialing.
        @test parsed_query.host_header == "example.com"

        parsed_default_port = HT._parse_http_url("https://example.com:443/explicit")
        @test parsed_default_port.address == "example.com:443"
        # An explicitly-written default port is preserved verbatim (as in Go).
        @test parsed_default_port.host_header == "example.com:443"

        parsed_http_default = HT._parse_http_url("http://example.com/plain")
        @test parsed_http_default.address == "example.com:80"
        @test parsed_http_default.host_header == "example.com"

        parsed_custom_port = HT._parse_http_url("http://minio:9000/bucket/key")
        @test parsed_custom_port.address == "minio:9000"
        @test parsed_custom_port.host_header == "minio:9000"

        parsed_query_uri = HT._parse_http_url(HT.URI("https://example.com?x=1"), Dict("y" => 2))
        @test parsed_query_uri.secure
        @test parsed_query_uri.address == "example.com:443"
        @test parsed_query_uri.target == "/?x=1&y=2"
        @test parsed_query_uri.server_name == "example.com"
        @test parsed_query_uri.url == "https://example.com:443/?x=1&y=2"
        @test parsed_query_uri.authorization === nothing

        parsed_tuple_query = HT._parse_http_url("https://example.com/tuple", [("b", 2), "a" => "one"])
        @test parsed_tuple_query.target == "/tuple?b=2&a=one"
        @test parsed_tuple_query.url == "https://example.com:443/tuple?b=2&a=one"
        @test_throws ArgumentError HT._parse_http_url("https://example.com/invalid", [("ok", 1, 2)])
        @test_throws ArgumentError HT._parse_http_url("https://example.com/invalid", 42)

        parsed_ipv6 = HT._parse_http_url("https://[2001:db8::1]/ipv6")
        @test parsed_ipv6.address == "[2001:db8::1]:443"
        @test parsed_ipv6.target == "/ipv6"
        @test parsed_ipv6.server_name == "2001:db8::1"
        @test parsed_ipv6.url == "https://[2001:db8::1]:443/ipv6"
        @test parsed_ipv6.authorization === nothing
        # IPv6 Host headers keep their brackets (unlike `server_name`).
        @test parsed_ipv6.host_header == "[2001:db8::1]"

        parsed_ipv6_port = HT._parse_http_url("https://[2001:db8::1]:8443/ipv6")
        @test parsed_ipv6_port.address == "[2001:db8::1]:8443"
        @test parsed_ipv6_port.server_name == "2001:db8::1"
        @test parsed_ipv6_port.url == "https://[2001:db8::1]:8443/ipv6"
        @test parsed_ipv6_port.host_header == "[2001:db8::1]:8443"

        parsed_ipv6_uri = HT._parse_http_url(HT.URI("https://[2001:db8::1]/ipv6"))
        @test parsed_ipv6_uri.address == "[2001:db8::1]:443"
        @test parsed_ipv6_uri.target == "/ipv6"
        @test parsed_ipv6_uri.server_name == "2001:db8::1"
        @test parsed_ipv6_uri.url == "https://[2001:db8::1]:443/ipv6"
        @test parsed_ipv6_uri.authorization === nothing

        _wait_task_client!(server_task)
        @test "/hello" in seen_targets
        @test "/echo" in seen_targets
        @test "/query?a=1&b=2" in seen_targets
        @test "/query?x=0&a=1&b=2" in seen_targets
        @test "/body-query" in seen_targets
        @test "/body-query-client" in seen_targets
        @test "/encoded?a%20b=c%2Bd&slash=%2Fx" in seen_targets
        @test "/auth" in seen_targets
        @test "/auth-url" in seen_targets
        @test "/auth-url-uri" in seen_targets
        @test "/auth-header" in seen_targets
        @test seen_query_methods == ["QUERY", "QUERY"]
        @test seen_query_bodies == ["select=name&limit=10", "select 1"]
        @test seen_query_content_types == ["application/x-www-form-urlencoded", "application/sql"]
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP high-level response streaming and decompression" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    accept_encodings = Dict{String, Union{Nothing, String}}()
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:14
            conn = NC.accept(listener)
            try
                req = HT.read_request(HT._ConnReader(conn))
                if req.target == "/stream"
                    _send_response_client!(conn, req; body_text = "stream-body", close_conn = true)
                elseif req.target == "/buffer"
                    _send_response_client!(conn, req; body_text = "buffer-body", close_conn = true)
                elseif req.target == "/too-small"
                    _send_response_client!(conn, req; body_text = "overflow", close_conn = true)
                elseif req.target == "/gzip-default"
                    accept_encodings[req.target] = HT.header(req.headers, "Accept-Encoding", nothing)
                    payload = _gzip_bytes_client("gzip-default")
                    headers = HT.Headers()
                    HT.setheader(headers, "Content-Encoding", "gzip")
                    _send_response_bytes_client!(conn, req; body_bytes = payload, headers = headers, close_conn = true)
                elseif req.target == "/gzip-off"
                    accept_encodings[req.target] = HT.header(req.headers, "Accept-Encoding", nothing)
                    payload = _gzip_bytes_client("gzip-off")
                    headers = HT.Headers()
                    HT.setheader(headers, "Content-Encoding", "gzip")
                    _send_response_bytes_client!(conn, req; body_bytes = payload, headers = headers, close_conn = true)
                elseif req.target == "/gzip-stream"
                    accept_encodings[req.target] = HT.header(req.headers, "Accept-Encoding", nothing)
                    payload = _gzip_bytes_client("gzip-stream")
                    headers = HT.Headers()
                    HT.setheader(headers, "Content-Encoding", "gzip")
                    _send_response_bytes_client!(conn, req; body_bytes = payload, headers = headers, close_conn = true)
                elseif req.target == "/gzip-buffer"
                    accept_encodings[req.target] = HT.header(req.headers, "Accept-Encoding", nothing)
                    payload = _gzip_bytes_client("gzip-buffer")
                    headers = HT.Headers()
                    HT.setheader(headers, "Content-Encoding", "gzip")
                    _send_response_bytes_client!(conn, req; body_bytes = payload, headers = headers, close_conn = true)
                elseif req.target == "/gzip-too-small"
                    accept_encodings[req.target] = HT.header(req.headers, "Accept-Encoding", nothing)
                    payload = _gzip_bytes_client("overflow")
                    headers = HT.Headers()
                    HT.setheader(headers, "Content-Encoding", "gzip")
                    _send_response_bytes_client!(conn, req; body_bytes = payload, headers = headers, close_conn = true)
                elseif req.target == "/gzip-empty-304"
                    accept_encodings[req.target] = HT.header(req.headers, "Accept-Encoding", nothing)
                    headers = HT.Headers()
                    HT.setheader(headers, "Content-Encoding", "gzip")
                    _send_response_bytes_client!(conn, req; status = 304, reason = "Not Modified", body_bytes = UInt8[], headers = headers, close_conn = true)
                elseif req.target == "/deflate-default"
                    accept_encodings[req.target] = HT.header(req.headers, "Accept-Encoding", nothing)
                    payload = _deflate_bytes_client("deflate-default")
                    headers = HT.Headers()
                    HT.setheader(headers, "Content-Encoding", "deflate")
                    _send_response_bytes_client!(conn, req; body_bytes = payload, headers = headers, close_conn = true)
                elseif req.target == "/deflate-off"
                    accept_encodings[req.target] = HT.header(req.headers, "Accept-Encoding", nothing)
                    payload = _deflate_bytes_client("deflate-off")
                    headers = HT.Headers()
                    HT.setheader(headers, "Content-Encoding", "deflate")
                    _send_response_bytes_client!(conn, req; body_bytes = payload, headers = headers, close_conn = true)
                elseif req.target == "/deflate-stream"
                    accept_encodings[req.target] = HT.header(req.headers, "Accept-Encoding", nothing)
                    payload = _deflate_bytes_client("deflate-stream")
                    headers = HT.Headers()
                    HT.setheader(headers, "Content-Encoding", "deflate")
                    _send_response_bytes_client!(conn, req; body_bytes = payload, headers = headers, close_conn = true)
                elseif req.target == "/deflate-buffer"
                    accept_encodings[req.target] = HT.header(req.headers, "Accept-Encoding", nothing)
                    payload = _deflate_bytes_client("deflate-buffer")
                    headers = HT.Headers()
                    HT.setheader(headers, "Content-Encoding", "deflate")
                    _send_response_bytes_client!(conn, req; body_bytes = payload, headers = headers, close_conn = true)
                elseif req.target == "/accept-encoding-empty"
                    accept_encodings[req.target] = HT.header(req.headers, "Accept-Encoding", nothing)
                    _send_response_client!(conn, req; body_text = "ok", close_conn = true)
                else
                    _send_response_client!(conn, req; status = 500, reason = "Unexpected", body_text = req.target, close_conn = true)
                end
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    try
        streamed = IOBuffer()
        resp_stream = HT.get("$(base_url)/stream"; response_stream = streamed)
        @test resp_stream.status == 200
        @test resp_stream.body === nothing
        @test String(take!(streamed)) == "stream-body"

        buffer = Vector{UInt8}(undef, 32)
        resp_buffer = HT.get("$(base_url)/buffer"; response_stream = buffer)
        @test resp_buffer.status == 200
        @test resp_buffer.body === buffer
        @test String(resp_buffer.body) == "buffer-body"

        small_err = try
            HT.get("$(base_url)/too-small"; response_stream = Vector{UInt8}(undef, 2))
            nothing
        catch err
            err
        end
        @test small_err isa ArgumentError
        if small_err isa ArgumentError
            @test occursin("Unable to grow response stream IOBuffer", sprint(showerror, small_err))
        end

        resp_gzip = HT.get("$(base_url)/gzip-default")
        @test resp_gzip.status == 200
        @test String(resp_gzip.body) == "gzip-default"
        @test accept_encodings["/gzip-default"] == "gzip, deflate"

        resp_gzip_raw = HT.get("$(base_url)/gzip-off"; decompress = false)
        @test resp_gzip_raw.status == 200
        @test String(read(HTTP.CodecZlib.GzipDecompressorStream(IOBuffer(resp_gzip_raw.body)))) == "gzip-off"
        @test accept_encodings["/gzip-off"] === nothing

        streamed_gzip = IOBuffer()
        resp_gzip_stream = HT.get("$(base_url)/gzip-stream"; response_stream = streamed_gzip, decompress = true)
        @test resp_gzip_stream.status == 200
        @test resp_gzip_stream.body === nothing
        @test String(take!(streamed_gzip)) == "gzip-stream"
        @test accept_encodings["/gzip-stream"] == "gzip, deflate"

        gzip_buffer = Vector{UInt8}(undef, 32)
        resp_gzip_buffer = HT.get("$(base_url)/gzip-buffer"; response_stream = gzip_buffer, decompress = true)
        @test resp_gzip_buffer.status == 200
        @test resp_gzip_buffer.body === gzip_buffer
        @test String(resp_gzip_buffer.body) == "gzip-buffer"
        @test accept_encodings["/gzip-buffer"] == "gzip, deflate"

        gzip_small_err = try
            HT.get("$(base_url)/gzip-too-small"; response_stream = Vector{UInt8}(undef, 2), decompress = true)
            nothing
        catch err
            err
        end
        @test gzip_small_err isa ArgumentError
        if gzip_small_err isa ArgumentError
            @test occursin("Unable to grow response stream IOBuffer", sprint(showerror, gzip_small_err))
        end
        @test accept_encodings["/gzip-too-small"] == "gzip, deflate"

        resp_gzip_empty_304 = HT.get("$(base_url)/gzip-empty-304"; status_exception = false)
        @test resp_gzip_empty_304.status == 304
        @test resp_gzip_empty_304.body == UInt8[]
        @test accept_encodings["/gzip-empty-304"] == "gzip, deflate"

        resp_deflate = HT.get("$(base_url)/deflate-default")
        @test resp_deflate.status == 200
        @test String(resp_deflate.body) == "deflate-default"
        @test accept_encodings["/deflate-default"] == "gzip, deflate"

        resp_deflate_raw = HT.get("$(base_url)/deflate-off"; decompress = false)
        @test resp_deflate_raw.status == 200
        @test String(read(HTTP.CodecZlib.ZlibDecompressorStream(IOBuffer(resp_deflate_raw.body)))) == "deflate-off"
        @test accept_encodings["/deflate-off"] === nothing

        streamed_deflate = IOBuffer()
        resp_deflate_stream = HT.get("$(base_url)/deflate-stream"; response_stream = streamed_deflate, decompress = true)
        @test resp_deflate_stream.status == 200
        @test resp_deflate_stream.body === nothing
        @test String(take!(streamed_deflate)) == "deflate-stream"
        @test accept_encodings["/deflate-stream"] == "gzip, deflate"

        deflate_buffer = Vector{UInt8}(undef, 32)
        resp_deflate_buffer = HT.get("$(base_url)/deflate-buffer"; response_stream = deflate_buffer, decompress = true)
        @test resp_deflate_buffer.status == 200
        @test resp_deflate_buffer.body === deflate_buffer
        @test String(resp_deflate_buffer.body) == "deflate-buffer"
        @test accept_encodings["/deflate-buffer"] == "gzip, deflate"

        # RFC 9110 §12.5.3: an explicit Accept-Encoding: "" must not be overwritten
        resp_ae_empty = HT.get("$(base_url)/accept-encoding-empty"; headers = ["Accept-Encoding" => ""])
        @test resp_ae_empty.status == 200
        @test accept_encodings["/accept-encoding-empty"] == ""

        _wait_task_client!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP high-level request body inputs" begin
    if _http_windows_ci()
        @test_skip true
    else
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    seen_bodies = Dict{String, String}()
    seen_content_types = Dict{String, Union{Nothing, String}}()
    multipart_parts = Ref{Union{Nothing, Vector{HT.Multipart}}}(nothing)
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:5
            conn = NC.accept(listener)
            try
                req = HT.read_request(HT._ConnReader(conn))
                body_bytes = _read_all_body_bytes_client(req.body)
                seen_content_types[req.target] = HT.header(req.headers, "Content-Type", nothing)
                if req.target == "/multipart"
                    multipart_parts[] = HT.parse_multipart_form(seen_content_types[req.target], body_bytes)
                    _send_response_client!(conn, req; body_text = "multipart", close_conn = true)
                else
                    body_text = String(copy(body_bytes))
                    seen_bodies[req.target] = body_text
                    _send_response_client!(conn, req; body_text = body_text, close_conn = true)
                end
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    try
        resp_dict = HT.post("$(base_url)/dict"; body = Dict("name" => "value with spaces"))
        @test resp_dict.status == 200
        @test String(resp_dict.body) == "name=value+with+spaces"

        resp_named = HT.post("$(base_url)/named"; body = (name = "value",))
        @test resp_named.status == 200
        @test String(resp_named.body) == "name=value"

        resp_iter = HT.post("$(base_url)/iter"; body = ["hey", " there ", "sailor"])
        @test resp_iter.status == 200
        @test String(resp_iter.body) == "hey there sailor"

        producer = Base.BufferStream()
        producer_task = errormonitor(Threads.@spawn HT.post("$(base_url)/stream"; body = producer))
        write(producer, "hello")
        write(producer, " world")
        close(producer)
        resp_stream = fetch(producer_task)
        @test resp_stream.status == 200
        @test String(resp_stream.body) == "hello world"

        form = HT.Form(Dict(
            "field" => "value",
            "upload" => HT.Multipart("file.txt", IOBuffer("multipart-body"), "text/plain"),
        ))
        resp_form = HT.post("$(base_url)/multipart"; body = form)
        @test resp_form.status == 200
        @test String(resp_form.body) == "multipart"

        _wait_task_client!(server_task)
        @test seen_bodies["/dict"] == "name=value+with+spaces"
        @test seen_content_types["/dict"] == "application/x-www-form-urlencoded"
        @test seen_bodies["/named"] == "name=value"
        @test seen_content_types["/named"] == "application/x-www-form-urlencoded"
        @test seen_bodies["/iter"] == "hey there sailor"
        @test seen_content_types["/iter"] === nothing
        @test seen_bodies["/stream"] == "hello world"
        @test seen_content_types["/stream"] === nothing
        @test multipart_parts[] !== nothing
        @test startswith(seen_content_types["/multipart"]::String, "multipart/form-data; boundary=")
        parts = multipart_parts[]::Vector{HT.Multipart}
        @test length(parts) == 2
        @test any(part -> part.name == "field" && String(read(part)) == "value", parts)
        @test any(part -> part.name == "upload" && part.filename == "file.txt" && String(read(part)) == "multipart-body", parts)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
    end
end

@testset "HTTP.open streaming interface" begin
    if _http_windows_ci()
        @test_skip true
    else
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    seen_open_auth = Ref{Union{Nothing, String}}(nothing)
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:8
            conn = NC.accept(listener)
            try
                req = HT.read_request(HT._ConnReader(conn))
                if req.target == "/open-get"
                    _send_response_client!(conn, req; body_text = "open-get", close_conn = true)
                elseif req.target == "/open-post"
                    payload = String(_read_all_body_bytes_client(req.body))
                    _send_response_client!(conn, req; body_text = payload, close_conn = true)
                elseif req.target == "/open-redirect"
                    headers = HT.Headers()
                    HT.setheader(headers, "Location", "/open-redirect-final")
                    HT.setheader(headers, "Connection", "close")
                    _send_response_client!(conn, req; status = 302, reason = "Found", headers = headers, close_conn = true)
                elseif req.target == "/open-redirect-final"
                    payload = String(_read_all_body_bytes_client(req.body))
                    _send_response_client!(conn, req; body_text = payload, close_conn = true)
                elseif req.target == "/open-limit"
                    headers = HT.Headers()
                    HT.setheader(headers, "Location", "/open-never")
                    HT.setheader(headers, "Connection", "close")
                    _send_response_client!(conn, req; status = 302, reason = "Found", headers = headers, body_text = "open-limit", close_conn = true)
                elseif req.target == "/open-auth"
                    seen_open_auth[] = HT.header(req.headers, "Authorization", nothing)
                    _send_response_client!(conn, req; body_text = "open-auth", close_conn = true)
                elseif req.target == "/open-abort"
                    _send_response_client!(conn, req; status = 500, reason = "Abort", body_text = "open-abort", close_conn = true)
                elseif req.target == "/open-error"
                    _send_response_client!(conn, req; body_text = "open-error", close_conn = true)
                else
                    _send_response_client!(conn, req; status = 500, reason = "Unexpected", body_text = req.target, close_conn = true)
                end
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    try
        resp_get = HT.open(:GET, "$(base_url)/open-get") do stream
            meta = HT.startread(stream)
            @test meta.status == 200
            @test String(read(stream)) == "open-get"
        end
        @test resp_get.status == 200
        @test resp_get.body === nothing

        payload = "payload"
        resp_post = HT.open(:POST, "$(base_url)/open-post") do stream
            buf = IOBuffer()
            write(buf, payload)
            seekstart(buf)
            @test write(stream, buf) == ncodeunits(payload)
            meta = HT.startread(stream)
            @test meta.status == 200
            @test String(read(stream)) == payload
        end
        @test resp_post.status == 200
        @test resp_post.body === nothing

        resp_redirect = HT.open(:POST, "$(base_url)/open-redirect"; redirect_method = :same) do stream
            write(stream, "redirect-body")
            meta = HT.startread(stream)
            @test meta.status == 200
            @test String(read(stream)) == "redirect-body"
        end
        @test resp_redirect.status == 200
        @test resp_redirect.redirect_count == 1
        @test resp_redirect.url == "$(base_url)/open-redirect-final"
        @test resp_redirect.body === nothing

        resp_limit = HT.open(:GET, "$(base_url)/open-limit"; redirect_limit = 0) do stream
            meta = HT.startread(stream)
            @test meta.status == 302
            @test String(read(stream)) == "open-limit"
        end
        @test resp_limit.status == 302
        @test resp_limit.redirect_count == 0
        @test resp_limit.url == "$(base_url)/open-limit"
        @test resp_limit.body === nothing

        resp_auth = HT.open(:GET, "$(base_url)/open-auth"; basicauth = ("alice", "secret")) do stream
            meta = HT.startread(stream)
            @test meta.status == 200
            @test !HT.isaborted(stream)
            @test String(read(stream)) == "open-auth"
        end
        @test resp_auth.status == 200
        @test seen_open_auth[] == "Basic YWxpY2U6c2VjcmV0"

        resp_abort = HT.open(:GET, "$(base_url)/open-abort"; retry = false, status_exception = false) do stream
            meta = HT.startread(stream)
            @test meta.status == 500
            @test HT.isaborted(stream)
            @test String(read(stream)) == "open-abort"
        end
        @test resp_abort.status == 500

        open_err = try
            HT.open(:GET, "$(base_url)/open-error") do stream
                _ = HT.startread(stream)
                error("open callback error")
            end
            nothing
        catch err
            err
        end
        @test open_err isa ErrorException
        if open_err isa ErrorException
            @test occursin("open callback error", open_err.msg)
        end

        _wait_task_client!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
    end
end

@testset "HTTP.open per-byte stream reads" begin
    if _http_windows_ci()
        @test_skip true
    else
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:5
            conn = NC.accept(listener)
            try
                req = HT.read_request(HT._ConnReader(conn))
                _send_response_client!(conn, req; body_text = "line1\nline2\nline3\n", close_conn = true)
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    try
        # Read whole body via read(stream) (the canonical pattern from migration docs)
        body_via_read = HT.open(:GET, "$(base_url)/lines") do stream
            HT.startread(stream)
            @test String(read(stream)) == "line1\nline2\nline3\n"
        end
        @test body_via_read.status == 200

        # readline iterates one line at a time
        lines_seen = String[]
        HT.open(:GET, "$(base_url)/lines") do stream
            HT.startread(stream)
            while !eof(stream)
                push!(lines_seen, readline(stream))
            end
        end
        @test lines_seen == ["line1", "line2", "line3"]

        # readavailable returns currently-buffered bytes without blocking past EOF
        HT.open(:GET, "$(base_url)/lines") do stream
            HT.startread(stream)
            chunks = Vector{UInt8}[]
            while !eof(stream)
                push!(chunks, readavailable(stream))
            end
            @test String(reduce(vcat, chunks; init = UInt8[])) == "line1\nline2\nline3\n"
        end

        # Single-byte reads compose into the full body
        HT.open(:GET, "$(base_url)/lines") do stream
            HT.startread(stream)
            bytes = UInt8[]
            while !eof(stream)
                push!(bytes, read(stream, UInt8))
            end
            @test String(bytes) == "line1\nline2\nline3\n"
        end

        # readbytes! drains in chunks
        HT.open(:GET, "$(base_url)/lines") do stream
            HT.startread(stream)
            buf = Vector{UInt8}(undef, 4)
            n1 = readbytes!(stream, buf)
            @test n1 == 4
            @test String(buf[1:n1]) == "line"
        end

        _wait_task_client!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
    end
end

@testset "HTTP.open stream guard rails" begin
    if _http_windows_ci()
        @test_skip true
    else
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:4
            conn = NC.accept(listener)
            try
                req = HT.read_request(HT._ConnReader(conn))
                if req.target == "/guard-closewrite"
                    body = String(_read_all_body_bytes_client(req.body))
                    _send_response_client!(conn, req; body_text = body, close_conn = true)
                elseif req.target == "/guard-started"
                    _send_response_client!(conn, req; body_text = "guard-started", close_conn = true)
                elseif req.target == "/guard-status"
                    _send_response_client!(conn, req; status = 500, reason = "Boom", body_text = "guard-status", close_conn = true)
                elseif req.target == "/guard-producer"
                    _send_response_client!(conn, req; body_text = "guard-producer", close_conn = true)
                else
                    _send_response_client!(conn, req; status = 500, reason = "Unexpected", body_text = req.target, close_conn = true)
                end
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    try
        @test_throws ArgumentError HT._require_client_stream(HT.Stream(HT.Request("GET", "/server-only")))

        closewrite_stream = HT.open(:POST, "$(base_url)/guard-closewrite")
        try
            HT.closewrite(closewrite_stream)
            @test_throws ArgumentError write(closewrite_stream, UInt8[0x61])
            meta = HT.startread(closewrite_stream)
            @test meta.status == 200
            @test String(read(closewrite_stream)) == ""
        finally
            close(closewrite_stream)
        end

        started_stream = HT.open(:GET, "$(base_url)/guard-started"; readtimeout = 0.25)
        try
            meta = HT.startread(started_stream)
            @test meta.status == 200
            @test_throws ArgumentError write(started_stream, "late-write")
            @test String(read(started_stream)) == "guard-started"
        finally
            close(started_stream)
        end

        status_err = try
            HT.open(:GET, "$(base_url)/guard-status"; retry = false) do stream
                meta = HT.startread(stream)
                @test meta.status == 500
            end
            nothing
        catch err
            err
        end
        @test status_err isa HT.StatusError

        producer_stream = HT.open(:GET, "$(base_url)/guard-producer")
        try
            response = HT.startread(producer_stream)
            producer_stream.producer = @async error("ignored producer error")
            @test HT.closeread(producer_stream) === response
            @test HT.closeread(producer_stream) === response
        finally
            close(producer_stream)
        end

        _wait_task_client!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
    end
end

@testset "HTTP SSE callback interface" begin
    if _http_windows_ci()
        @test_skip true
    else
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    sse_headers = HT.Headers()
    HT.setheader(sse_headers, "Content-Type", "text/event-stream")
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:8
            conn = NC.accept(listener)
            try
                req = HT.read_request(HT._ConnReader(conn))
                if req.target == "/sse"
                    body = "event: ping\ndata: hello\ndata: world\nid: 1\n\nretry: 1500\ndata: next\n\n"
                    _send_response_client!(conn, req; body_text = body, headers = sse_headers, close_conn = true)
                elseif req.target == "/sse-plain"
                    headers = HT.Headers()
                    HT.setheader(headers, "Content-Type", "text/plain")
                    _send_response_client!(conn, req; body_text = "data: plain\n\n", headers = headers, close_conn = true)
                elseif req.target == "/sse-gzip"
                    payload = _gzip_bytes_client("data: gzip-one\n\n")
                    headers = copy(sse_headers)
                    HT.setheader(headers, "Content-Encoding", "gzip")
                    _send_response_bytes_client!(conn, req; body_bytes = payload, headers = headers, close_conn = true)
                elseif req.target == "/sse-long-line"
                    _send_response_client!(conn, req; body_text = ":\n" * repeat("A", 32), headers = sse_headers, close_conn = true)
                elseif req.target == "/sse-error"
                    _send_response_client!(conn, req; status = 404, reason = "Not Found", body_text = "missing", close_conn = true)
                elseif req.target == "/sse-callback-error"
                    _send_response_client!(conn, req; body_text = "data: boom\n\n", headers = sse_headers, close_conn = true)
                elseif req.target == "/sse-cancel"
                    _send_response_client!(conn, req; body_text = "data: first\n\ndata: second\n\n", headers = sse_headers, close_conn = true)
                else
                    _send_response_client!(conn, req; status = 500, reason = "Unexpected", body_text = req.target, close_conn = true)
                end
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    try
        combo_err = try
            HT.get("$(base_url)/sse"; response_stream = IOBuffer(), sse_callback = event -> event)
            nothing
        catch err
            err
        end
        @test combo_err isa ArgumentError

        signature_err = try
            response_callback(response::HT.Response, event) = begin
                _ = (response, event)
                nothing
            end
            HT.get("$(base_url)/sse"; sse_callback = response_callback)
            nothing
        catch err
            err
        end
        @test signature_err isa ArgumentError

        events = HT.SSEEvent[]
        resp_sse = HT.get("$(base_url)/sse"; sse_callback = event -> push!(events, event))
        @test resp_sse.status == 200
        @test resp_sse.body === HT.nobody
        @test length(events) == 2
        @test events[1].event == "ping"
        @test events[1].id == "1"
        @test events[1].data == "hello\nworld"
        @test events[2].retry == 1500
        @test events[2].id == "1"
        @test events[2].data == "next"

        gzip_events = String[]
        resp_gzip = HT.get("$(base_url)/sse-gzip"; sse_callback = event -> push!(gzip_events, event.data))
        @test resp_gzip.status == 200
        @test resp_gzip.body === HT.nobody
        @test gzip_events == ["gzip-one"]

        long_line_err = try
            HT.get("$(base_url)/sse-long-line"; sse_callback = event -> event, max_sse_line_bytes = 16)
            nothing
        catch err
            err
        end
        @test long_line_err isa ErrorException
        if long_line_err isa ErrorException
            @test occursin("max_sse_line_bytes", long_line_err.msg)
        end

        plain_events = HT.SSEEvent[]
        resp_plain = HT.get("$(base_url)/sse-plain"; sse_callback = event -> push!(plain_events, event))
        @test resp_plain.status == 200
        @test resp_plain.body === HT.nobody
        @test length(plain_events) == 1
        @test plain_events[1].data == "plain"

        cancel_events = HT.SSEEvent[]
        resp_cancel = HT.get("$(base_url)/sse-cancel"; sse_callback = (stream, event) -> begin
            push!(cancel_events, event)
            close(stream)
        end)
        @test resp_cancel.status == 200
        @test resp_cancel.body === HT.nobody
        @test length(cancel_events) == 1
        @test cancel_events[1].data == "first"

        error_events = HT.SSEEvent[]
        resp_error = HT.get("$(base_url)/sse-error"; sse_callback = event -> push!(error_events, event), status_exception = false)
        @test resp_error.status == 404
        @test String(resp_error.body) == "missing"
        @test isempty(error_events)

        callback_err = try
            HT.get("$(base_url)/sse-callback-error"; sse_callback = event -> error("sse callback error"))
            nothing
        catch err
            err
        end
        @test callback_err isa ErrorException
        if callback_err isa ErrorException
            @test occursin("sse callback error", callback_err.msg)
        end

        _wait_task_client!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
    end
end

@testset "HTTP SSE helper parsing" begin
    response = HT.Response(200)
    closed = Ref(0)
    stream = HT._SSEClientStream(response, () -> begin
        closed[] += 1
        nothing
    end)
    @test stream.status == 200
    @test isopen(stream)

    wrapped = HT._wrap_sse_callback((client_stream, event) -> begin
        @test client_stream.status == 200
        @test event.data == "alpha"
        close(client_stream)
    end, stream, response)
    stop_err = try
        wrapped(HT.SSEEvent("alpha"))
        nothing
    catch err
        err
    end
    @test stop_err isa HT._SSEStop
    @test closed[] == 1
    close(stream)
    @test closed[] == 1
    @test !isopen(stream)
    @test_throws ArgumentError HT._wrap_sse_callback(() -> nothing, HT._SSEClientStream(response, () -> nothing), response)

    @test HT._trim_sse_line_length(UInt8[0x61, 0x0d, 0x0d]) == 1
    @test HT._sse_bytes_to_string(UInt8[]) == ""
    @test collect(codeunits(HT._sse_bytes_to_string(UInt8[0xff]))) == UInt8[0xff]

    @test HT._looks_like_sse_prefix(UInt8[0xEF, 0xBB, 0xBF, UInt8('d'), UInt8('a'), UInt8('t'), UInt8('a')])
    @test HT._looks_like_sse_prefix(UInt8[UInt8('e'), UInt8('v'), UInt8('e'), UInt8('n'), UInt8('t')])
    @test HT._looks_like_sse_prefix(UInt8[UInt8(':'), UInt8('c')])
    @test !HT._looks_like_sse_prefix(UInt8[UInt8('x'), UInt8('y')])

    state = HT._SSEState()
    parsed_events = HT.SSEEvent[]
    callback = event -> push!(parsed_events, event)
    HT._process_sse_line!(state, UInt8[0xEF, 0xBB, 0xBF, UInt8('d'), UInt8('a'), UInt8('t'), UInt8('a'), UInt8(':'), UInt8(' '), UInt8('f'), UInt8('i'), UInt8('r'), UInt8('s'), UInt8('t')], callback)
    HT._process_sse_line!(state, collect(codeunits("id: bad\0id")), callback)
    HT._process_sse_line!(state, collect(codeunits("retry: 25")), callback)
    HT._process_sse_line!(state, collect(codeunits("extra")), callback)
    HT._process_sse_line!(state, UInt8[UInt8(':'), UInt8('c'), UInt8('o'), UInt8('m'), UInt8('m'), UInt8('e'), UInt8('n'), UInt8('t')], callback)
    HT._process_sse_line!(state, UInt8[], callback)
    @test length(parsed_events) == 1
    @test parsed_events[1].data == "first"
    @test parsed_events[1].id === nothing
    @test parsed_events[1].retry == 25
    @test parsed_events[1].fields["extra"] == ""

    do_response = nothing
    @test_logs (:error, r"SSE stream handler error") begin
        do_response = HT.sse_stream(200) do sse_stream
            write(sse_stream, HT.SSEEvent("hello"))
            error("boom")
        end
        @test do_response !== nothing
        @test do_response.body isa HT.SSEStream
        do_stream = do_response.body::HT.SSEStream
        @test timedwait(() -> !isopen(do_stream), 5.0; pollint = 0.001) == :ok
    end

    parsed_from_stream = HT.SSEEvent[]
    total = HT._parse_sse_stream!(IOBuffer("data: one\n\ndata: tail"), event -> push!(parsed_from_stream, event))
    @test total == ncodeunits("data: one\n\ndata: tail")
    @test [event.data for event in parsed_from_stream] == ["one", "tail"]

    line_limit_err = try
        HT._parse_sse_stream!(IOBuffer(":\n" * repeat("A", 32)), event -> nothing; max_line_bytes = 16)
        nothing
    catch err
        err
    end
    @test line_limit_err isa ErrorException
    if line_limit_err isa ErrorException
        @test occursin("max_sse_line_bytes", line_limit_err.msg)
    end

    event_limit_err = try
        HT._parse_sse_stream!(IOBuffer("data: abc\ndata: def\n\n"), event -> nothing; max_event_bytes = 12)
        nothing
    catch err
        err
    end
    @test event_limit_err isa ErrorException
    if event_limit_err isa ErrorException
        @test occursin("max_sse_event_bytes", event_limit_err.msg)
    end

    detect_err = try
        HT._parse_sse_stream!(IOBuffer(repeat("x", 9_000)), event -> nothing)
        nothing
    catch err
        err
    end
    @test detect_err isa ErrorException
    if detect_err isa ErrorException
        @test occursin("Server-Sent Events stream", detect_err.msg)
    end
end

@testset "HTTP request timeout configuration parsing" begin
    request_timeout_ns, config = HT._resolve_request_timeout_settings(
        1.25,
        0.5,
        0.75,
        0.125,
        0.25,
        1.5,
    )
    @test request_timeout_ns == 1_250_000_000
    @test config !== nothing
    @test (config::HT._RequestTimeoutConfig).connect_timeout_ns == 500_000_000
    @test config.response_header_timeout_ns == 750_000_000
    @test config.read_idle_timeout_ns == 125_000_000
    @test config.write_idle_timeout_ns == 250_000_000
    @test config.expect_continue_timeout_ns == 1_500_000_000

    ctx = HT.RequestContext()
    HT._apply_request_timeout_settings!(ctx, request_timeout_ns, config)
    stored = ctx.timeout_config
    @test stored !== nothing
    @test stored == config
    @test ctx.deadline_ns > time_ns()
    @test !HT.expired(ctx)
    empty!(ctx)
    @test ctx.timeout_config === nothing

    legacy_request_timeout_ns = Int64(-1)
    legacy_config = nothing
    @test_logs (:warn, r"`readtimeout` is deprecated") begin
        legacy_request_timeout_ns, legacy_config = HT._resolve_request_timeout_settings(0, 0, 0, 0, 0, nothing, 0.05)
    end
    @test legacy_request_timeout_ns == 0
    @test legacy_config !== nothing
    @test (legacy_config::HT._RequestTimeoutConfig).read_idle_timeout_ns == 50_000_000
    @test legacy_config.response_header_timeout_ns == 0

    @test_throws ArgumentError HT._resolve_request_timeout_settings(0, 0, 0, 0.05, 0, nothing, 0.05)
end

@testset "HTTP high-level readtimeout" begin
    if _http_windows_ci()
        @test_skip true
    else
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            req = HT.read_request(HT._ConnReader(conn))
            _ = req
            sleep(0.20)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    try
        err = try
            HT.get("$(base_url)/slow"; readtimeout = 0.05)
            nothing
        catch ex
            ex
        end
        @test err isa HT.TimeoutError
        _wait_task_client!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
    end
end

@testset "HTTP high-level response_header_timeout" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            req = HT.read_request(HT._ConnReader(conn))
            _ = req
            sleep(0.20)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    try
        err = try
            HT.get("$(base_url)/slow"; response_header_timeout=0.05)
            nothing
        catch ex
            ex
        end
        @test err isa HT.TimeoutError
        _wait_task_client!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP high-level read_idle_timeout" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            req = HT.read_request(HT._ConnReader(conn))
            _ = _read_all_body_bytes_client(req.body)
            write(conn, collect(codeunits("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\na")))
            sleep(0.20)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    try
        err = try
            HT.get("$(base_url)/slow-body"; read_idle_timeout=0.05)
            nothing
        catch ex
            ex
        end
        @test err isa HT.TimeoutError
        _wait_task_client!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP connect_timeout works with explicit client" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            sleep(0.20)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    client = HT.Client(transport=HT.Transport(tls_config=TL.Config(verify_peer=false), max_idle_per_host=4, max_idle_total=4))
    try
        err = try
            HT.get("https://$(address)/stall"; client=client, connect_timeout=0.05, retry=false)
            nothing
        catch ex
            ex
        end
        @test err !== nothing
        @test !(err isa ArgumentError)
        @test _is_timeout_error_client(err::Exception)
        _wait_task_client!(server_task)
    finally
        close(client.transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP client-level connect_timeout resolution" begin
    client = HT.Client(connect_timeout=5)
    try
        # Unset kwarg falls back to the client default.
        @test HT._resolve_connect_timeout(client, nothing) == 5.0
        # Explicit per-call values override the client default, including an
        # explicit 30 (the built-in default value).
        @test HT._resolve_connect_timeout(client, 7) == 7
        @test HT._resolve_connect_timeout(client, 30) == 30
        # Explicit 0 falls through to the client default, like the other
        # timeout kwargs.
        @test HT._resolve_connect_timeout(client, 0) == 5.0
    finally
        close(client)
    end
    unset = HT.Client()
    try
        # Neither the call nor the client sets it: built-in 30s default.
        @test HT._resolve_connect_timeout(unset, nothing) == 30
        # Explicit 0 without a client default disables the connect timeout.
        @test HT._resolve_connect_timeout(unset, 0) == 0
    finally
        close(unset)
    end
    @test HT._resolve_connect_timeout(nothing, nothing) == 30
    @test HT._resolve_connect_timeout(nothing, 12) == 12
    @test HT._resolve_connect_timeout(nothing, 0) == 0
end

@testset "HTTP Client(connect_timeout=...) default applies to requests" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:2
            conn = NC.accept(listener)
            try
                sleep(0.20)
            finally
                HTTP.@try_ignore NC.close(conn)
            end
        end
        return nothing
    end)
    client = HT.Client(
        transport=HT.Transport(tls_config=TL.Config(verify_peer=false), max_idle_per_host=4, max_idle_total=4),
        connect_timeout=0.05,
    )
    try
        # The request does not pass connect_timeout, so the client default
        # must bound the (stalled) TLS handshake.
        err = try
            HT.get("https://$(address)/stall"; client=client, retry=false)
            nothing
        catch ex
            ex
        end
        @test err !== nothing
        @test _is_timeout_error_client(err::Exception)

        # Same through the HTTP.open streaming path.
        stream_err = try
            HT.open(:GET, "https://$(address)/stall"; client=client, retry=false) do stream
                nothing
            end
            nothing
        catch ex
            ex
        end
        @test stream_err !== nothing
        @test _is_timeout_error_client(stream_err::Exception)
        _wait_task_client!(server_task)
    finally
        close(client.transport)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP transport error wrapping" begin
    refused = ND.OpError("dial", "tcp", nothing, nothing, Base.SystemError("connect", Base.Libc.ECONNREFUSED))
    wrapped_refused = HT._wrap_client_transport_error(refused, "request", Int64(0), Int64(0))
    @test wrapped_refused isa HT.ConnectError
    @test (wrapped_refused::HT.ConnectError).cause === refused

    # Connect refused: should wrap to HTTP.ConnectError, never leak Reseau internals.
    # Some Windows CI runners report this port-1 probe as a connect timeout
    # instead of an immediate refusal, so keep the live probe focused on the
    # public HTTPError boundary and test the refusal mapping directly above.
    err = try
        HT.get("http://127.0.0.1:1/"; connect_timeout=2, retry=false)
        nothing
    catch ex
        ex
    end
    @test err isa HT.HTTPError
    @test err isa HT.ConnectError || err isa HT.TimeoutError
    if err isa HT.ConnectError
        @test occursin("127.0.0.1", err.address)
    else
        @test (err::HT.TimeoutError).operation == "connect"
    end

    # DNS failure: should wrap to HTTP.DNSError.
    dns_err = try
        HT.get("http://this-host-does-not-exist.invalid/"; retry=false)
        nothing
    catch ex
        ex
    end
    @test dns_err isa HT.DNSError
    @test dns_err isa HT.HTTPError
    @test occursin("invalid", dns_err.hostname)

    # request_timeout populates timeout_ns and elapsed_ns on TimeoutError.
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog=8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            req = HT.read_request(HT._ConnReader(conn))
            _ = req
            sleep(0.5)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    try
        timeout_err = try
            HT.get("http://$(address)/slow"; request_timeout=0.05, retry=false)
            nothing
        catch ex
            ex
        end
        @test timeout_err isa HT.TimeoutError
        @test timeout_err.timeout_ns > 0
        @test timeout_err.elapsed_ns > 0
        _wait_task_client!(server_task)
    finally
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP server bind-in-use wraps to AddressInUseError" begin
    bind_address = "127.0.0.1:54321"
    bind_err = Base.SystemError("bind", Base.Libc.EADDRINUSE)
    wrapped_bind = HT._wrap_server_listen_error(bind_err, bind_address)
    @test wrapped_bind isa HT.AddressInUseError
    @test wrapped_bind isa HT.HTTPError
    @test (wrapped_bind::HT.AddressInUseError).address == bind_address

    s1 = HT.serve!(req -> HT.Response(200, "first"), "127.0.0.1", 0; listenany=true)
    bound_port = HT.port(s1)
    s2 = nothing
    try
        bound_err = try
            s2 = HT.serve!(req -> HT.Response(200, "second"), "127.0.0.1", bound_port)
            nothing
        catch ex
            ex
        end
        if bound_err === nothing
            @test Sys.iswindows()
        else
            @test bound_err isa HT.AddressInUseError
            @test bound_err isa HT.HTTPError
            @test occursin("$(bound_port)", (bound_err::HT.AddressInUseError).address)
        end
    finally
        s2 === nothing || close(s2)
        close(s1)
    end
end

@testset "Client default_headers and per-call override" begin
    server = HT.serve!("127.0.0.1", 0; listenany=true) do req
        v = HT.header(req, "X-Custom")
        return HT.Response(200; body=v)
    end
    try
        client = HT.Client(default_headers=["X-Custom"=>"default"])
        try
            resp = HT.get(client, "http://127.0.0.1:$(HT.port(server))/")
            @test String(resp.body) == "default"

            resp2 = HT.get(client, "http://127.0.0.1:$(HT.port(server))/"; headers=["X-Custom"=>"override"])
            @test String(resp2.body) == "override"
        finally
            close(client)
        end
    finally
        HT.forceclose(server)
    end
end

@testset "Client default_query merges with per-call query" begin
    server = HT.serve!("127.0.0.1", 0; listenany=true) do req
        return HT.Response(200; body=req.target)
    end
    try
        client = HT.Client(default_query=Dict("api_key"=>"abc", "page"=>2))
        try
            resp = HT.get(client, "http://127.0.0.1:$(HT.port(server))/x")
            body = String(resp.body)
            @test occursin("api_key=abc", body)
            @test occursin("page=2", body)

            # Per-call query merges, with override winning
            resp2 = HT.get(client, "http://127.0.0.1:$(HT.port(server))/x"; query=["api_key"=>"override", "extra"=>true])
            body2 = String(resp2.body)
            @test occursin("api_key=override", body2)
            @test occursin("extra=true", body2)
            @test occursin("page=2", body2)
            @test !occursin("api_key=abc", body2)
        finally
            close(client)
        end
    finally
        HT.forceclose(server)
    end
end

@testset "Client positional verb helpers" begin
    server = HT.serve!("127.0.0.1", 0; listenany=true) do req
        return HT.Response(200; body=req.method)
    end
    try
        client = HT.Client()
        try
            url = "http://127.0.0.1:$(HT.port(server))/"
            @test String(HT.get(client, url).body) == "GET"
            @test String(HT.post(client, url; body="x").body) == "POST"
            @test String(HT.put(client, url; body="x").body) == "PUT"
            @test String(HT.patch(client, url; body="x").body) == "PATCH"
            @test String(HT.query(client, url; body="x").body) == "QUERY"
            @test String(HT.delete(client, url).body) == "DELETE"
            @test HT.head(client, url).status == 200
            @test HT.options(client, url).status == 200
        finally
            close(client)
        end
    finally
        HT.forceclose(server)
    end
end

@testset "Client poisoning after close" begin
    server = HT.serve!("127.0.0.1", 0; listenany=true) do req
        return HT.Response(200; body="ok")
    end
    try
        client = HT.Client()
        # Initial request works.
        resp = HT.get(client, "http://127.0.0.1:$(HT.port(server))/")
        @test resp.status == 200
        @test isopen(client)
        close(client)
        @test !isopen(client)
        # Subsequent calls must fail with ArgumentError.
        @test_throws ArgumentError HT.get(client, "http://127.0.0.1:$(HT.port(server))/")
        @test_throws ArgumentError HT.get(client, "http://127.0.0.1:$(HT.port(server))/")
    finally
        HT.forceclose(server)
    end
end

@testset "RequestContext cancellation interrupts in-flight request" begin
    slow_server = HT.serve!("127.0.0.1", 0; listenany=true) do req
        sleep(60)
        return HT.Response(200; body="late")
    end
    try
        ctx = HT.RequestContext()
        url = "http://127.0.0.1:$(HT.port(slow_server))/"
        t = Threads.@spawn HT.get($url; context=$ctx)
        sleep(0.5)
        HT.cancel!(ctx; message="user pressed Ctrl-C")
        start = time()
        result = try
            fetch(t)
            (:ok, nothing)
        catch e
            inner = e isa Base.TaskFailedException ? e.task.exception : e
            (:err, inner)
        end
        elapsed = time() - start
        @test result[1] == :err
        @test result[2] isa HT.CanceledError
        @test (result[2]::HT.CanceledError).message == "user pressed Ctrl-C"
        @test elapsed < 5  # cancellation should fire promptly, not wait for sleep(60)
        @test isempty(ctx.cancel_callbacks)
    finally
        HT.forceclose(slow_server)
    end
end

@testset "Client default_basicauth applied unless overridden" begin
    server = HT.serve!("127.0.0.1", 0; listenany=true) do req
        v = HT.header(req, "Authorization")
        return HT.Response(200; body=v)
    end
    try
        client = HT.Client(default_basicauth="alice"=>"secret")
        try
            url = "http://127.0.0.1:$(HT.port(server))/"
            resp = HT.get(client, url)
            @test startswith(String(resp.body), "Basic ")

            # Per-call basicauth overrides
            resp2 = HT.get(client, url; basicauth=("bob","other"))
            @test resp2.body !== resp.body
            @test startswith(String(resp2.body), "Basic ")
        finally
            close(client)
        end
    finally
        HT.forceclose(server)
    end
end

@testset "Client default_request_timeout applied unless overridden" begin
    slow_server = HT.serve!("127.0.0.1", 0; listenany=true) do req
        sleep(5)
        return HT.Response(200)
    end
    try
        client = HT.Client(request_timeout=0.5)
        try
            url = "http://127.0.0.1:$(HT.port(slow_server))/"
            err = try
                HT.get(client, url; retry=false)
                nothing
            catch e
                e
            end
            @test err isa HT.TimeoutError
        finally
            close(client)
        end
    finally
        HT.forceclose(slow_server)
    end
end

@testset "max_decompressed_size guards against decompression bombs" begin
    # ~4 MB of zeros compresses to a few KB of gzip — a small "bomb".
    big = zeros(UInt8, 4_000_000)
    gz = transcode(HTTP.CodecZlib.GzipCompressor, big)
    @test length(gz) < 100_000   # confirm the payload really is small on the wire
    default_bomb = zeros(UInt8, HT._DEFAULT_MAX_DECOMPRESSED_SIZE + 1)
    default_bomb_gz = transcode(HTTP.CodecZlib.GzipCompressor, default_bomb)
    server = HT.serve!("127.0.0.1", 0; listenany = true) do req
        payload = req.target == "/default-bomb" ? default_bomb_gz : gz
        return HT.Response(200; headers = ["Content-Encoding" => "gzip"], body = payload)
    end
    try
        base = "http://127.0.0.1:$(HT.port(server))/"

        # The default cap allows ordinary compressed bodies below the limit.
        r = HT.get(base)
        @test length(r.body) == length(big)

        # The default cap rejects compressed payloads that inflate past it.
        default_err = try
            HT.get("$(base)default-bomb")
            nothing
        catch e
            e
        end
        @test default_err isa HTTP.DecompressionLimitError
        default_err isa HTTP.DecompressionLimitError && @test default_err.limit == HT._DEFAULT_MAX_DECOMPRESSED_SIZE

        @test_throws ArgumentError HT.get(base; max_decompressed_size = -1)

        # Limit below the decompressed size: rejected before the bomb inflates.
        err = try
            HT.get(base; max_decompressed_size = 1024)
            nothing
        catch e
            e
        end
        @test err isa HTTP.DecompressionLimitError
        err isa HTTP.DecompressionLimitError && @test err.limit == 1024

        # Limit at/above the decompressed size: succeeds.
        r2 = HT.get(base; max_decompressed_size = length(big))
        @test length(r2.body) == length(big)

        # The limit also applies to a caller-owned IO sink.
        sink = IOBuffer()
        err2 = try
            HT.get(base; response_stream = sink, max_decompressed_size = 1024)
            nothing
        catch e
            e
        end
        @test err2 isa HTTP.DecompressionLimitError

        # Explicit zero preserves the opt-out for callers that intentionally
        # manage unbounded decompression risk themselves.
        r3 = HT.get(base; max_decompressed_size = 0)
        @test length(r3.body) == length(big)
    finally
        HT.forceclose(server)
    end
end

@testset "HTTP client codeunits bodies dispatch without Base ambiguity (#1302)" begin
    server = HTTP.serve!("127.0.0.1", 0) do req
        body = req.body === nothing ? UInt8[] : req.body
        return HT.Response(200, String(copy(body)))
    end
    try
        url = "http://127.0.0.1:$(HTTP.port(server))/"
        # codeunits request body with a write deadline: routes through the
        # deadline write IO, which was ambiguous with Base's CodeUnits write
        resp = HT.post(url; body = codeunits("cu-body"), write_idle_timeout = 5)
        @test resp.status == 200
        @test String(resp.body) == "cu-body"
        # client stream write of codeunits (Stream{true} disambiguation)
        resp_open = HT.open("POST", url) do io
            write(io, codeunits("cu-open"))
        end
        @test resp_open.status == 200
    finally
        close(server)
    end
end
