using Test
using HTTP
using Reseau

const HT = HTTP
const TL = Reseau.TLS
const NC = Reseau.TCP
const ND = Reseau.HostResolvers
const IP = Reseau.IOPoll

const _TLS_CERT_PATH = joinpath(@__DIR__, "resources", "unittests.crt")
const _TLS_KEY_PATH = joinpath(@__DIR__, "resources", "unittests.key")
const _HTTP_WINDOWS_PROXY_WARMED = Ref(false)

function _read_all_proxy(body::HT.AbstractBody)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 64)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
end

function _write_all_proxy!(conn::NC.Conn, bytes::Vector{UInt8})::Nothing
    total = 0
    while total < length(bytes)
        n = write(conn, bytes[(total + 1):end])
        n > 0 || error("expected write progress")
        total += n
    end
    return nothing
end

function _send_response_proxy!(conn::NC.Conn, request::HT.Request; status::Int = 200, reason::String = "OK", body_text::String = "", headers::HT.Headers = HT.Headers(), close_conn::Bool = false)::Nothing
    payload = collect(codeunits(body_text))
    response = HT.Response(
        status;
        reason = reason,
        headers = headers,
        body = HT.BytesBody(payload),
        content_length = length(payload),
        close = close_conn,
        request = request,
    )
    io = IOBuffer()
    HT.write_response!(io, response)
    _write_all_proxy!(conn, take!(io))
    return nothing
end

function _wait_task_proxy!(task::Task; timeout_s::Float64 = 5.0)
    status = timedwait(() -> istaskdone(task), timeout_s; pollint = 0.001)
    status == :timed_out && error("timed out waiting for proxy task")
    fetch(task)
    return nothing
end

function _bridge_proxy!(src::NC.Conn, dst::NC.Conn)::Nothing
    while true
        chunk = try
            readavailable(src)
        catch
            UInt8[]
        end
        isempty(chunk) && return nothing
        n = length(chunk)
        total = 0
        while total < n
            wrote = try
                write(dst, chunk[(total + 1):n])
            catch
                0
            end
            wrote > 0 || return nothing
            total += wrote
        end
    end
end

function _reset_default_http_client_proxy!()
    lock(HT._DEFAULT_CLIENT_LOCK)
    try
        existing = HT._DEFAULT_CLIENT[]
        existing === nothing || close(existing::HT.Client)
        HT._DEFAULT_CLIENT[] = nothing
    finally
        unlock(HT._DEFAULT_CLIENT_LOCK)
    end
    return nothing
end

function _write_all_h2_proxy!(io, bytes::Vector{UInt8})::Nothing
    total = 0
    while total < length(bytes)
        n = write(io, bytes[(total + 1):end])
        n > 0 || error("expected h2 write progress")
        total += n
    end
    return nothing
end

function _write_frame_h2_proxy!(io, frame)
    buf = IOBuffer()
    framer = HT.Framer(buf)
    HT.write_frame!(framer, frame)
    _write_all_h2_proxy!(io, take!(buf))
    return nothing
end

function _read_exact_h2_proxy!(io, n::Int)::Vector{UInt8}
    out = Vector{UInt8}(undef, n)
    offset = 0
    while offset < n
        chunk = Vector{UInt8}(undef, n - offset)
        nr = readbytes!(io, chunk)
        nr > 0 || throw(EOFError())
        copyto!(out, offset + 1, chunk, 1, nr)
        offset += nr
    end
    return out
end

function _proxy_windows_ci_warmup!()::Nothing
    _http_windows_ci() || return nothing
    _HTTP_WINDOWS_PROXY_WARMED[] && return nothing
    _HTTP_WINDOWS_PROXY_WARMED[] = true

    origin_listener = nothing
    proxy_listener = nothing
    origin_task = nothing
    proxy_task = nothing
    request_task = nothing
    client = nothing
    try
        origin_listener = TL.listen(
            "tcp",
            "127.0.0.1:0",
            TL.Config(
                verify_peer = false,
                cert_file = _TLS_CERT_PATH,
                key_file = _TLS_KEY_PATH,
                alpn_protocols = ["http/1.1"],
            );
            backlog = 8,
        )
        origin_addr = TL.addr(origin_listener)::NC.SocketAddrV4
        origin_address = ND.join_host_port("127.0.0.1", Int(origin_addr.port))
        proxy_listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
        proxy_addr = NC.addr(proxy_listener)::NC.SocketAddrV4
        proxy_address = ND.join_host_port("127.0.0.1", Int(proxy_addr.port))

        origin_task = errormonitor(Threads.@spawn begin
            conn = TL.accept(origin_listener)
            try
                TL.handshake!(conn)
                req = HT.read_request(HT._ConnReader(conn))
                payload = collect(codeunits("proxy-warmup"))
                response = HT.Response(200; body = HT.BytesBody(payload), content_length = length(payload), request = req)
                io = IOBuffer()
                HT.write_response!(io, response)
                write(conn, take!(io))
            finally
                try
                    TL.close(conn)
                catch
                end
            end
            return nothing
        end)

        proxy_task = errormonitor(Threads.@spawn begin
            client_conn = NC.accept(proxy_listener)
            origin_conn = NC.connect(ND.HostResolver(), "tcp", origin_address)
            bridge1 = nothing
            bridge2 = nothing
            try
                connect_req = HT.read_request(HT._ConnReader(client_conn))
                headers = HT.Headers()
                HT.setheader(headers, "Connection", "keep-alive")
                _send_response_proxy!(client_conn, connect_req; status = 200, reason = "Connection Established", headers = headers)
                bridge1 = errormonitor(Threads.@spawn _bridge_proxy!(client_conn, origin_conn))
                bridge2 = errormonitor(Threads.@spawn _bridge_proxy!(origin_conn, client_conn))
                try
                    _wait_task_proxy!(bridge1; timeout_s = 2.0)
                    _wait_task_proxy!(bridge2; timeout_s = 2.0)
                catch
                end
            finally
                try
                    NC.close(client_conn)
                catch
                end
                try
                    NC.close(origin_conn)
                catch
                end
            end
            return nothing
        end)

        client = HT.Client(
            transport = HT.Transport(
                proxy = HT.ProxyURL("http://user:pass@$(proxy_address)"),
                tls_config = TL.Config(
                    verify_peer = false,
                    server_name = "localhost",
                    alpn_protocols = ["http/1.1"],
                ),
                max_idle_per_host = 4,
                max_idle_total = 4,
            ),
            prefer_http2 = false,
        )
        request = HT.Request("GET", "/warmup"; host = origin_address, body = HT.EmptyBody(), content_length = 0)
        HT.set_deadline!(request.context, Int64(time_ns()) + 3_000_000_000)
        try
            request_task = errormonitor(Threads.@spawn HT.do!(client, origin_address, request; secure = true, protocol = :h1))
            _wait_task_proxy!(request_task; timeout_s = 2.0)
            response = fetch(request_task)
            _read_all_proxy(response.body)
            close(client)
            _wait_task_proxy!(origin_task; timeout_s = 2.0)
            _wait_task_proxy!(proxy_task; timeout_s = 2.0)
        catch
        end
    catch
        # The warmup is best-effort: it exists only to exercise the flaky
        # Windows CI proxy/TLS compiler path before the real tests.
    finally
        client === nothing || try
            close(client)
        catch
        end
        try
            origin_listener === nothing || TL.close(origin_listener)
        catch
        end
        try
            proxy_listener === nothing || NC.close(proxy_listener)
        catch
        end
        origin_task !== nothing && try
            _wait_task_proxy!(origin_task; timeout_s = 0.5)
        catch
        end
        proxy_task !== nothing && try
            _wait_task_proxy!(proxy_task; timeout_s = 0.5)
        catch
        end
        request_task !== nothing && try
            _wait_task_proxy!(request_task; timeout_s = 0.5)
        catch
        end
        GC.gc()
        yield()
        IP.shutdown!()
    end
    return nothing
end

if _http_windows_ci()
    @testset "HTTP proxy windows warmup" begin
        _proxy_windows_ci_warmup!()
    end
end

@testset "HTTP proxy explicit config parsing" begin
    proxy = HT.ProxyURL("http://user:pass@proxy.local:8080")
    @test proxy.http === nothing
    @test proxy.https === nothing
    @test proxy.all !== nothing
    @test (proxy.all::HT._ProxyTarget).url == "http://proxy.local:8080/"
    @test !(proxy.all::HT._ProxyTarget).secure
    @test (proxy.all::HT._ProxyTarget).address == "proxy.local:8080"
    @test (proxy.all::HT._ProxyTarget).authorization == "Basic " * HTTP.Base64.base64encode("user:pass")

    default_scheme = HT.ProxyURL("proxy.local:9000")
    @test default_scheme.all !== nothing
    @test (default_scheme.all::HT._ProxyTarget).url == "http://proxy.local:9000/"
    @test !(default_scheme.all::HT._ProxyTarget).secure
    @test (default_scheme.all::HT._ProxyTarget).address == "proxy.local:9000"

    merged = withenv(
            "HTTP_PROXY" => "http://env-http.local:8080",
            "HTTPS_PROXY" => "http://env-https.local:8443",
            "ALL_PROXY" => "http://env-all.local:3128",
            "NO_PROXY" => "skip.local",
        ) do
        HT.ProxyConfig(; env = true, http = "http://override-http.local:9000")
    end
    @test (merged.http::HT._ProxyTarget).address == "override-http.local:9000"
    @test (merged.https::HT._ProxyTarget).address == "env-https.local:8443"
    @test (merged.all::HT._ProxyTarget).address == "env-all.local:3128"
    @test merged.no_proxy !== nothing
end

@testset "HTTP proxy no_proxy matching" begin
    matcher = HT.NoProxy("example.com,.internal.local,127.0.0.1,10.0.0.0/8,[::1],*.svc.local,1.2.3.4:8443")
    @test HT._matches_no_proxy(matcher, "example.com", 80)
    @test HT._matches_no_proxy(matcher, "api.example.com", 80)
    @test HT._matches_no_proxy(matcher, "foo.internal.local", 80)
    @test !HT._matches_no_proxy(matcher, "internal.local", 80)
    @test HT._matches_no_proxy(matcher, "127.0.0.1", 80)
    @test HT._matches_no_proxy(matcher, "10.2.3.4", 443)
    @test HT._matches_no_proxy(matcher, "::1", 443)
    @test HT._matches_no_proxy(matcher, "db.svc.local", 443)
    @test HT._matches_no_proxy(matcher, "1.2.3.4", 8443)
    @test !HT._matches_no_proxy(matcher, "1.2.3.4", 443)
    @test !HT._matches_no_proxy(matcher, "public.example.net", 80)

    all_match = HT.NoProxy("*")
    @test HT._matches_no_proxy(all_match, "anything.example", 80)
end

@testset "HTTP proxy parser edge cases" begin
    @test HT._split_host_port_optional("[::1]:443") == ("[::1]", Int32(443))
    @test HT._split_host_port_optional("[::1]:abc") == ("[::1]", Int32(-1))
    @test HT._split_host_port_optional("2001:db8::1") == ("2001:db8::1", Int32(-1))

    matcher = HT.NoProxy(["10.0.0.0/12", "2001:db8::1/128", "*.svc.local:8443"])
    @test HT._matches_no_proxy(matcher, "10.15.1.2", 80)
    @test !HT._matches_no_proxy(matcher, "10.16.1.2", 80)
    @test HT._matches_no_proxy(matcher, "2001:db8::1", 80)
    @test !HT._matches_no_proxy(matcher, "2001:db8::2", 80)
    @test HT._matches_no_proxy(matcher, "api.svc.local", 8443)
    @test !HT._matches_no_proxy(matcher, "svc.local", 8443)

    ignored = HT.NoProxy(["10.0.0.0/33", "[2001:db8::]/129", ""])
    @test !HT._matches_no_proxy(ignored, "10.0.0.1", 80)
    @test !HT._matches_no_proxy(ignored, "2001:db8::1", 80)
    @test_throws ArgumentError HT.NoProxy(1)
end

@testset "HTTP proxy env selection and all_proxy fallback" begin
    selector = withenv(
            "HTTP_PROXY" => "http://user:pass@http-proxy.local:8080",
            "HTTPS_PROXY" => "http://https-proxy.local:8443",
            "ALL_PROXY" => "http://fallback-proxy.local:3128",
            "NO_PROXY" => "skip.local,.bypass.local,192.168.0.0/16",
        ) do
        HT.ProxyFromEnvironment()
    end
    http_proxy = HT._proxy_for(selector, false, "public.local", 80)
    @test http_proxy !== nothing
    @test (http_proxy::HT._ProxyTarget).address == "http-proxy.local:8080"
    @test (http_proxy::HT._ProxyTarget).authorization == "Basic " * HTTP.Base64.base64encode("user:pass")

    https_proxy = HT._proxy_for(selector, true, "secure.local", 443)
    @test https_proxy !== nothing
    @test !(https_proxy::HT._ProxyTarget).secure
    @test (https_proxy::HT._ProxyTarget).address == "https-proxy.local:8443"

    bypass = HT._proxy_for(selector, true, "api.bypass.local", 443)
    @test bypass === nothing

    selector_fallback = withenv(
            "HTTP_PROXY" => nothing,
            "http_proxy" => nothing,
            "HTTPS_PROXY" => nothing,
            "https_proxy" => nothing,
            "ALL_PROXY" => "http://fallback-proxy.local:3128",
            "NO_PROXY" => nothing,
            "no_proxy" => nothing,
        ) do
        HT.ProxyFromEnvironment()
    end
    fallback = HT._proxy_for(selector_fallback, false, "origin.local", 80)
    @test fallback !== nothing
    @test (fallback::HT._ProxyTarget).address == "fallback-proxy.local:3128"
end

@testset "HTTP proxy planning chooses direct, forward, and tunnel modes" begin
    direct = HT._proxy_plan(HT.ProxyConfig(), false, "origin.local:80")
    @test direct.mode == HT._ProxyPlanMode.DIRECT
    @test direct.proxy === nothing

    proxy = HT.ProxyURL("http://proxy.local:8080")
    forward = HT._proxy_plan(proxy, false, "origin.local:80")
    @test forward.mode == HT._ProxyPlanMode.HTTP_FORWARD
    @test forward.proxy !== nothing
    @test forward.first_hop_address == "proxy.local:8080"
    @test forward.pool_key == "http://proxy.local:8080/|http://origin.local:80"

    tunnel = HT._proxy_plan(proxy, true, "origin.local:443")
    @test tunnel.mode == HT._ProxyPlanMode.HTTP_TUNNEL
    @test tunnel.first_hop_address == "proxy.local:8080"
    @test tunnel.pool_key == "http://proxy.local:8080/|https://origin.local:443"

    https_proxy = HT.ProxyURL("https://proxy.local:8443")
    @test_throws ArgumentError HT._proxy_plan(https_proxy, true, "origin.local:443")
end

@testset "HTTP proxy forwards plain HTTP requests in absolute-form" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen_target = Ref{Union{Nothing, String}}(nothing)
    seen_host = Ref{Union{Nothing, String}}(nothing)
    seen_proxy_auth = Ref{Union{Nothing, String}}(nothing)
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            req = HT.read_request(HT._ConnReader(conn))
            seen_target[] = req.target
            seen_host[] = HT.header(req.headers, "Host")
            seen_proxy_auth[] = HT.header(req.headers, "Proxy-Authorization")
            _send_response_proxy!(conn, req; body_text = "proxied", close_conn = true)
        finally
            try
                NC.close(conn)
            catch
            end
        end
        return nothing
    end)
    client = HT.Client(transport = HT.Transport(proxy = HT.ProxyURL("http://user:pass@$(proxy_address)"), max_idle_per_host = 4, max_idle_total = 4), prefer_http2 = false)
    try
        response = HT.get!(client, "example.com:80", "/forward?x=1"; secure = false, protocol = :h1)
        @test response.status == 200
        @test String(_read_all_proxy(response.body)) == "proxied"
        _wait_task_proxy!(server_task)
        @test seen_target[] == "http://example.com:80/forward?x=1"
        @test seen_host[] == "example.com:80"
        @test seen_proxy_auth[] == "Basic " * HTTP.Base64.base64encode("user:pass")
    finally
        close(client)
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP proxy CONNECT tunnels HTTPS requests over http proxy" begin
    if _http_windows_ci()
        @test_skip true
    else
    origin_listener = TL.listen(
        "tcp",
        "127.0.0.1:0",
        TL.Config(
            verify_peer = false,
            cert_file = _TLS_CERT_PATH,
            key_file = _TLS_KEY_PATH,
            alpn_protocols = ["http/1.1"],
        );
        backlog = 8,
    )
    origin_addr = TL.addr(origin_listener)::NC.SocketAddrV4
    origin_address = ND.join_host_port("127.0.0.1", Int(origin_addr.port))
    proxy_listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    proxy_addr = NC.addr(proxy_listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(proxy_addr.port))
    seen_connect_host = Ref{Union{Nothing, String}}(nothing)
    seen_proxy_auth = Ref{Union{Nothing, String}}(nothing)
    seen_origin_target = Ref{Union{Nothing, String}}(nothing)
    origin_task = errormonitor(Threads.@spawn begin
        conn = TL.accept(origin_listener)
        try
            TL.handshake!(conn)
            req = HT.read_request(HT._ConnReader(conn))
            seen_origin_target[] = req.target
            payload = collect(codeunits("tls-proxied"))
            response = HT.Response(200; body = HT.BytesBody(payload), content_length = length(payload), request = req)
            io = IOBuffer()
            HT.write_response!(io, response)
            write(conn, take!(io))
        finally
            try
                TL.close(conn)
            catch
            end
        end
        return nothing
    end)
    proxy_task = errormonitor(Threads.@spawn begin
        client_conn = NC.accept(proxy_listener)
        origin_conn = NC.connect(ND.HostResolver(), "tcp", origin_address)
        bridge1 = nothing
        bridge2 = nothing
        try
            connect_req = HT.read_request(HT._ConnReader(client_conn))
            seen_connect_host[] = HT.header(connect_req.headers, "Host")
            seen_proxy_auth[] = HT.header(connect_req.headers, "Proxy-Authorization")
            @test connect_req.method == "CONNECT"
            @test connect_req.target == origin_address
            headers = HT.Headers()
            HT.setheader(headers, "Connection", "keep-alive")
            _send_response_proxy!(client_conn, connect_req; status = 200, reason = "Connection Established", headers = headers)
            bridge1 = errormonitor(Threads.@spawn _bridge_proxy!(client_conn, origin_conn))
            bridge2 = errormonitor(Threads.@spawn _bridge_proxy!(origin_conn, client_conn))
            _wait_task_proxy!(bridge1; timeout_s = 5.0)
            _wait_task_proxy!(bridge2; timeout_s = 5.0)
        finally
            try
                NC.close(client_conn)
            catch
            end
            try
                NC.close(origin_conn)
            catch
            end
        end
        return nothing
    end)
    client = HT.Client(
        transport = HT.Transport(
            proxy = HT.ProxyURL("http://user:pass@$(proxy_address)"),
            tls_config = TL.Config(
                verify_peer = false,
                server_name = "localhost",
                alpn_protocols = ["http/1.1"],
            ),
            max_idle_per_host = 4,
            max_idle_total = 4,
        ),
        prefer_http2 = false,
    )
    try
        request = HT.Request("GET", "/via-proxy"; host = origin_address, body = HT.EmptyBody(), content_length = 0)
        HT.set_deadline!(request.context, Int64(time_ns()) + 3_000_000_000)
        response = HT.do!(client, origin_address, request; secure = true, protocol = :h1)
        @test response.status == 200
        @test String(_read_all_proxy(response.body)) == "tls-proxied"
        close(client)
        _wait_task_proxy!(origin_task)
        _wait_task_proxy!(proxy_task)
        @test seen_connect_host[] == origin_address
        @test seen_proxy_auth[] == "Basic " * HTTP.Base64.base64encode("user:pass")
        @test seen_origin_target[] == "/via-proxy"
    finally
        close(client)
        try
            TL.close(origin_listener)
        catch
        end
        try
            NC.close(proxy_listener)
        catch
        end
    end
    end
end

@testset "HTTP high-level request and open accept explicit proxy overrides" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen_targets = String[]
    server_task = errormonitor(Threads.@spawn begin
        for _ in 1:2
            conn = NC.accept(listener)
            try
                req = HT.read_request(HT._ConnReader(conn))
                push!(seen_targets, req.target)
                if occursin("/open", req.target)
                    _send_response_proxy!(conn, req; body_text = "open-proxied", close_conn = true)
                else
                    _send_response_proxy!(conn, req; body_text = "request-proxied", close_conn = true)
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
        response = HT.get("http://example.com:80/request"; proxy = "http://$(proxy_address)")
        @test response.status == 200
        @test String(response.body) == "request-proxied"

        open_response = HT.open(:GET, "http://example.com:80/open"; proxy = "http://$(proxy_address)") do stream
            meta = HT.startread(stream)
            @test meta.status == 200
            @test String(read(stream)) == "open-proxied"
        end
        @test open_response.status == 200
        @test open_response.body === nothing

        _wait_task_proxy!(server_task)
        @test seen_targets == [
            "http://example.com:80/request",
            "http://example.com:80/open",
        ]
    finally
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP default client uses env proxy configuration" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen_target = Ref{Union{Nothing, String}}(nothing)
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            req = HT.read_request(HT._ConnReader(conn))
            seen_target[] = req.target
            _send_response_proxy!(conn, req; body_text = "env-proxied", close_conn = true)
        finally
            try
                NC.close(conn)
            catch
            end
        end
        return nothing
    end)
    try
        _reset_default_http_client_proxy!()
        response = withenv("HTTP_PROXY" => "http://$(proxy_address)", "NO_PROXY" => nothing, "no_proxy" => nothing) do
            HT.get("http://env.local:80/via-env")
        end
        @test response.status == 200
        @test String(response.body) == "env-proxied"
        _wait_task_proxy!(server_task)
        @test seen_target[] == "http://env.local:80/via-env"
    finally
        _reset_default_http_client_proxy!()
        try
            NC.close(listener)
        catch
        end
    end
end

@testset "HTTP proxy CONNECT supports tunneled H2 requests" begin
    if _http_windows_ci()
        @test_skip true
    else
    origin_listener = TL.listen(
        "tcp",
        "127.0.0.1:0",
        TL.Config(
            verify_peer = false,
            cert_file = _TLS_CERT_PATH,
            key_file = _TLS_KEY_PATH,
            alpn_protocols = ["h2"],
        );
        backlog = 8,
    )
    origin_addr = TL.addr(origin_listener)::NC.SocketAddrV4
    origin_address = ND.join_host_port("127.0.0.1", Int(origin_addr.port))
    proxy_listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    proxy_addr = NC.addr(proxy_listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(proxy_addr.port))
    seen_h2_path = Ref{Union{Nothing, String}}(nothing)
    tunnel_done = Base.Event()
    origin_task = errormonitor(Threads.@spawn begin
        conn = TL.accept(origin_listener)
        try
            TL.handshake!(conn)
            preface = _read_exact_h2_proxy!(conn, length(HT._H2_PREFACE))
            @test preface == HT._H2_PREFACE
            reader = HT.Framer(HT._ConnReader(conn))
            decoder = HT.Decoder()
            frame = HT.read_frame!(reader)
            @test frame isa HT.SettingsFrame
            _write_frame_h2_proxy!(conn, HT.SettingsFrame(false, Pair{UInt16, UInt32}[]))
            _write_frame_h2_proxy!(conn, HT.SettingsFrame(true, Pair{UInt16, UInt32}[]))
            request_headers = nothing
            while request_headers === nothing
                frame = HT.read_frame!(reader)
                if frame isa HT.SettingsFrame
                    continue
                end
                if frame isa HT.HeadersFrame
                    decoded = HT.decode_header_block(decoder, (frame::HT.HeadersFrame).header_block_fragment)
                    for header in decoded
                        if header.name == ":path"
                            seen_h2_path[] = header.value
                        end
                    end
                    request_headers = decoded
                end
            end
            encoder = HT.Encoder()
            payload = collect(codeunits("h2-proxied"))
            header_block = HT.encode_header_block(encoder, [
                HT.HeaderField(":status", "200", false),
                HT.HeaderField("content-length", string(length(payload)), false),
            ])
            _write_frame_h2_proxy!(conn, HT.HeadersFrame(UInt32(1), false, true, header_block))
            _write_frame_h2_proxy!(conn, HT.DataFrame(UInt32(1), true, payload))
            while true
                try
                    _ = HT.read_frame!(reader)
                catch err
                    if err isa EOFError || err isa TL.TLSError || err isa HT.ParseError || err isa HT.ProtocolError
                        break
                    end
                    rethrow(err)
                end
            end
        finally
            try
                TL.close(conn)
            catch
            end
        end
        return nothing
    end)
    proxy_task = errormonitor(Threads.@spawn begin
        client_conn = NC.accept(proxy_listener)
        origin_conn = NC.connect(ND.HostResolver(), "tcp", origin_address)
        try
            connect_req = HT.read_request(HT._ConnReader(client_conn))
            @test connect_req.method == "CONNECT"
            @test connect_req.target == origin_address
            _send_response_proxy!(client_conn, connect_req; status = 200, reason = "Connection Established", headers = HT.Headers())
            errormonitor(Threads.@spawn _bridge_proxy!(client_conn, origin_conn))
            errormonitor(Threads.@spawn _bridge_proxy!(origin_conn, client_conn))
            wait(tunnel_done)
        finally
            try
                NC.close(client_conn)
            catch
            end
            try
                NC.close(origin_conn)
            catch
            end
        end
        return nothing
    end)
    try
        response = HT.get(
            "https://$(origin_address)/via-h2";
            proxy = "http://$(proxy_address)",
            protocol = :h2,
            require_ssl_verification = false,
        )
        @test response.status == 200
        @test String(response.body) == "h2-proxied"
        notify(tunnel_done)
        close(HT._default_client!())
        _reset_default_http_client_proxy!()
        _wait_task_proxy!(origin_task)
        _wait_task_proxy!(proxy_task)
        @test seen_h2_path[] == "/via-h2"
    finally
        _reset_default_http_client_proxy!()
        try
            TL.close(origin_listener)
        catch
        end
        try
            NC.close(proxy_listener)
        catch
        end
    end
    end
end
