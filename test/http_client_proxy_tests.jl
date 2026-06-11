using Test
using Base64
using HTTP
using Reseau

const HT = HTTP
const W = HTTP.WebSockets
const TL = Reseau.TLS
const NC = Reseau.TCP
const ND = Reseau.HostResolvers
const IP = Reseau.IOPoll

const _TLS_CERT_PATH = joinpath(@__DIR__, "resources", "unittests.crt")
const _TLS_KEY_PATH = joinpath(@__DIR__, "resources", "unittests.key")
const _HTTP_WINDOWS_PROXY_WARMED = Ref(false)

if !isdefined(@__MODULE__, :_http_windows_ci)
    @inline function _http_windows_ci()::Bool
        return Sys.iswindows() && get(ENV, "GITHUB_ACTIONS", "false") == "true"
    end
end

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

function _read_exact_proxy!(conn::NC.Conn, n::Int)::Vector{UInt8}
    out = Vector{UInt8}(undef, n)
    got = readbytes!(conn, out, n; all = true)
    got == n || throw(EOFError())
    return out
end

struct _SocksConnectRequest
    atyp::UInt8
    host::String
    port::UInt16
end

function _socks_read_greeting_proxy!(conn::NC.Conn)::Vector{UInt8}
    head = _read_exact_proxy!(conn, 2)
    @test head[1] == 0x05
    nmethods = Int(head[2])
    return _read_exact_proxy!(conn, nmethods)
end

function _socks_select_method_proxy!(conn::NC.Conn, method::UInt8)::Nothing
    write(conn, UInt8[0x05, method])
    return nothing
end

function _socks_read_username_password_proxy!(conn::NC.Conn)::Tuple{String,String}
    head = _read_exact_proxy!(conn, 2)
    @test head[1] == 0x01
    username_bytes = _read_exact_proxy!(conn, Int(head[2]))
    pass_len = Int(_read_exact_proxy!(conn, 1)[1])
    password_bytes = _read_exact_proxy!(conn, pass_len)
    write(conn, UInt8[0x01, 0x00])
    return String(username_bytes), String(password_bytes)
end

function _socks_read_connect_request_proxy!(conn::NC.Conn)::_SocksConnectRequest
    head = _read_exact_proxy!(conn, 4)
    @test head[1] == 0x05
    @test head[2] == 0x01
    @test head[3] == 0x00
    atyp = head[4]
    if atyp == 0x01
        data = _read_exact_proxy!(conn, 6)
        host = string(data[1], ".", data[2], ".", data[3], ".", data[4])
        port = (UInt16(data[5]) << 8) | UInt16(data[6])
        return _SocksConnectRequest(atyp, host, port)
    elseif atyp == 0x03
        len = Int(_read_exact_proxy!(conn, 1)[1])
        data = _read_exact_proxy!(conn, len + 2)
        host = String(data[1:len])
        port = (UInt16(data[len + 1]) << 8) | UInt16(data[len + 2])
        return _SocksConnectRequest(atyp, host, port)
    elseif atyp == 0x04
        data = _read_exact_proxy!(conn, 18)
        addr = NC.SocketAddrV6((
                data[1], data[2], data[3], data[4],
                data[5], data[6], data[7], data[8],
                data[9], data[10], data[11], data[12],
                data[13], data[14], data[15], data[16],
            ),
            0,
        )
        port = (UInt16(data[17]) << 8) | UInt16(data[18])
        return _SocksConnectRequest(atyp, NC._format_ipv6(addr.ip), port)
    end
    error("unexpected SOCKS address type $atyp")
end

function _socks_write_success_proxy!(conn::NC.Conn)::Nothing
    write(conn, UInt8[0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    return nothing
end

function _send_response_proxy!(conn::NC.Conn, request::HT.Request; status::Int = 200, reason::String = "OK", body_text::String = "", headers::HT.Headers = HT.Headers(), close_conn::Bool = false)::Nothing
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
    framer = buf
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
                response = HT.Response(200, HT.BytesBody(payload); content_length = length(payload), request = req)
                io = IOBuffer()
                HT.write_response!(io, response)
                write(conn, take!(io))
            finally
                HTTP.@try_ignore TL.close(conn)
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
                HTTP.@try_ignore begin
                    _wait_task_proxy!(bridge1; timeout_s = 2.0)
                    _wait_task_proxy!(bridge2; timeout_s = 2.0)
                end
            finally
                HTTP.@try_ignore NC.close(client_conn)
                HTTP.@try_ignore NC.close(origin_conn)
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
        HT.set_deadline!(HT.get_request_context(request), Int64(time_ns()) + 3_000_000_000)
        HTTP.@try_ignore begin
            request_task = errormonitor(Threads.@spawn HT.do!(client, origin_address, request; secure = true, protocol = :h1))
            _wait_task_proxy!(request_task; timeout_s = 2.0)
            response = fetch(request_task)
            _read_all_proxy(response.body)
            close(client)
            _wait_task_proxy!(origin_task; timeout_s = 2.0)
            _wait_task_proxy!(proxy_task; timeout_s = 2.0)
        end
    catch
        # The warmup is best-effort: it exists only to exercise the flaky
        # Windows CI proxy/TLS compiler path before the real tests.
    finally
        client === nothing || HTTP.@try_ignore close(client)
        HTTP.@try_ignore origin_listener === nothing || TL.close(origin_listener)
        HTTP.@try_ignore proxy_listener === nothing || NC.close(proxy_listener)
        origin_task === nothing || HTTP.@try_ignore begin
            _wait_task_proxy!(origin_task; timeout_s = 0.5)
        end
        proxy_task === nothing || HTTP.@try_ignore begin
            _wait_task_proxy!(proxy_task; timeout_s = 0.5)
        end
        request_task === nothing || HTTP.@try_ignore begin
            _wait_task_proxy!(request_task; timeout_s = 0.5)
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
    @test (proxy.all::HT._ProxyTarget).authorization == "Basic " * Base64.base64encode("user:pass")

    default_scheme = HT.ProxyURL("proxy.local:9000")
    @test default_scheme.all !== nothing
    @test (default_scheme.all::HT._ProxyTarget).url == "http://proxy.local:9000/"
    @test !(default_scheme.all::HT._ProxyTarget).secure
    @test (default_scheme.all::HT._ProxyTarget).address == "proxy.local:9000"

    socks = HT.ProxyURL("socks5://user:p%40ss@proxy.local")
    @test (socks.all::HT._ProxyTarget).url == "socks5://proxy.local:1080/"
    @test (socks.all::HT._ProxyTarget).scheme == "socks5"
    @test !(socks.all::HT._ProxyTarget).secure
    @test (socks.all::HT._ProxyTarget).address == "proxy.local:1080"
    @test (socks.all::HT._ProxyTarget).username == "user"
    @test (socks.all::HT._ProxyTarget).password == "p@ss"
    @test (socks.all::HT._ProxyTarget).authorization == "Basic " * Base64.base64encode("user:p@ss")

    socks5h = HT.ProxyURL("socks5h://proxy.local:1081")
    @test (socks5h.all::HT._ProxyTarget).url == "socks5h://proxy.local:1081/"
    @test (socks5h.all::HT._ProxyTarget).scheme == "socks5h"
    @test (socks5h.all::HT._ProxyTarget).address == "proxy.local:1081"

    upper_scheme = HT.ProxyURL("SOCKS5H://proxy.local:1081")
    @test (upper_scheme.all::HT._ProxyTarget).scheme == "socks5h"

    socks_v6 = HT.ProxyURL("socks5://[::1]")
    @test (socks_v6.all::HT._ProxyTarget).address == "[::1]:1080"
    socks_v6_port = HT.ProxyURL("socks5://[::1]:9050")
    @test (socks_v6_port.all::HT._ProxyTarget).address == "[::1]:9050"

    socks_pathy = HT.ProxyURL("socks5://proxy.local:1080/ignored?q=1#frag")
    @test (socks_pathy.all::HT._ProxyTarget).address == "proxy.local:1080"
    @test (socks_pathy.all::HT._ProxyTarget).url == "socks5://proxy.local:1080/"

    @test_throws ArgumentError HT.ProxyURL("socks5://::1:1080")
    @test_throws ArgumentError HT.ProxyURL("socks5://proxy.local:0x50")
    @test_throws ArgumentError HT.ProxyURL("socks5://proxy.local:+1080")
    @test_throws ArgumentError HT.ProxyURL("socks5://proxy.local:0")
    @test_throws ArgumentError HT.ProxyURL("socks5://proxy.local:65536")
    @test_throws ArgumentError HT.ProxyURL("socks5://user:pass@")
    @test_throws ArgumentError HT.ProxyURL("socks4://proxy.local:1080")
    @test_throws ArgumentError HT.ProxyURL("socks5://")

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

    env_socks = withenv(
            "HTTP_PROXY" => nothing,
            "http_proxy" => nothing,
            "HTTPS_PROXY" => nothing,
            "https_proxy" => nothing,
            "ALL_PROXY" => "socks5h://env-socks.local",
            "all_proxy" => nothing,
            "NO_PROXY" => nothing,
            "no_proxy" => nothing,
        ) do
        HT.ProxyFromEnvironment()
    end
    @test (env_socks.all::HT._ProxyTarget).scheme == "socks5h"
    @test (env_socks.all::HT._ProxyTarget).address == "env-socks.local:1080"
end

@testset "percent-encoded userinfo is decoded for Basic auth" begin
    # RFC 3986 §3.2.1: userinfo sub-components are percent-encoded and must be
    # decoded before forming the Basic credential ("%40" -> "@", "%24" -> "\$").
    # Affects both proxy credentials and request-URL credentials (same code path).
    proxy = HT.ProxyURL("http://user:p%40ss%24@proxy.local:8080")
    @test (proxy.all::HT._ProxyTarget).authorization == "Basic " * Base64.base64encode("user:p@ss\$")
    # an encoded username ("%2B" -> "+") is decoded as well
    enc_user = HT.ProxyURL("http://a%2Bb:secret@proxy.local:8080")
    @test (enc_user.all::HT._ProxyTarget).authorization == "Basic " * Base64.base64encode("a+b:secret")
    # request URL userinfo (not a proxy) is decoded too
    @test HT._parse_http_url("https://user:p%40ss@api.local/path").authorization ==
          "Basic " * Base64.base64encode("user:p@ss")
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
    @test (http_proxy::HT._ProxyTarget).authorization == "Basic " * Base64.base64encode("user:pass")

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

@testset "HTTP proxy CGI safeguard matches Go semantics" begin
    selector = withenv(
            "HTTP_PROXY" => "http://cgi-http-proxy.local:8080",
            "HTTPS_PROXY" => "http://cgi-https-proxy.local:8443",
            "ALL_PROXY" => "http://fallback-proxy.local:3128",
            "REQUEST_METHOD" => "POST",
        ) do
        HT.ProxyFromEnvironment()
    end
    err = try
        HT._proxy_for(selector, false, "public.local", 80)
        nothing
    catch err
        err
    end
    @test err isa ArgumentError
    @test occursin("refusing to use HTTP_PROXY value in CGI environment", sprint(showerror, err::ArgumentError))

    https_proxy = HT._proxy_for(selector, true, "secure.local", 443)
    @test https_proxy !== nothing
    @test (https_proxy::HT._ProxyTarget).address == "cgi-https-proxy.local:8443"

    selector_lower = withenv(
            "HTTP_PROXY" => nothing,
            "http_proxy" => "http://lower-http-proxy.local:8080",
            "REQUEST_METHOD" => "GET",
        ) do
        HT.ProxyFromEnvironment()
    end
    err_lower = try
        HT._proxy_for(selector_lower, false, "public.local", 80)
        nothing
    catch err
        err
    end
    @test err_lower isa ArgumentError
    @test occursin("refusing to use HTTP_PROXY value in CGI environment", sprint(showerror, err_lower::ArgumentError))

    selector_fallback = withenv(
            "HTTP_PROXY" => nothing,
            "http_proxy" => nothing,
            "ALL_PROXY" => "http://fallback-proxy.local:3128",
            "REQUEST_METHOD" => "POST",
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

    socks = HT.ProxyURL("socks5://proxy.local:1080")
    socks_plan = HT._proxy_plan(socks, false, "origin.local:80")
    @test socks_plan.mode == HT._ProxyPlanMode.SOCKS5
    @test socks_plan.proxy !== nothing
    @test socks_plan.first_hop_address == "proxy.local:1080"
    @test socks_plan.pool_key == "socks5://proxy.local:1080/|http://origin.local:80"

    socks5h = HT.ProxyURL("socks5h://proxy.local:1080")
    socks5h_plan = HT._proxy_plan(socks5h, true, "origin.local:443")
    @test socks5h_plan.mode == HT._ProxyPlanMode.SOCKS5H
    @test socks5h_plan.first_hop_address == "proxy.local:1080"
    @test socks5h_plan.pool_key == "socks5h://proxy.local:1080/|https://origin.local:443"

    socks_no_proxy = HT.ProxyURL("socks5://proxy.local:1080"; no_proxy = "origin.local")
    skipped_plan = HT._proxy_plan(socks_no_proxy, false, "origin.local:80")
    @test skipped_plan.mode == HT._ProxyPlanMode.DIRECT

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
            HTTP.@try_ignore NC.close(conn)
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
        @test seen_proxy_auth[] == "Basic " * Base64.base64encode("user:pass")
    finally
        close(client)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP SOCKS5 proxy handshakes before plain HTTP requests" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen_target = Ref{Union{Nothing, String}}(nothing)
    seen_host = Ref{Union{Nothing, String}}(nothing)
    seen_socks_host = Ref{Union{Nothing, String}}(nothing)
    seen_socks_port = Ref{UInt16}(0)
    seen_username = Ref{Union{Nothing, String}}(nothing)
    seen_password = Ref{Union{Nothing, String}}(nothing)
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            methods = _socks_read_greeting_proxy!(conn)
            @test methods == UInt8[0x00, 0x02]
            _socks_select_method_proxy!(conn, 0x02)
            seen_username[], seen_password[] = _socks_read_username_password_proxy!(conn)
            req = _socks_read_connect_request_proxy!(conn)
            seen_socks_host[] = req.host
            seen_socks_port[] = req.port
            _socks_write_success_proxy!(conn)
            http_req = HT.read_request(HT._ConnReader(conn))
            seen_target[] = http_req.target
            seen_host[] = HT.header(http_req.headers, "Host")
            _send_response_proxy!(conn, http_req; body_text = "socks-proxied", close_conn = true)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    client = HT.Client(transport = HT.Transport(proxy = HT.ProxyURL("socks5://user:p%40ss@$(proxy_address)"), max_idle_per_host = 4, max_idle_total = 4), prefer_http2 = false)
    try
        response = HT.get!(client, "example.com:80", "/via-socks?x=1"; secure = false, protocol = :h1)
        @test response.status == 200
        @test String(_read_all_proxy(response.body)) == "socks-proxied"
        _wait_task_proxy!(server_task)
        @test seen_username[] == "user"
        @test seen_password[] == "p@ss"
        @test seen_socks_host[] == "example.com"
        @test seen_socks_port[] == UInt16(80)
        @test seen_target[] == "/via-socks?x=1"
        @test seen_host[] == "example.com:80"
    finally
        close(client)
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP WebSockets client uses SOCKS proxy stream" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    seen_target = Ref{Union{Nothing, String}}(nothing)
    seen_socks_host = Ref{Union{Nothing, String}}(nothing)
    task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            methods = _socks_read_greeting_proxy!(conn)
            @test methods == UInt8[0x00]
            _socks_select_method_proxy!(conn, 0x00)
            req = _socks_read_connect_request_proxy!(conn)
            seen_socks_host[] = req.host
            _socks_write_success_proxy!(conn)
            request = HT.read_request(HT._ConnReader(conn))
            seen_target[] = request.target
            headers = HT.Headers()
            HT.setheader(headers, "Upgrade", "websocket")
            HT.setheader(headers, "Connection", "Upgrade")
            key = W.ws_get_request_sec_websocket_key(request)
            key === nothing && error("missing websocket key")
            HT.setheader(headers, "Sec-WebSocket-Accept", W.ws_compute_accept_key(key))
            io = IOBuffer()
            HT.write_response!(io, HT.Response(101, HT.EmptyBody(); headers = headers, content_length = 0))
            write(conn, take!(io))
            frame = W.WsFrame(opcode = UInt8(W.WsOpcode.TEXT), payload = Vector{UInt8}("socks-ws"), fin = true)
            encoded = W.ws_encode_frame(frame)
            write(conn, encoded, length(encoded))
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    ws = nothing
    try
        ws = W.open("ws://example.com/proxied-ws"; proxy = "socks5://$(proxy_address)")
        @test W.receive(ws) == "socks-ws"
        _wait_task_proxy!(task)
        @test seen_socks_host[] == "example.com"
        @test seen_target[] == "/proxied-ws"
    finally
        ws === nothing || HTTP.@try_ignore close(ws)
        HTTP.@try_ignore NC.close(listener)
        _reset_default_http_client_proxy!()
    end
end

@testset "HTTP SOCKS5 proxy failures surface as ConnectError" begin
    # proxy rejects the CONNECT command
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            _socks_read_greeting_proxy!(conn)
            _socks_select_method_proxy!(conn, 0x00)
            _socks_read_connect_request_proxy!(conn)
            write(conn, UInt8[0x05, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    try
        err = try
            HT.get("http://example.com/refused"; proxy = "socks5://$(proxy_address)", retry = false)
            nothing
        catch ex
            ex
        end
        @test err isa HT.ConnectError
        if err isa HT.ConnectError
            @test err.cause isa Reseau.SOCKS.ReplyError
            @test err.address == "example.com:80"
        end
        _wait_task_proxy!(server_task)
    finally
        _reset_default_http_client_proxy!()
        HTTP.@try_ignore NC.close(listener)
    end

    # proxy demands username/password auth but the URL has no credentials
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            methods = _socks_read_greeting_proxy!(conn)
            @test methods == UInt8[0x00]
            _socks_select_method_proxy!(conn, 0x02)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    try
        err = try
            HT.get("http://example.com/auth"; proxy = "socks5://$(proxy_address)", retry = false)
            nothing
        catch ex
            ex
        end
        @test err isa HT.ConnectError
        if err isa HT.ConnectError
            @test err.cause isa Reseau.SOCKS.AuthenticationError
        end
        _wait_task_proxy!(server_task)
    finally
        _reset_default_http_client_proxy!()
        HTTP.@try_ignore NC.close(listener)
    end

    # empty username from the proxy URL is rejected before any proxy bytes
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        HTTP.@try_ignore NC.close(conn)
        return nothing
    end)
    try
        err = try
            HT.get("http://example.com/empty-user"; proxy = "socks5://:secret@$(proxy_address)", retry = false)
            nothing
        catch ex
            ex
        end
        @test err isa HT.ConnectError
        if err isa HT.ConnectError
            @test err.cause isa Reseau.SOCKS.AuthenticationError
        end
        _wait_task_proxy!(server_task)
    finally
        _reset_default_http_client_proxy!()
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP SOCKS5 handshake honors connect timeout" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    release = Base.Event()
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            _socks_read_greeting_proxy!(conn)
            wait(release)
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    try
        err = try
            HT.get(
                "http://example.com/stalled";
                proxy = "socks5://$(proxy_address)",
                retry = false,
                connect_timeout = 0.3,
            )
            nothing
        catch ex
            ex
        end
        @test err isa HT.TimeoutError
        notify(release)
        _wait_task_proxy!(server_task)
    finally
        notify(release)
        _reset_default_http_client_proxy!()
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTPS h1 requests ride a SOCKS5 proxied TLS stream" begin
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
    target_address = ND.join_host_port("example.com", Int(origin_addr.port))
    proxy_listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    proxy_addr = NC.addr(proxy_listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(proxy_addr.port))
    seen_socks_host = Ref{Union{Nothing, String}}(nothing)
    seen_socks_port = Ref{UInt16}(0)
    seen_origin_target = Ref{Union{Nothing, String}}(nothing)
    origin_task = errormonitor(Threads.@spawn begin
        conn = TL.accept(origin_listener)
        try
            TL.handshake!(conn)
            req = HT.read_request(HT._ConnReader(conn))
            seen_origin_target[] = req.target
            payload = collect(codeunits("tls-socks-proxied"))
            response = HT.Response(200, HT.BytesBody(payload); content_length = length(payload), request = req)
            io = IOBuffer()
            HT.write_response!(io, response)
            write(conn, take!(io))
        finally
            HTTP.@try_ignore TL.close(conn)
        end
        return nothing
    end)
    proxy_task = errormonitor(Threads.@spawn begin
        client_conn = NC.accept(proxy_listener)
        origin_conn = NC.connect(ND.HostResolver(), "tcp", origin_address)
        bridge1 = nothing
        bridge2 = nothing
        try
            methods = _socks_read_greeting_proxy!(client_conn)
            @test methods == UInt8[0x00]
            _socks_select_method_proxy!(client_conn, 0x00)
            req = _socks_read_connect_request_proxy!(client_conn)
            seen_socks_host[] = req.host
            seen_socks_port[] = req.port
            _socks_write_success_proxy!(client_conn)
            bridge1 = errormonitor(Threads.@spawn _bridge_proxy!(client_conn, origin_conn))
            bridge2 = errormonitor(Threads.@spawn _bridge_proxy!(origin_conn, client_conn))
            _wait_task_proxy!(bridge1; timeout_s = 5.0)
            _wait_task_proxy!(bridge2; timeout_s = 5.0)
        finally
            HTTP.@try_ignore NC.close(client_conn)
            HTTP.@try_ignore NC.close(origin_conn)
        end
        return nothing
    end)
    client = HT.Client(
        transport = HT.Transport(
            proxy = HT.ProxyURL("socks5h://$(proxy_address)"),
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
        request = HT.Request("GET", "/via-socks-tls"; host = target_address, body = HT.EmptyBody(), content_length = 0)
        HT.set_deadline!(HT.get_request_context(request), Int64(time_ns()) + 3_000_000_000)
        response = HT.do!(client, target_address, request; secure = true, protocol = :h1)
        @test response.status == 200
        @test String(_read_all_proxy(response.body)) == "tls-socks-proxied"
        close(client)
        _wait_task_proxy!(origin_task)
        _wait_task_proxy!(proxy_task)
        @test seen_socks_host[] == "example.com"
        @test seen_socks_port[] == UInt16(origin_addr.port)
        @test seen_origin_target[] == "/via-socks-tls"
    finally
        close(client)
        HTTP.@try_ignore TL.close(origin_listener)
        HTTP.@try_ignore NC.close(proxy_listener)
    end
    end
end

@testset "HTTP SOCKS5 proxied connections are pooled and reused" begin
    listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    laddr = NC.addr(listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    handshakes = Ref(0)
    seen_targets = String[]
    server_task = errormonitor(Threads.@spawn begin
        conn = NC.accept(listener)
        try
            _socks_read_greeting_proxy!(conn)
            _socks_select_method_proxy!(conn, 0x00)
            _socks_read_connect_request_proxy!(conn)
            handshakes[] += 1
            _socks_write_success_proxy!(conn)
            for i in 1:2
                req = HT.read_request(HT._ConnReader(conn))
                push!(seen_targets, req.target)
                _send_response_proxy!(conn, req; body_text = "reuse-$(i)", close_conn = i == 2)
            end
        finally
            HTTP.@try_ignore NC.close(conn)
        end
        return nothing
    end)
    client = HT.Client(transport = HT.Transport(proxy = HT.ProxyURL("socks5://$(proxy_address)"), max_idle_per_host = 4, max_idle_total = 4), prefer_http2 = false)
    try
        first_response = HT.get!(client, "example.com:80", "/reuse-1"; secure = false, protocol = :h1)
        @test first_response.status == 200
        @test String(_read_all_proxy(first_response.body)) == "reuse-1"
        second_response = HT.get!(client, "example.com:80", "/reuse-2"; secure = false, protocol = :h1)
        @test second_response.status == 200
        @test String(_read_all_proxy(second_response.body)) == "reuse-2"
        _wait_task_proxy!(server_task)
        @test handshakes[] == 1
        @test seen_targets == ["/reuse-1", "/reuse-2"]
    finally
        close(client)
        HTTP.@try_ignore NC.close(listener)
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
            response = HT.Response(200, HT.BytesBody(payload); content_length = length(payload), request = req)
            io = IOBuffer()
            HT.write_response!(io, response)
            write(conn, take!(io))
        finally
            HTTP.@try_ignore TL.close(conn)
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
            HTTP.@try_ignore NC.close(client_conn)
            HTTP.@try_ignore NC.close(origin_conn)
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
        HT.set_deadline!(HT.get_request_context(request), Int64(time_ns()) + 3_000_000_000)
        response = HT.do!(client, origin_address, request; secure = true, protocol = :h1)
        @test response.status == 200
        @test String(_read_all_proxy(response.body)) == "tls-proxied"
        close(client)
        _wait_task_proxy!(origin_task)
        _wait_task_proxy!(proxy_task)
        @test seen_connect_host[] == origin_address
        @test seen_proxy_auth[] == "Basic " * Base64.base64encode("user:pass")
        @test seen_origin_target[] == "/via-proxy"
    finally
        close(client)
        HTTP.@try_ignore TL.close(origin_listener)
        HTTP.@try_ignore NC.close(proxy_listener)
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
                HTTP.@try_ignore NC.close(conn)
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
        HTTP.@try_ignore NC.close(listener)
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
            HTTP.@try_ignore NC.close(conn)
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
        HTTP.@try_ignore NC.close(listener)
    end
end

@testset "HTTP default client surfaces CGI HTTP_PROXY refusal" begin
    if _http_windows_ci()
        @test_skip true
        return
    end
    _reset_default_http_client_proxy!()
    try
        err = withenv(
                "HTTP_PROXY" => "http://cgi-http-proxy.local:8080",
                "http_proxy" => nothing,
                "NO_PROXY" => nothing,
                "no_proxy" => nothing,
                "REQUEST_METHOD" => "POST",
            ) do
            try
                HT.get("http://public.local:80/cgi-refusal")
                nothing
            catch err
                err
            finally
                _reset_default_http_client_proxy!()
            end
        end
        @test err isa ArgumentError
        @test occursin("refusing to use HTTP_PROXY value in CGI environment", sprint(showerror, err::ArgumentError))
    finally
        _reset_default_http_client_proxy!()
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
            reader = HT._ConnReader(conn)
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
            HTTP.@try_ignore TL.close(conn)
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
            HTTP.@try_ignore NC.close(client_conn)
            HTTP.@try_ignore NC.close(origin_conn)
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
        HTTP.@try_ignore TL.close(origin_listener)
        HTTP.@try_ignore NC.close(proxy_listener)
    end
    end
end

@testset "HTTP SOCKS5H proxy supports tunneled H2 requests" begin
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
    target_address = ND.join_host_port("example.com", Int(origin_addr.port))
    proxy_listener = ND.listen("tcp", "127.0.0.1:0"; backlog = 8)
    proxy_addr = NC.addr(proxy_listener)::NC.SocketAddrV4
    proxy_address = ND.join_host_port("127.0.0.1", Int(proxy_addr.port))
    seen_h2_path = Ref{Union{Nothing, String}}(nothing)
    seen_socks_host = Ref{Union{Nothing, String}}(nothing)
    seen_socks_port = Ref{UInt16}(0)
    tunnel_done = Base.Event()
    origin_task = errormonitor(Threads.@spawn begin
        conn = TL.accept(origin_listener)
        try
            TL.handshake!(conn)
            preface = _read_exact_h2_proxy!(conn, length(HT._H2_PREFACE))
            @test preface == HT._H2_PREFACE
            reader = HT._ConnReader(conn)
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
            payload = collect(codeunits("h2-socks-proxied"))
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
            HTTP.@try_ignore TL.close(conn)
        end
        return nothing
    end)
    proxy_task = errormonitor(Threads.@spawn begin
        client_conn = NC.accept(proxy_listener)
        origin_conn = NC.connect(ND.HostResolver(), "tcp", origin_address)
        try
            methods = _socks_read_greeting_proxy!(client_conn)
            @test methods == UInt8[0x00]
            _socks_select_method_proxy!(client_conn, 0x00)
            req = _socks_read_connect_request_proxy!(client_conn)
            seen_socks_host[] = req.host
            seen_socks_port[] = req.port
            _socks_write_success_proxy!(client_conn)
            errormonitor(Threads.@spawn _bridge_proxy!(client_conn, origin_conn))
            errormonitor(Threads.@spawn _bridge_proxy!(origin_conn, client_conn))
            wait(tunnel_done)
        finally
            HTTP.@try_ignore NC.close(client_conn)
            HTTP.@try_ignore NC.close(origin_conn)
        end
        return nothing
    end)
    try
        response = HT.get(
            "https://$(target_address)/via-socks-h2";
            proxy = "socks5h://$(proxy_address)",
            protocol = :h2,
            require_ssl_verification = false,
        )
        @test response.status == 200
        @test String(response.body) == "h2-socks-proxied"
        notify(tunnel_done)
        close(HT._default_client!())
        _reset_default_http_client_proxy!()
        _wait_task_proxy!(origin_task)
        _wait_task_proxy!(proxy_task)
        @test seen_socks_host[] == "example.com"
        @test seen_socks_port[] == UInt16(origin_addr.port)
        @test seen_h2_path[] == "/via-socks-h2"
    finally
        notify(tunnel_done)
        _reset_default_http_client_proxy!()
        HTTP.@try_ignore TL.close(origin_listener)
        HTTP.@try_ignore NC.close(proxy_listener)
    end
    end
end
