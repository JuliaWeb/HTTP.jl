using Test
using HTTP

# HTTP/3 requests to public servers. They need the network, with UDP to port
# 443 allowed, so they run only when HTTP_RUN_LIVE_HTTP3=1.

@testset "HTTP/3 to public servers" begin
    @testset "protocol = :h3 to $(url)" for url in ("https://cloudflare-quic.com/", "https://www.google.com/")
        resp = HTTP.get(url; protocol = :h3, redirect = false, status_exception = false)
        @test resp.version == v"3"
        @test 200 <= resp.status < 400
        @test !isempty(resp.body)
    end

    @testset "Cloudflare sees HTTP/3" begin
        resp = HTTP.get("https://cloudflare.com/cdn-cgi/trace"; protocol = :h3)
        @test "http=http/3" in split(String(resp.body), '\n')
    end

    @testset "Alt-Svc moves $(url) to HTTP/3" for url in ("https://cloudflare-quic.com/", "https://www.google.com/")
        client = HTTP.Client(prefer_http3 = true)
        try
            @test HTTP.get(client, url; status_exception = false).version == v"2"
            @test HTTP.get(client, url; status_exception = false).version == v"3"
        finally
            close(client)
        end
    end
end
