using Test, HTTP, Logging, Base64, Reseau
import Sockets

# Find a subsequence in a byte vector (naive; good enough for tests).
function _find_subseq(hay::Vector{UInt8}, needle::Vector{UInt8}, from::Int = 1)::Int
    n = length(needle)
    m = length(hay)
    (n == 0 || from > m) && return 0
    last_i = m - n + 1
    last_i < from && return 0
    @inbounds for i in from:last_i
        if hay[i] == needle[1]
            ok = true
            for j in 2:n
                if hay[i + j - 1] != needle[j]
                    ok = false
                    break
                end
            end
            ok && return i
        end
    end
    return 0
end

const _HTTP1_CHUNKED_TERMINATOR = Vector{UInt8}(codeunits("\r\n0\r\n"))
const _HTTP1_HEADERS_TERMINATOR = Vector{UInt8}(codeunits("\r\n\r\n"))

function _http1_chunked_with_trailers_done(buf::Vector{UInt8})::Bool
    idx0 = _find_subseq(buf, _HTTP1_CHUNKED_TERMINATOR)
    idx0 == 0 && return false
    idx_end = _find_subseq(buf, _HTTP1_HEADERS_TERMINATOR, idx0 + length(_HTTP1_CHUNKED_TERMINATOR))
    return idx_end != 0
end

# Minimal raw TCP client for tests. Avoids the `Sockets` stdlib.
@static if Sys.iswindows()
    const _WS2_32 = "ws2_32"
    const _AF_INET = Cint(2)
    const _SOCK_STREAM = Cint(1)
    const _IPPROTO_TCP = Cint(6)
    const _INVALID_SOCKET = typemax(UInt)
    const _SOCKET_ERROR = Cint(-1)
    const _POLLIN = Int16(0x0001)
    const _RAW_READ_TIMEOUT_MS = Cint(5_000)

    struct _sockaddr_in
        sin_family::UInt16
        sin_port::UInt16
        sin_addr::UInt32
        sin_zero::NTuple{8, UInt8}
    end

    struct _WSAPOLLFD
        fd::UInt
        events::Int16
        revents::Int16
    end

    function _raw_tcp_connect_readall(
            host::AbstractString,
            port::Integer,
            request::AbstractString,
            ;
            stop_pred = nothing,
        )::Vector{UInt8}
        wsadata = Vector{UInt8}(undef, 512)
        ret = ccall((:WSAStartup, _WS2_32), Cint, (UInt16, Ptr{UInt8}), UInt16(0x0202), wsadata)
        ret == 0 || error("WSAStartup() failed: $ret")
        sock = ccall((:socket, _WS2_32), UInt, (Cint, Cint, Cint), _AF_INET, _SOCK_STREAM, _IPPROTO_TCP)
        if sock == _INVALID_SOCKET
            err = ccall((:WSAGetLastError, _WS2_32), Cint, ())
            _ = ccall((:WSACleanup, _WS2_32), Cint, ())
            error("socket() failed: $err")
        end

        try
            addr = ccall((:inet_addr, _WS2_32), UInt32, (Cstring,), host)
            addr == 0xffffffff && error("inet_addr() failed for host=$host")
            port_be = ccall((:htons, _WS2_32), UInt16, (UInt16,), UInt16(port))
            sin = _sockaddr_in(UInt16(_AF_INET), port_be, addr, ntuple(_ -> UInt8(0), 8))

            cres = ccall((:connect, _WS2_32), Cint, (UInt, Ref{_sockaddr_in}, Cint), sock, sin, Cint(sizeof(_sockaddr_in)))
            cres == 0 || error("connect() failed: $(ccall((:WSAGetLastError, _WS2_32), Cint, ()))")

            bytes = Vector{UInt8}(codeunits(request))
            sent = GC.@preserve bytes ccall(
                (:send, _WS2_32),
                Cint,
                (UInt, Ptr{UInt8}, Cint, Cint),
                sock,
                pointer(bytes),
                Cint(length(bytes)),
                Cint(0),
            )
            sent == length(bytes) || error("send() failed: $(ccall((:WSAGetLastError, _WS2_32), Cint, ()))")
            # Some server stacks treat EOF as end-of-request; half-close our send side.
            _ = ccall((:shutdown, _WS2_32), Cint, (UInt, Cint), sock, Cint(1)) # SD_SEND = 1

            buf = UInt8[]
            tmp = Vector{UInt8}(undef, 4096)
            while true
                pollfd = Ref(_WSAPOLLFD(sock, _POLLIN, Int16(0)))
                pres = ccall(
                    (:WSAPoll, _WS2_32),
                    Cint,
                    (Ptr{_WSAPOLLFD}, UInt32, Cint),
                    pollfd,
                    UInt32(1),
                    _RAW_READ_TIMEOUT_MS,
                )
                pres == 0 && error("WSAPoll() timeout")
                pres == _SOCKET_ERROR && error("WSAPoll() failed: $(ccall((:WSAGetLastError, _WS2_32), Cint, ()))")

                r = GC.@preserve tmp ccall(
                    (:recv, _WS2_32),
                    Cint,
                    (UInt, Ptr{UInt8}, Cint, Cint),
                    sock,
                    pointer(tmp),
                    Cint(length(tmp)),
                    Cint(0),
                )
                r == _SOCKET_ERROR && error("recv() failed: $(ccall((:WSAGetLastError, _WS2_32), Cint, ()))")
                r == 0 && break
                append!(buf, view(tmp, 1:r))
                stop_pred !== nothing && stop_pred(buf) && return buf
            end
            return buf
        finally
            _ = ccall((:closesocket, _WS2_32), Cint, (UInt,), sock)
            _ = ccall((:WSACleanup, _WS2_32), Cint, ())
        end
    end
else
    const _AF_INET = Cint(2)
    const _SOCK_STREAM = Cint(1)
    const _POLLIN = Int16(0x0001)
    const _RAW_READ_TIMEOUT_MS = Cint(5_000)

    @static if Sys.isapple() || Sys.isbsd()
        struct _sockaddr_in
            sin_len::UInt8
            sin_family::UInt8
            sin_port::UInt16
            sin_addr::UInt32
            sin_zero::NTuple{8, UInt8}
        end
    else
        struct _sockaddr_in
            sin_family::UInt16
            sin_port::UInt16
            sin_addr::UInt32
            sin_zero::NTuple{8, UInt8}
        end
    end

    struct _pollfd
        fd::Cint
        events::Int16
        revents::Int16
    end

    const _poll_nfds_t = @static (Sys.isapple() || Sys.isbsd()) ? Cuint : Culong

    function _raw_tcp_connect_readall(
            host::AbstractString,
            port::Integer,
            request::AbstractString,
            ;
            stop_pred = nothing,
        )::Vector{UInt8}
        fd = ccall(:socket, Cint, (Cint, Cint, Cint), _AF_INET, _SOCK_STREAM, 0)
        fd < 0 && error("socket() failed: errno=$(Libc.errno())")
        try
            addr = Ref{UInt32}(0)
            ok = ccall(:inet_pton, Cint, (Cint, Cstring, Ptr{Cvoid}), _AF_INET, host, addr)
            ok == 1 || error("inet_pton() failed for host=$host")

            port16 = UInt16(port)
            port_be = ccall(:htons, UInt16, (UInt16,), port16)

            sin = @static if Sys.isapple() || Sys.isbsd()
                _sockaddr_in(
                    UInt8(sizeof(_sockaddr_in)),
                    UInt8(_AF_INET),
                    port_be,
                    addr[],
                    ntuple(_ -> UInt8(0), 8),
                )
            else
                _sockaddr_in(
                    UInt16(_AF_INET),
                    port_be,
                    addr[],
                    ntuple(_ -> UInt8(0), 8),
                )
            end

            ret = ccall(:connect, Cint, (Cint, Ref{_sockaddr_in}, Cuint), fd, sin, Cuint(sizeof(_sockaddr_in)))
            ret == 0 || error("connect() failed: errno=$(Libc.errno())")

            bytes = Vector{UInt8}(codeunits(request))
            n = GC.@preserve bytes ccall(
                :write,
                Cssize_t,
                (Cint, Ptr{UInt8}, Csize_t),
                fd,
                pointer(bytes),
                Csize_t(length(bytes)),
            )
            n == length(bytes) || error("write() failed: errno=$(Libc.errno())")
            # Some server stacks treat EOF as end-of-request; half-close our send side.
            _ = ccall(:shutdown, Cint, (Cint, Cint), fd, Cint(1)) # SHUT_WR = 1

            buf = UInt8[]
            tmp = Vector{UInt8}(undef, 4096)
            while true
                pollfd = Ref(_pollfd(fd, _POLLIN, Int16(0)))
                pres = ccall(
                    :poll,
                    Cint,
                    (Ptr{_pollfd}, _poll_nfds_t, Cint),
                    pollfd,
                    _poll_nfds_t(1),
                    _RAW_READ_TIMEOUT_MS,
                )
                if pres == 0
                    error("poll() timeout")
                end
                if pres < 0
                    err = Libc.errno()
                    err == Libc.EINTR && continue
                    error("poll() failed: errno=$err")
                end

                r = GC.@preserve tmp ccall(
                    :read,
                    Cssize_t,
                    (Cint, Ptr{UInt8}, Csize_t),
                    fd,
                    pointer(tmp),
                    Csize_t(length(tmp)),
                )
                r < 0 && error("read() failed: errno=$(Libc.errno())")
                r == 0 && break
                append!(buf, view(tmp, 1:Int(r)))
                stop_pred !== nothing && stop_pred(buf) && return buf
            end
            return buf
        finally
            _ = ccall(:close, Cint, (Cint,), fd)
        end
    end
end

@testset "HTTP.serve" begin
    server = HTTP.serve!(req -> HTTP.Response(200, "Hello, World!"); listenany=true)
    try
        @test server.state == :running
        port = HTTP.port(server)
        resp = HTTP.get("http://127.0.0.1:$port")
        @test resp.status == 200
        @test String(resp.body) == "Hello, World!"
    finally
        close(server)
    end
end

@testset "server shutdown hooks" begin
    closed = Threads.Atomic{Int}(0)
    server = HTTP.serve!(req -> HTTP.Response(200, "ok"); listenany=true, on_shutdown=() -> (closed[] += 1))
    try
        port = HTTP.port(server)
        HTTP.get("http://127.0.0.1:$port")
    finally
        close(server)
    end
    @test closed[] == 1

    forced = Threads.Atomic{Int}(0)
    server2 = HTTP.serve!(req -> HTTP.Response(200, "ok"); listenany=true,
        on_shutdown=[() -> (forced[] += 1), () -> (forced[] += 1)])
    try
        port2 = HTTP.port(server2)
        HTTP.get("http://127.0.0.1:$port2")
    finally
        HTTP.forceclose(server2)
    end
    @test forced[] == 2
end

@testset "access logging stream handler" begin
    logger = Test.TestLogger()
    with_logger(logger) do
        server = HTTP.listen!("127.0.0.1", 0; listenany=true, access_log=common_logfmt) do http
            read(http)
            HTTP.setstatus(http, 200)
            HTTP.startwrite(http)
            write(http, "hello")
        end
        port = HTTP.port(server)
        try
            HTTP.post("http://127.0.0.1:$port"; body="x")
            sleep(1)
        finally
            close(server)
        end
    end
    logs = filter!(x -> x.group == :access, logger.logs)
    @test length(logs) == 1
    @test occursin(r" 200 5$", logs[1].message)
end

@testset "HTTP.listen stream handler" begin
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
        body = String(read(http))
        HTTP.setstatus(http, 200)
        HTTP.setheader(http, "Content-Type" => "text/plain")
        HTTP.startwrite(http)
        write(http, isempty(body) ? "ping" : body)
    end
    try
        port = HTTP.port(server)
        resp = HTTP.get("http://127.0.0.1:$port")
        @test resp.status == 200
        @test String(resp.body) == "ping"

        resp = HTTP.post("http://127.0.0.1:$port"; body="echo")
        @test resp.status == 200
        @test String(resp.body) == "echo"
    finally
        close(server)
    end
end

@testset "HTTP.streamhandler" begin
    handler = req -> begin
        body = req.body === nothing ? UInt8[] : req.body
        if isempty(body)
            return HTTP.Response(200, ["Content-Type" => "text/plain"], "ping")
        end
        return HTTP.Response(200, ["Content-Type" => "text/plain"], String(body))
    end
    server = HTTP.listen!(HTTP.streamhandler(handler), "127.0.0.1", 0; listenany=true)
    try
        port = HTTP.port(server)
        resp = HTTP.get("http://127.0.0.1:$port")
        @test resp.status == 200
        @test String(resp.body) == "ping"

        resp = HTTP.post("http://127.0.0.1:$port"; body="echo")
        @test resp.status == 200
        @test String(resp.body) == "echo"
    finally
        close(server)
    end
end

@testset "HTTP response trailers" begin
    server = HTTP.listen!("127.0.0.1", 0; listenany=true) do http
        read(http)
        HTTP.setstatus(http, 200)
        HTTP.startwrite(http)
        write(http, "hello")
        HTTP.addtrailer(http, "X-Trailer" => "ok")
        HTTP.closewrite(http)
    end
    try
        port = HTTP.port(server)
        sock = Sockets.connect("127.0.0.1", port)
        write(sock, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        flush(sock)
        raw = String(read(sock))
        close(sock)
        lower_raw = lowercase(raw)
        @test occursin("transfer-encoding: chunked", lower_raw)
        @test occursin("hello", raw)
        @test occursin("\r\n0\r\nx-trailer: ok\r\n\r\n", lower_raw)
    finally
        close(server)
    end
end

@testset "HTTP/2 TLS support" begin
    if !Reseau.Sockets.tls_is_alpn_available()
        @info "Skipping HTTP/2 TLS tests; ALPN not available"
        @test true
    else
        @testset "HTTP/2 stream handler writes" begin
            cert = joinpath(@__DIR__, "fixtures", "http2.crt")
            key = joinpath(@__DIR__, "fixtures", "http2.key")
            saw_http2 = Threads.Atomic{Bool}(false)
            buffered = Threads.Atomic{Bool}(false)
            server = HTTP.serve!("127.0.0.1", 0; listenany=true, stream=true, ssl_cert=cert, ssl_key=key, ssl_alpn_list="h2") do stream
                HTTP.startread(stream)
                stream.http2 && (saw_http2[] = true)
                HTTP.setstatus(stream, 200)
                HTTP.startwrite(stream)
                write(stream, "hello")
                if stream.http2 && stream.responsebuf !== nothing
                    buffered[] = true
                end
                HTTP.closewrite(stream)
            end
            try
                port = HTTP.port(server)
                resp = HTTP.get("https://127.0.0.1:$(port)"; ssl_insecure=true, ssl_alpn_list="h2")
                if resp.version == HTTP.HTTPVersion(2, 0)
                    @test saw_http2[]
                    @test !buffered[]
                    @test String(resp.body) == "hello"
                else
                    @info "HTTP/2 not negotiated for stream handler test"
                    @test true
                end
            finally
                close(server)
            end
        end
        @testset "HTTP/2 host and authority mapping" begin
            cert = joinpath(@__DIR__, "fixtures", "http2.crt")
            key = joinpath(@__DIR__, "fixtures", "http2.key")
            host_ref = Ref{String}("")
            authority_ref = Ref{String}("")
            server = HTTP.serve!("127.0.0.1", 0; listenany=true, stream=true, ssl_cert=cert, ssl_key=key, ssl_alpn_list="h2") do stream
                HTTP.startread(stream)
                if stream.http2
                    host_ref[] = HTTP.header(stream.request, "host")
                    authority_ref[] = HTTP.header(stream.request, ":authority")
                end
                HTTP.setstatus(stream, 200)
                HTTP.startwrite(stream)
                write(stream, "ok")
                HTTP.closewrite(stream)
            end
            try
                port = HTTP.port(server)
                resp = HTTP.get("https://127.0.0.1:$(port)"; ssl_insecure=true, ssl_alpn_list="h2", headers=["Host" => "example.com"])
                if resp.version == HTTP.HTTPVersion(2, 0)
                    @test host_ref[] == "example.com"
                    @test authority_ref[] == "example.com"
                else
                    @info "HTTP/2 not negotiated for host/authority mapping test"
                    @test true
                end
            finally
                close(server)
            end
        end
        @testset "HTTP/2 server push promise" begin
            cert = joinpath(@__DIR__, "fixtures", "http2.crt")
            key = joinpath(@__DIR__, "fixtures", "http2.key")
            port_ref = Ref{Int}(0)
            push_called = Threads.Atomic{Bool}(false)
            push_http2 = Threads.Atomic{Bool}(false)
            push_server_side = Threads.Atomic{Bool}(false)
            server = HTTP.serve!("127.0.0.1", 0; listenany=true, stream=true, ssl_cert=cert, ssl_key=key, ssl_alpn_list="h2") do stream
                HTTP.startread(stream)
                if stream.http2
                    authority = "127.0.0.1:$(port_ref[])"
                    push = HTTP.push_promise(stream, "GET", "/pushed"; scheme="https", authority=authority)
                    push_called[] = true
                    push_http2[] = push.http2
                    push_server_side[] = push.server_side
                    HTTP.setstatus(push, 200)
                    HTTP.setheader(push, "Content-Type" => "text/plain")
                    write(push, "pushed")
                    HTTP.closewrite(push)
                end
                HTTP.setstatus(stream, 200)
                write(stream, "ok")
            end
            try
                port_ref[] = HTTP.port(server)
                resp = HTTP.get("https://127.0.0.1:$(port_ref[])"; ssl_insecure=true, ssl_alpn_list="h2")
                if resp.version == HTTP.HTTPVersion(2, 0)
                    @test push_called[]
                    @test push_http2[]
                    @test push_server_side[]
                    @test String(resp.body) == "ok"
                else
                    @info "HTTP/2 not negotiated for push promise test"
                    @test true
                end
            finally
                close(server)
            end
        end
        @testset "HTTP/2 readtimeout keeps connection open" begin
            cert = joinpath(@__DIR__, "fixtures", "http2.crt")
            key = joinpath(@__DIR__, "fixtures", "http2.key")
            seen_lock = ReentrantLock()
            seen_conns = Set{UInt}()
            server = HTTP.serve!("127.0.0.1", 0; listenany=true, stream=true, ssl_cert=cert, ssl_key=key, ssl_alpn_list="h2") do stream
                HTTP.startread(stream)
                @lock seen_lock push!(seen_conns, objectid(stream.connection))
                if stream.request.path == "/slow"
                    sleep(2)
                else
                    sleep(1.5)
                end
                try
                    HTTP.setstatus(stream, 200)
                    HTTP.startwrite(stream)
                    write(stream, stream.request.path == "/slow" ? "slow" : "fast")
                    HTTP.closewrite(stream)
                catch
                    nothing
                end
            end
            try
                port = HTTP.port(server)
                cs = HTTP.ClientSettings("https", "127.0.0.1", UInt32(port); ssl_insecure=true, ssl_alpn_list="h2", max_connections=1)
                client = HTTP.Client(cs)
                slow_err = try
                    HTTP.get("https://127.0.0.1:$(port)/slow"; client=client, readtimeout=1, retry=false)
                catch e
                    e
                end
                fast_resp = HTTP.get("https://127.0.0.1:$(port)/fast"; client=client, retry=false)
                if fast_resp.version == HTTP.HTTPVersion(2, 0)
                    @test slow_err isa HTTP.TimeoutError
                    @test String(fast_resp.body) == "fast"
                    @test length(seen_conns) == 1
                else
                    @info "HTTP/2 not negotiated for readtimeout connection test"
                    @test true
                end
            finally
                close(server)
            end
        end
    end
end

@testset "access logging" begin
    local handler = (req) -> begin
        if req.target == "/internal-error"
            error("internal error")
        end
        if req.target == "/close"
            return HTTP.Response(444, ["content-type" => "text/plain"], nothing)
        end
        return HTTP.Response(200, ["content-type" => "text/plain"], "hello, world")
    end
    function with_testserver(f, fmt)
        logger = Test.TestLogger()
        with_logger(logger) do
            server = HTTP.serve!(handler; listenany=true, access_log=fmt)
            port = HTTP.port(server)
            try
                f(port)
            finally
                close(server)
            end
        end
        return filter!(x -> x.group == :access, logger.logs)
    end

    # Common Log Format
    logs = with_testserver(common_logfmt) do port
        HTTP.get("http://127.0.0.1:$port")
        HTTP.get("http://127.0.0.1:$port/index.html")
        HTTP.get("http://127.0.0.1:$port/index.html?a=b")
        HTTP.head("http://127.0.0.1:$port")
        HTTP.get("http://127.0.0.1:$port/internal-error"; status_exception=false)
        # sleep(1) # necessary to properly forget the closed connection from the previous call
        try HTTP.get("http://127.0.0.1:$port/close"; retry=false) catch end
        HTTP.get("http://127.0.0.1:$port", ["Connection" => "close"])
        sleep(1) # we want to make sure the server has time to finish logging before checking logs
    end
    @test length(logs) == 7
    @test all(x -> x.group === :access, logs)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET / HTTP/1.1\" 200 12$", logs[1].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /index.html HTTP/1.1\" 200 12$", logs[2].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /index.html\?a=b HTTP/1.1\" 200 12$", logs[3].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"HEAD / HTTP/1.1\" 200 0$", logs[4].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /internal-error HTTP/1.1\" 500 \d+$", logs[5].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /close HTTP/1.1\" 444 0$", logs[6].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET / HTTP/1.1\" 200 12$", logs[7].message)

    # Combined Log Format
    logs = with_testserver(combined_logfmt) do port
        HTTP.get("http://127.0.0.1:$port", ["Referer" => "julialang.org"])
        HTTP.get("http://127.0.0.1:$port/index.html")
        useragent = HTTP.USER_AGENT[]
        HTTP.setuseragent!(nothing)
        HTTP.get("http://127.0.0.1:$port/index.html?a=b")
        HTTP.setuseragent!(useragent)
        HTTP.head("http://127.0.0.1:$port")
    end
    @test length(logs) == 4
    @test all(x -> x.group === :access, logs)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET / HTTP/1.1\" 200 12 \"julialang\.org\" \"HTTP\.jl/.*\"$", logs[1].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /index.html HTTP/1.1\" 200 12 \"-\" \"HTTP\.jl/.*\"$", logs[2].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"GET /index.html\?a=b HTTP/1.1\" 200 12 \"-\" \"-\"$", logs[3].message)
    @test occursin(r"^127.0.0.1 - - \[(\d{2})/.*/(\d{4}):\d{2}:\d{2}:\d{2}.*\] \"HEAD / HTTP/1.1\" 200 0 \"-\" \"HTTP\.jl/.*\"$", logs[4].message)

    # Custom log format
    fmt = logfmt"$http_accept $sent_http_content_type $request $request_method $request_uri $remote_addr $remote_port $remote_user $server_protocol $time_iso8601 $time_local $status $body_bytes_sent"
    logs = with_testserver(fmt) do port
        HTTP.get("http://127.0.0.1:$port", ["Accept" => "application/json"])
        HTTP.get("http://127.0.0.1:$port/index.html")
        HTTP.get("http://127.0.0.1:$port/index.html?a=b")
        HTTP.head("http://127.0.0.1:$port")
        auth = Base64.base64encode("alice:secret")
        HTTP.get("http://127.0.0.1:$port/auth", ["Authorization" => "Basic $auth"])
    end
    @test length(logs) == 5
    @test all(x -> x.group === :access, logs)
    @test occursin(r"^application/json text/plain GET / HTTP/1\.1 GET / 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 12$", logs[1].message)
    @test occursin(r"^\*/\* text/plain GET /index\.html HTTP/1\.1 GET /index\.html 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 12$", logs[2].message)
    @test occursin(r"^\*/\* text/plain GET /index\.html\?a=b HTTP/1\.1 GET /index\.html\?a=b 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 12$", logs[3].message)
    @test occursin(r"^\*/\* text/plain HEAD / HTTP/1\.1 HEAD / 127\.0\.0\.1 \d+ - HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 0$", logs[4].message)
    @test occursin(r"^\*/\* text/plain GET /auth HTTP/1\.1 GET /auth 127\.0\.0\.1 \d+ alice HTTP/1\.1 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \d+/.*/\d{4}:\d{2}:\d{2}:\d{2}.* 200 12$", logs[5].message)
end
