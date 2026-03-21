using Test
using HTTP
using Reseau

const HT = HTTP
const TL = Reseau.TLS
const NC = Reseau.TCP
const ND = Reseau.HostResolvers

const _TLS_CERT_PATH = joinpath(@__DIR__, "resources", "unittests.crt")
const _TLS_KEY_PATH = joinpath(@__DIR__, "resources", "unittests.key")

function _read_all_integration(body::HT.AbstractBody)::Vector{UInt8}
    out = UInt8[]
    buf = Vector{UInt8}(undef, 32)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return out
end

@testset "HTTP integration TLS auto falls back to h1 on ALPN mismatch" begin
    listener = TL.listen(
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
    laddr = TL.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server = HT.serve!(listener) do request
        payload = collect(codeunits("tls-h1:" * request.target))
        return HT.Response(200; body = HT.BytesBody(payload), content_length = length(payload))
    end
    client = HT.Client(
        transport = HT.Transport(
            tls_config = TL.Config(
                verify_peer = false,
                server_name = "localhost",
                alpn_protocols = ["h2", "http/1.1"],
            ),
            max_idle_per_host = 4,
            max_idle_total = 4,
        ),
        prefer_http2 = true,
    )
    try
        response = HT.get!(client, address, "/auto-tls"; secure = true, protocol = :auto)
        @test response.status == 200
        @test String(_read_all_integration(response.body)) == "tls-h1:/auto-tls"
    finally
        close(client)
        HT.forceclose(server)
        wait(server)
    end
end

@testset "HTTP integration TLS selects h2 via ALPN" begin
    listener = TL.listen(
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
    laddr = TL.addr(listener)::NC.SocketAddrV4
    address = ND.join_host_port("127.0.0.1", Int(laddr.port))
    server = HT.serve!(listener) do request
        payload = collect(codeunits("tls-h2:" * request.target))
        return HT.Response(200; body = HT.BytesBody(payload), content_length = length(payload), proto_major = 2, proto_minor = 0)
    end
    client = HT.Client(
        transport = HT.Transport(
            tls_config = TL.Config(
                verify_peer = false,
                server_name = "localhost",
                alpn_protocols = ["h2"],
            ),
            max_idle_per_host = 4,
            max_idle_total = 4,
        ),
        prefer_http2 = true,
    )
    try
        response = HT.get!(client, address, "/secure-h2"; secure = true, protocol = :h2)
        @test response.status == 200
        @test String(_read_all_integration(response.body)) == "tls-h2:/secure-h2"
    finally
        close(client)
        HT.forceclose(server)
        wait(server)
    end
end

function _wait_http_addr(server::HT.Server; timeout_s::Float64 = 5.0)
    deadline = time() + timeout_s
    while time() < deadline
        try
            return HT.server_addr(server)
        catch
            sleep(0.01)
        end
    end
    error("timed out waiting for HTTP/1 server addr")
end

@testset "HTTP integration protocol selection" begin
    h1_server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            payload = collect(codeunits("h1:" * request.target))
            return HT.Response(200; body = HT.BytesBody(payload), content_length = length(payload))
        end
    h1_address = _wait_http_addr(h1_server)
    client = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4), prefer_http2 = true)
    try
        h1_response = HT.get!(client, h1_address, "/auto-h1"; secure = false, protocol = :auto)
        @test h1_response.status == 200
        @test String(_read_all_integration(h1_response.body)) == "h1:/auto-h1"
    finally
        close(client)
        HT.forceclose(h1_server)
        wait(h1_server)
    end

    h2_server = HT.serve!("127.0.0.1", 0; listenany = true) do request
            payload = collect(codeunits("h2:" * request.target))
            return HT.Response(200; body = HT.BytesBody(payload), content_length = length(payload), proto_major = 2, proto_minor = 0)
        end
    h2_address = _wait_http_addr(h2_server)
    client2 = HT.Client(transport = HT.Transport(max_idle_per_host = 4, max_idle_total = 4), prefer_http2 = true)
    try
        h2_response = HT.get!(client2, h2_address, "/explicit-h2"; secure = false, protocol = :h2)
        @test h2_response.status == 200
        @test String(_read_all_integration(h2_response.body)) == "h2:/explicit-h2"
        @test_throws ArgumentError HT.get!(client2, h2_address, "/bad"; protocol = :bad)
    finally
        close(client2)
        HT.forceclose(h2_server)
        wait(h2_server)
    end
end
