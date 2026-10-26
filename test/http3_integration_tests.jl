using Test
using HTTP
using Reseau

# HTTP/3 through the high-level client: `protocol = :h3`, discovery through
# Alt-Svc, falling back to TCP, and retries.

@isdefined(_H3TestServer) || include("http3_test_server.jl")

const H3I = HTTP
const H3I_TL = Reseau.TLS
const H3I_ND = Reseau.HostResolvers

_h3i_client(; kw...) = H3I.Client(; transport = H3I.Transport(tls_config = H3I_TL.Config(verify_peer = false, server_name = "localhost")), kw...)

function _h3i_protocols_trace(protocols::Vector{Symbol})
    return function (event)
        event isa H3I.RequestEvent && push!(protocols, event.protocol)
        return nothing
    end
end

# An HTTPS server over TCP whose responses advertise `alt_svc`.
function _h3i_tcp_server(alt_svc::AbstractString, body::AbstractString)
    listener = H3I_TL.listen("tcp", "127.0.0.1:0",
        H3I_TL.Config(verify_peer = false, cert_file = _H3T_CERT, key_file = _H3T_KEY, alpn_protocols = ["h2", "http/1.1"]);
        backlog = 8)
    port = Int(H3I_TL.addr(listener).port)
    server = H3I.serve!(listener) do request
        payload = collect(codeunits(body))
        return H3I.Response(200, ["Alt-Svc" => alt_svc]; body = payload)
    end
    return server, port
end

function _h3i_close_tcp(server)
    H3I.forceclose(server)
    wait(server)
end

# A loopback UDP port with nothing listening on it.
function _h3i_closed_udp_port()
    sock = Reseau.UDP.listen(Reseau.UDP.loopback_addr(0))
    port = Int(Reseau.UDP.local_addr(sock).port)
    close(sock)
    return port
end

@testset "HTTP/3 through the client" begin
    @testset "protocol = :h3 sends requests over a pooled QUIC connection" begin
        seen = Channel{_H3TestRequest}(Inf)
        server = _h3t_server() do req, s, conn
            put!(seen, req)
            _h3t_respond!(s, 200, ["content-type" => "text/plain"], "h3:" * something(_h3t_header(req, ":path"), ""))
        end
        client = _h3i_client()
        try
            protocols = Symbol[]
            resp = H3I.request(_h3i_protocols_trace(protocols), "GET", "https://$(_h3t_address(server))/first"; client, protocol = :h3)
            @test resp.status == 200
            @test resp.version == v"3"
            @test String(resp.body) == "h3:/first"
            resp = H3I.request(_h3i_protocols_trace(protocols), "POST", "https://$(_h3t_address(server))/second"; client, protocol = :h3, body = "payload")
            @test String(resp.body) == "h3:/second"
            @test protocols == [:h3, :h3]
            take!(seen)
            @test String(take!(seen).body) == "payload"
            @test length(server.conns) == 1
            # HTTP/3 needs TLS.
            @test_throws ArgumentError H3I.request("GET", "http://$(_h3t_address(server))/"; client, protocol = :h3)
        finally
            close(client)
            _h3t_close(server)
        end
    end

    @testset "Alt-Svc moves an origin to HTTP/3" begin
        seen = Channel{_H3TestRequest}(Inf)
        h3_server = _h3t_server() do req, s, conn
            put!(seen, req)
            _h3t_respond!(s, 200, Pair{String,String}[], "over h3")
        end
        tcp_server, tcp_port = _h3i_tcp_server("h3=\":$(h3_server.port)\"; ma=3600", "over tcp")
        client = _h3i_client(prefer_http3 = true)
        try
            protocols = Symbol[]
            trace = _h3i_protocols_trace(protocols)
            url = "https://127.0.0.1:$(tcp_port)/page"
            @test String(H3I.request(trace, "GET", url; client).body) == "over tcp"
            resp = H3I.request(trace, "GET", url; client)
            @test String(resp.body) == "over h3"
            @test resp.version == v"3"
            @test String(H3I.request(trace, "GET", url; client).body) == "over h3"
            @test protocols == [:h2, :h3, :h3]
            # The alternative serves the origin: the request names it.
            @test _h3t_header(take!(seen), ":authority") == "127.0.0.1:$(tcp_port)"
            # Without prefer_http3, Alt-Svc is ignored.
            plain = _h3i_client()
            try
                plain_protocols = Symbol[]
                H3I.request(_h3i_protocols_trace(plain_protocols), "GET", url; client = plain)
                H3I.request(_h3i_protocols_trace(plain_protocols), "GET", url; client = plain)
                @test plain_protocols == [:h2, :h2]
            finally
                close(plain)
            end
        finally
            close(client)
            _h3i_close_tcp(tcp_server)
            _h3t_close(h3_server)
        end
    end

    @testset "a QUIC connection that cannot be made falls back to TCP" begin
        dead_port = _h3i_closed_udp_port()
        tcp_server, tcp_port = _h3i_tcp_server("h3=\":$(dead_port)\"", "over tcp")
        client = _h3i_client(prefer_http3 = true)
        try
            protocols = Symbol[]
            trace = _h3i_protocols_trace(protocols)
            url = "https://127.0.0.1:$(tcp_port)/"
            for _ in 1:3
                resp = H3I.request(trace, "GET", url; client)
                @test resp.status == 200 && String(resp.body) == "over tcp"
            end
            # HTTP/3 is tried once; the broken alternative is then left alone.
            @test protocols == [:h2, :h3, :h2]
        finally
            close(client)
            _h3i_close_tcp(tcp_server)
        end
    end

    @testset "HTTP/3 is never used through a proxy" begin
        client = _h3i_client(prefer_http3 = true)
        try
            # Fresh for as long as an Int64 of nanoseconds lasts.
            H3I._alt_svc_record!(client.alt_svc, "example.com:443", ["h3=\":443\"; ma=9300000000"], Int64(0))
            direct = H3I._proxy_plan(H3I._normalize_proxy_config(nothing), true, "example.com:443")
            proxied = H3I._proxy_plan(H3I.ProxyURL("http://127.0.0.1:3128"), true, "example.com:443")
            @test H3I._h3_target(client, direct, true, :auto, "example.com:443") == "example.com:443"
            @test H3I._h3_target(client, proxied, true, :auto, "example.com:443") === nothing
            @test_throws ArgumentError H3I._h3_target(client, proxied, true, :h3, "example.com:443")
            @test H3I._h3_target(client, direct, true, :h2, "example.com:443") === nothing
        finally
            close(client)
        end
    end

    @testset "rejected requests are retried, whatever the method" begin
        rejected = Threads.Atomic{Int}(0)
        server = _h3t_server() do req, s, conn
            if Threads.atomic_add!(rejected, 1) == 0
                Reseau.QUIC.reset_stream!(s, H3I._H3_REQUEST_REJECTED)
            else
                _h3t_respond!(s, 200, Pair{String,String}[], "accepted")
            end
        end
        client = _h3i_client()
        try
            retries = Ref(0)
            trace = event -> (event isa H3I.RetryEvent && (retries[] += 1); nothing)
            resp = H3I.request(trace, "POST", "https://$(_h3t_address(server))/"; client, protocol = :h3, body = "x")
            @test String(resp.body) == "accepted"
            @test retries[] == 1
            @test H3I.isrecoverable(H3I.H3StreamResetError(H3I._H3_REQUEST_REJECTED))
            @test H3I.isrecoverable(H3I.H3GoAwayError(UInt64(4)))
            @test !H3I.isrecoverable(H3I.H3StreamResetError(H3I._H3_REQUEST_CANCELLED))
            # A connection that closed under the request, as a reused one
            # can at its idle timeout, is retried like a closed TCP connection.
            closed = Reseau.QUIC.ConnectionError(UInt64(0), "idle timeout", false, false)
            @test H3I.isrecoverable(H3I.ProtocolError("HTTP/3 connection closed", closed))
        finally
            close(client)
            _h3t_close(server)
        end
    end
end
