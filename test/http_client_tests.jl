using Test
using HTTP
using Reseau

const HT = HTTP
const NC = Reseau.TCP
const ND = Reseau.HostResolvers
const TL = Reseau.TLS

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
    server_task = errormonitor(Threads.@spawn begin
        conn1 = NC.accept(listener)
        try
            req1 = HT.read_request(HT._ConnReader(conn1))
            push!(seen_tokens, HT.header(req1.headers, "X-Client-Token", ""))
            _send_response_client!(conn1, req1; body_text="request")
        finally
            try
                NC.close(conn1)
            catch
            end
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            push!(seen_tokens, HT.header(req2.headers, "X-Stream-Token", ""))
            _send_response_client!(conn2, req2; body_text="stream")
        finally
            try
                NC.close(conn2)
            catch
            end
        end
        return nothing
    end)
    try
        response = ClientSingleMiddleware.get("$(base_url)/request"; clienttoken="abc123", retry=false)
        @test response.status == 200
        @test String(response.body) == "request"
        @test HT.header(response, "X-Client-Request") == "handled"

        seen_body = Ref("")
        response = ClientSingleMiddleware.open(:GET, "$(base_url)/stream"; streamtoken="stream-xyz", retry=false) do stream
            meta = HT.startread(stream)
            @test meta.status == 200
            seen_body[] = String(read(stream))
        end
        @test response.status == 200
        @test seen_body[] == "stream"
        @test seen_tokens == ["abc123", "stream-xyz"]
        _wait_task_client!(server_task)
    finally
        try
            NC.close(listener)
        catch
        end
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
                try
                    NC.close(conn)
                catch
                end
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
        try
            NC.close(listener)
        catch
        end
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
            try
                NC.close(conn)
            catch
            end
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
        try
            NC.close(listener)
        catch
        end
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
            try
                NC.close(conn)
            catch
            end
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
        try
            NC.close(listener)
        catch
        end
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
            headers1 = HT.Headers()
            HT.setheader(headers1, "Location", "/final")
            HT.setheader(headers1, "Connection", "close")
            _send_response_client!(conn1, req1; status = 302, reason = "Found", headers = headers1, close_conn = true)
        finally
            try
                NC.close(conn1)
            catch
            end
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            push!(seen_methods, req2.method)
            push!(seen_targets, req2.target)
            redirected_content_type[] = HT.header(req2.headers, "Content-Type", nothing)
            _send_response_client!(conn2, req2; body_text = "final")
        finally
            try
                NC.close(conn2)
            catch
            end
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
        try
            NC.close(listener)
        catch
        end
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
            try
                NC.close(conn1)
            catch
            end
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            _send_response_client!(conn2, req2; body_text = "ok", close_conn = true)
        finally
            try
                NC.close(conn2)
            catch
            end
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
        try
            NC.close(listener)
        catch
        end
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
            try
                NC.close(conn1)
            catch
            end
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            push!(seen_methods, req2.method)
            push!(seen_bodies, String(_read_all_body_bytes_client(req2.body)))
            _send_response_client!(conn2, req2; body_text = "ok", close_conn = true)
        finally
            try
                NC.close(conn2)
            catch
            end
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
        try
            NC.close(listener)
        catch
        end
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
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            req = HT.read_request(HT._ConnReader(conn))
            push!(seen_methods, req.method)
            _ = _read_all_body_bytes_client(req.body)
            headers = HT.Headers()
            HT.setheader(headers, "Location", "/final")
            HT.setheader(headers, "Connection", "close")
            _send_response_client!(conn, req; status = 307, reason = "Temporary Redirect", headers = headers, body_text = "redirect", close_conn = true)
        finally
            try
                NC.close(conn)
            catch
            end
        end
        return nothing
    end)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4))
    try
        req = HT.Request("POST", "/start"; host = address, body = callback_body, content_length = 1)
        resp = HT.do!(client, address, req)
        @test resp.status == 307
        @test String(_read_all_body_bytes_client(resp.body)) == "redirect"
        _wait_task_client!(server_task)
        @test seen_methods == ["POST"]
    finally
        close(client.transport)
        try
            NC.close(listener)
        catch
        end
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
            try
                NC.close(conn1)
            catch
            end
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            seen_referer[] = HT.header(req2.headers, "Referer", nothing)
            _send_response_client!(conn2, req2; body_text = "ok", close_conn = true)
        finally
            try
                NC.close(conn2)
            catch
            end
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
        try
            NC.close(listener)
        catch
        end
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
            try
                NC.close(conn)
            catch
            end
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
            try
                NC.close(conn)
            catch
            end
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
        try
            NC.close(listener1)
        catch
        end
        try
            NC.close(listener2)
        catch
        end
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
            try
                NC.close(conn1)
            catch
            end
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            hop2_host[] = HT.header(req2.headers, "Host", nothing)
            hop2_header[] = HT.header(req2.headers, "X-Test", nothing)
            _send_response_client!(conn2, req2; body_text = "ok", close_conn = true)
        finally
            try
                NC.close(conn2)
            catch
            end
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
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP client redirect trusted host matching helper" begin
    @test HT._should_copy_sensitive_headers_on_redirect("foo.com:80", "foo.com:443")
    @test HT._should_copy_sensitive_headers_on_redirect("foo.com:80", "sub.foo.com:443")
    @test !HT._should_copy_sensitive_headers_on_redirect("foo.com:80", "bar.com:443")
end

@testset "HTTP client redirect absolute location default ports" begin
    address_h2, secure_h2, target_h2 = HT._resolve_redirect_target("origin.com:443", true, "https://www.google.com/search", "/")
    @test address_h2 == "www.google.com:443"
    @test secure_h2
    @test target_h2 == "/search"

    address_h1, secure_h1, target_h1 = HT._resolve_redirect_target("origin.com:80", false, "http://example.com/next", "/")
    @test address_h1 == "example.com:80"
    @test !secure_h1
    @test target_h1 == "/next"

    address_rel, secure_rel, target_rel = HT._resolve_redirect_target("origin.com:443", true, "//cdn.example.com/assets", "/")
    @test address_rel == "cdn.example.com:443"
    @test secure_rel
    @test target_rel == "/assets"

    address_dot, secure_dot, target_dot = HT._resolve_redirect_target("origin.com:80", false, "../next", "/a/b/c")
    @test address_dot == "origin.com:80"
    @test !secure_dot
    @test target_dot == "/a/next"

    address_query, secure_query, target_query = HT._resolve_redirect_target("origin.com:80", false, "?q=1", "/a/b/c")
    @test address_query == "origin.com:80"
    @test !secure_query
    @test target_query == "/a/b/c?q=1"

    address_frag, secure_frag, target_frag = HT._resolve_redirect_target("origin.com:80", false, "#frag", "/a/b/c?x=1")
    @test address_frag == "origin.com:80"
    @test !secure_frag
    @test target_frag == "/a/b/c?x=1"

    @test_throws HT.ProtocolError HT._resolve_redirect_target("origin.com:80", false, "ftp://example.com/file", "/")
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
                try
                    NC.close(conn)
                catch
                end
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
        try
            NC.close(listener)
        catch
        end
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
                try
                    NC.close(conn)
                catch
                end
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
        try
            NC.close(listener)
        catch
        end
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
            try
                NC.close(conn1)
            catch
            end
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            cookie_header_seen[] = HT.header(req2.headers, "Cookie", nothing)
            _send_response_client!(conn2, req2; body_text = "ok")
        finally
            try
                NC.close(conn2)
            catch
            end
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
        try
            NC.close(listener)
        catch
        end
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
            try
                NC.close(conn1)
            catch
            end
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            cookie_header_seen[] = HT.header(req2.headers, "Cookie", nothing)
            _send_response_client!(conn2, req2; body_text = "check", close_conn = true)
        finally
            try
                NC.close(conn2)
            catch
            end
        end
        conn3 = NC.accept(listener)
        try
            req3 = HT.read_request(HT._ConnReader(conn3))
            cookie_header_disabled[] = HT.header(req3.headers, "Cookie", nothing)
            _send_response_client!(conn3, req3; body_text = "disabled", close_conn = true)
        finally
            try
                NC.close(conn3)
            catch
            end
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
        try
            NC.close(listener)
        catch
        end
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
            try
                NC.close(conn1)
            catch
            end
        end
        conn2 = NC.accept(listener)
        try
            req2 = HT.read_request(HT._ConnReader(conn2))
            cookie_header_seen[] = HT.header(req2.headers, "Cookie", nothing)
            _send_response_client!(conn2, req2; body_text = "stream", close_conn = true)
        finally
            try
                NC.close(conn2)
            catch
            end
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
        try
            NC.close(listener)
        catch
        end
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
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:15
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
                try
                    NC.close(conn)
                catch
                end
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

        parsed_query_uri = HT._parse_http_url(HT.URI("https://example.com?x=1"), Dict("y" => 2))
        @test parsed_query_uri.secure
        @test parsed_query_uri.address == "example.com:443"
        @test parsed_query_uri.target == "/?x=1&y=2"
        @test parsed_query_uri.server_name == "example.com"
        @test parsed_query_uri.url == "https://example.com:443/?x=1&y=2"
        @test parsed_query_uri.authorization === nothing

        parsed_ipv6 = HT._parse_http_url("https://[2001:db8::1]/ipv6")
        @test parsed_ipv6.address == "[2001:db8::1]:443"
        @test parsed_ipv6.target == "/ipv6"
        @test parsed_ipv6.server_name == "2001:db8::1"
        @test parsed_ipv6.url == "https://[2001:db8::1]:443/ipv6"
        @test parsed_ipv6.authorization === nothing

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
        @test "/encoded?a%20b=c%2Bd&slash=%2Fx" in seen_targets
        @test "/auth" in seen_targets
        @test "/auth-url" in seen_targets
        @test "/auth-url-uri" in seen_targets
        @test "/auth-header" in seen_targets
    finally
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP high-level response streaming and decompression" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    base_url = "http://$(address)"
    accept_encodings = Dict{String, Union{Nothing, String}}()
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:13
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
                else
                    _send_response_client!(conn, req; status = 500, reason = "Unexpected", body_text = req.target, close_conn = true)
                end
            finally
                try
                    NC.close(conn)
                catch
                end
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

        _wait_task_client!(server_task)
    finally
        try
            NC.close(listener)
        catch
        end
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
                try
                    NC.close(conn)
                catch
                end
            end
        end
        return nothing
    end)
    try
        resp_dict = HT.post("$(base_url)/dict"; body = Dict("name" => "value with spaces"))
        @test resp_dict.status == 200
        @test String(resp_dict.body) == "name=value%20with%20spaces"

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
        @test seen_bodies["/dict"] == "name=value%20with%20spaces"
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
        try
            NC.close(listener)
        catch
        end
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
                try
                    NC.close(conn)
                catch
                end
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

        resp_post = HT.open(:POST, "$(base_url)/open-post") do stream
            write(stream, "payload")
            meta = HT.startread(stream)
            @test meta.status == 200
            @test String(read(stream)) == "payload"
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
        try
            NC.close(listener)
        catch
        end
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
                try
                    NC.close(conn)
                catch
                end
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
        try
            NC.close(listener)
        catch
        end
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
        for _ in 1:7
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
                try
                    NC.close(conn)
                catch
                end
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
        try
            NC.close(listener)
        catch
        end
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
    stored = HT._request_context_timeout_config(ctx)
    @test stored !== nothing
    @test stored == config
    @test ctx.deadline_ns > time_ns()
    @test !HT.expired(ctx)
    empty!(ctx)
    @test HT._request_context_timeout_config(ctx) === nothing

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
            try
                NC.close(conn)
            catch
            end
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
        @test err isa Reseau.IOPoll.DeadlineExceededError
        _wait_task_client!(server_task)
    finally
        try
            NC.close(listener)
        catch
        end
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
            try
                NC.close(conn)
            catch
            end
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
        @test err isa Reseau.IOPoll.DeadlineExceededError
        _wait_task_client!(server_task)
    finally
        try
            NC.close(listener)
        catch
        end
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
            try
                NC.close(conn)
            catch
            end
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
        @test err isa Reseau.IOPoll.DeadlineExceededError
        _wait_task_client!(server_task)
    finally
        try
            NC.close(listener)
        catch
        end
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
            try
                NC.close(conn)
            catch
            end
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
        try
            NC.close(listener)
        catch
        end
    end
end
