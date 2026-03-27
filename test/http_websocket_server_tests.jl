using Test
using HTTP
using Reseau

const HT = HTTP
const W = HTTP.WebSockets
const NC = Reseau.TCP
const TL = Reseau.TLS
const ND = Reseau.HostResolvers

const _TLS_CERT_PATH = joinpath(@__DIR__, "resources", "unittests.crt")
const _TLS_KEY_PATH = joinpath(@__DIR__, "resources", "unittests.key")

function _wait_server_addr(server; timeout_s::Float64 = 5.0)
    _ = timeout_s
    return W.server_addr(server)
end

function _raw_upgrade_response(address::String; secure::Bool = false, origin::Union{Nothing, String} = nothing, key::Union{Nothing, String} = nothing)
    conn = secure ?
        TL.client(NC.connect(ND.HostResolver(), "tcp", address), TL.Config(server_name = "127.0.0.1", verify_peer = false)) :
        NC.connect(ND.HostResolver(), "tcp", address)
    try
        secure && TL.handshake!(conn::TL.Conn)
        headers = HT.Headers()
        HT.setheader(headers, "Upgrade", "websocket")
        HT.setheader(headers, "Connection", "Upgrade")
        HT.setheader(headers, "Sec-WebSocket-Key", key === nothing ? HT.ws_random_handshake_key() : key::String)
        HT.setheader(headers, "Sec-WebSocket-Version", "13")
        origin === nothing || HT.setheader(headers, "Origin", origin)
        request = HT.Request("GET", "/ws"; headers = headers, host = address, content_length = 0)
        io = IOBuffer()
        HT.write_request!(io, request)
        write(conn, take!(io))
        return HT._streaming_response(HT._read_incoming_response(HT._ConnReader(conn), request))
    finally
        try
            if conn isa TL.Conn
                TL.close(conn::TL.Conn)
            else
                NC.close(conn::NC.Conn)
            end
        catch
        end
    end
end

function _read_all_ws_body(body::HT.AbstractBody)::String
    out = UInt8[]
    buf = Vector{UInt8}(undef, 64)
    while true
        n = HT.body_read!(body, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    return String(out)
end

@testset "HTTP.WebSockets server listen! over ws" begin
    server = W.listen!("127.0.0.1", 0) do ws
        msg = W.receive(ws)
        W.send(ws, msg)
    end
    try
        address = _wait_server_addr(server)
        ws = W.open("ws://$address/echo")
        try
            W.send(ws, "hello")
            @test W.receive(ws) == "hello"
        finally
            close(ws)
        end
    finally
        close(server)
    end
end

@testset "HTTP.WebSockets server listen! over wss" begin
    server = W.listen!(
        "127.0.0.1",
        0;
        tls_config = TL.Config(verify_peer = false, cert_file = _TLS_CERT_PATH, key_file = _TLS_KEY_PATH),
    ) do ws
        W.send(ws, "secure")
    end
    try
        address = _wait_server_addr(server)
        ws = W.open("wss://$address/secure"; require_ssl_verification = false)
        try
            @test W.receive(ws) == "secure"
        finally
            close(ws)
        end
    finally
        close(server)
    end
end

@testset "HTTP.WebSockets server subprotocol negotiation" begin
    server = W.listen!("127.0.0.1", 0; subprotocols = ["chat"]) do ws
        W.send(ws, "ok")
    end
    try
        address = _wait_server_addr(server)
        ws = W.open("ws://$address/proto"; subprotocols = ["chat", "superchat"])
        try
            @test ws.subprotocol == "chat"
            @test W.receive(ws) == "ok"
        finally
            close(ws)
        end
    finally
        close(server)
    end
end

@testset "HTTP.WebSockets server default origin policy rejects mismatched origins" begin
    server = W.listen!("127.0.0.1", 0) do ws
        W.send(ws, "nope")
    end
    try
        address = _wait_server_addr(server)
        response = _raw_upgrade_response(address; origin = "http://evil.example")
        @test response.status == 403
    finally
        close(server)
    end
end

@testset "HTTP.WebSockets server custom origin policy can allow requests" begin
    server = W.listen!(
        "127.0.0.1",
        0;
        check_origin = (request, origin) -> true,
    ) do ws
        W.send(ws, "allowed")
    end
    try
        address = _wait_server_addr(server)
        ws = W.open("ws://$address/origin"; headers = ["Origin" => "http://evil.example"])
        try
            @test W.receive(ws) == "allowed"
        finally
            close(ws)
        end
    finally
        close(server)
    end
end

@testset "HTTP.WebSockets server rejects invalid websocket keys" begin
    server = W.listen!("127.0.0.1", 0) do ws
        W.send(ws, "nope")
    end
    try
        address = _wait_server_addr(server)
        for key in ("x", "%%%", "AQIDBA==")
            response = _raw_upgrade_response(address; key = key)
            try
                @test response.status == 400
                @test occursin("invalid websocket key", _read_all_ws_body(response.body))
            finally
                HT.body_close!(response.body)
            end
        end
    finally
        close(server)
    end
end

@testset "HTTP.WebSockets server close notifies active sessions" begin
    started = Channel{Nothing}(1)
    finished = Channel{Nothing}(1)
    server = W.listen!("127.0.0.1", 0) do ws
        put!(started, nothing)
        try
            while true
                W.receive(ws)
            end
        catch
        finally
            put!(finished, nothing)
        end
    end
    ws = nothing
    try
        address = _wait_server_addr(server)
        ws = W.open("ws://$address/shutdown")
        take!(started)
        close(server)
        @test isready(finished)
        take!(finished)
        err = try
            W.receive(ws::W.WebSocket)
            nothing
        catch err
            err
        end
        @test err isa W.WebSocketError
        @test (err::W.WebSocketError).message.code == 1001
    finally
        ws === nothing || try
            close(ws::W.WebSocket)
        catch
        end
    end
end
