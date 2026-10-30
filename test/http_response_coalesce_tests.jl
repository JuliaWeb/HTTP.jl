using Test, HTTP, Reseau

mutable struct ResponseWriteProbe <: IO
    bytes::IOBuffer
    writes::Int
    short::Bool
end
ResponseWriteProbe(; short=false) = ResponseWriteProbe(IOBuffer(), 0, short)
function Base.unsafe_write(io::ResponseWriteProbe, p::Ptr{UInt8}, n::UInt)
    io.writes += 1
    count = io.short && n > 0 ? n - 1 : n
    unsafe_write(io.bytes, p, count)
    return count
end
Base.write(io::ResponseWriteProbe, b::UInt8) = unsafe_write(io, Ref(b), UInt(1))

@testset "HTTP/1 reusable response bodies share the head write" begin
    for n in (0, 2, 4096, 4097, 131072), as_string in (false, true)
        body = as_string ? "x"^n : fill(UInt8('x'), n)
        response = HTTP.Response(200, body)
        io = ResponseWriteProbe()
        HTTP.write_response!(io, response)
        expected = "HTTP/1.1 200 OK\r\nContent-Length: $n\r\n\r\n" * "x"^n
        @test String(take!(io.bytes)) == expected
        @test io.writes == (n <= 4096 ? 1 : 2)
        HTTP.write_response!(io, response)
        @test String(take!(io.bytes)) == expected
        @test body == (as_string ? "x"^n : fill(UInt8('x'), n))
    end
    response = HTTP.Response(200, "é")
    io = ResponseWriteProbe()
    HTTP.write_response!(io, response)
    @test String(take!(io.bytes)) == "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\né"
    @test io.writes == 1
    io = ResponseWriteProbe()
    HTTP.write_response!(io, HTTP.Response(200, view(UInt8[1,2,3,4], 2:3)))
    @test take!(io.bytes)[end-1:end] == UInt8[2,3]
    @test io.writes == 1
    for status in (200, 204, 304)
        io = ResponseWriteProbe()
        HTTP.write_response!(io, HTTP.Response(status, "body"), HTTP.Request("HEAD", "/"))
        @test endswith(String(take!(io.bytes)), "\r\n\r\n")
        @test io.writes == 1
    end
    for status in (204, 304)
        io = ResponseWriteProbe()
        HTTP.write_response!(io, HTTP.Response(status, "body"))
        @test endswith(String(take!(io.bytes)), "\r\n\r\n")
        @test io.writes == 1
    end
    io = ResponseWriteProbe()
    HTTP.write_response!(io, HTTP.Response(200, "body"; headers=["Transfer-Encoding"=>"chunked"]))
    @test endswith(String(take!(io.bytes)), "\r\n\r\n4\r\nbody\r\n0\r\n\r\n")
    io = ResponseWriteProbe()
    @test_throws HTTP.ProtocolError HTTP.write_response!(io, HTTP.Response(200, "bad"; content_length=4))
    @test io.writes == 0
    for declared in (2, 4)
        io = ResponseWriteProbe()
        response = HTTP.Response(200, UInt8[1,2,3])
        response.content_length = declared
        @test_throws HTTP.ProtocolError HTTP.write_response!(io, response)
        @test io.writes == 0
    end
    io = ResponseWriteProbe()
    body = UInt8[1,2,3]
    response = HTTP.Response(200, body)
    push!(body, 4)
    @test_throws HTTP.ProtocolError HTTP.write_response!(io, response)
    @test io.writes == 0
    @test_throws HTTP.ProtocolError HTTP.write_response!(ResponseWriteProbe(short=true), HTTP.Response(200, "body"))
end

@testset "HTTP serve sends reusable responses over TCP and TLS" begin
    for tls in (false, true)
        listener = tls ? Reseau.TLS.listen("tcp", "127.0.0.1:0", Reseau.TLS.Config(
            cert_file=joinpath(@__DIR__, "resources", "localhost-only.crt"),
            key_file=joinpath(@__DIR__, "resources", "localhost-only.key"),
        )) : Reseau.TCP.listen("tcp", "127.0.0.1:0")
        responses = Dict(n => HTTP.Response(200, "x"^n) for n in (0, 2, 4096, 4097, 131072))
        server = HTTP.serve!(r -> responses[parse(Int, r.target[2:end])], listener)
        client = HTTP.Client(transport=HTTP.Transport(tls_config=Reseau.TLS.Config(verify_peer=false)), prefer_http2=false)
        url = "$(tls ? "https" : "http")://127.0.0.1:$(HTTP.port(server))"
        try
            for _ in 1:2, n in keys(responses)
                response = HTTP.get("$url/$n"; client, retry=false)
                @test response.status == 200
                @test String(response.body) == "x"^n
            end
            head = HTTP.request("HEAD", "$url/4096"; client, retry=false)
            @test isempty(head.body)
            @test HTTP.header(head,"Content-Length") == "4096"
            @test all(r.body == "x"^n for (n,r) in responses)
        finally
            close(client)
            HTTP.forceclose(server)
            wait(server)
        end
    end
end
