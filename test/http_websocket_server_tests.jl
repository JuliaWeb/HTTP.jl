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

function _raw_upgrade_response(address::String; secure::Bool = false, origin::Union{Nothing, String} = nothing, key::Union{Nothing, String} = nothing)
    conn = secure ?
        TL.client(NC.connect(ND.HostResolver(), "tcp", address), TL.Config(server_name = "127.0.0.1", verify_peer = false)) :
        NC.connect(ND.HostResolver(), "tcp", address)
    try
        secure && TL.handshake!(conn::TL.Conn)
        headers = HT.Headers()
        HT.setheader(headers, "Upgrade", "websocket")
        HT.setheader(headers, "Connection", "Upgrade")
        HT.setheader(headers, "Sec-WebSocket-Key", key === nothing ? HT.WebSockets.ws_random_handshake_key() : key::String)
        HT.setheader(headers, "Sec-WebSocket-Version", "13")
        origin === nothing || HT.setheader(headers, "Origin", origin)
        request = HT.Request("GET", "/ws"; headers = headers, host = address, content_length = 0)
        io = IOBuffer()
        HT.write_request!(io, request)
        write(conn, take!(io))
        return HT._streaming_response(HT._read_incoming_response(HT._ConnReader(conn), request))
    finally
        HTTP.@try_ignore begin
            if conn isa TL.Conn
                TL.close(conn::TL.Conn)
            else
                NC.close(conn::NC.Conn)
            end
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

function _ws_frame(opcode, payload::AbstractVector{UInt8}; fin::Bool = true)
    return W.WsFrame(opcode = UInt8(opcode), payload = Vector{UInt8}(payload), fin = fin)
end

function _ws_frame(opcode, payload::AbstractString; fin::Bool = true)
    return _ws_frame(opcode, collect(codeunits(payload)); fin = fin)
end

function _websocket_error_after_frames(frames::Vector{<:W.WsFrame}; maxframesize::Integer = typemax(Int), maxfragmentation::Integer = W.DEFAULT_MAX_FRAG)
    ws = W.WebSocket(IOBuffer(), () -> nothing; maxframesize = maxframesize, maxfragmentation = maxfragmentation)
    for frame in frames
        W._process_incoming_frame!(ws, frame)
    end
    err = try
        W.receive(ws)
        nothing
    catch ex
        ex
    end
    @test err isa W.WebSocketError
    return err::W.WebSocketError
end

@testset "HTTP.WebSockets server frame error branches" begin
    default_limited = W.WebSocket(IOBuffer(), () -> nothing; is_client = false)
    @test default_limited.maxframesize == W.DEFAULT_MAX_FRAME_SIZE
    @test default_limited.codec.max_incoming_payload_length == UInt64(W.DEFAULT_MAX_FRAME_SIZE)

    header_limited = W.WebSocket(IOBuffer(), () -> nothing; maxframesize = 4, is_client = false)
    @test header_limited.codec.max_incoming_payload_length == UInt64(4)
    # Header declares a masked 5-byte TEXT frame. The codec should reject as
    # soon as the payload length is parsed, before any payload bytes are read.
    @test_throws W.WebSocketProtocolError W._process_incoming_data!(header_limited, UInt8[0x81, 0x85])
    @test isempty(header_limited.codec.decoder.payload_buf)

    too_large = _websocket_error_after_frames([
        _ws_frame(W.WsOpcode.TEXT, "toolong"),
    ]; maxframesize = 3)
    @test too_large.message.code == 1009
    @test too_large.message.reason == "frame too large"

    invalid_close = _websocket_error_after_frames([
        _ws_frame(W.WsOpcode.CLOSE, UInt8[0x03, 0xe7]),
    ])
    @test invalid_close.message.code == 1002
    @test invalid_close.message.reason == "invalid close status code"

    unexpected_continuation = _websocket_error_after_frames([
        _ws_frame(W.WsOpcode.CONTINUATION, "orphan"),
    ])
    @test unexpected_continuation.message.code == 1002
    @test unexpected_continuation.message.reason == "unexpected continuation"

    fragmented = W.WebSocket(IOBuffer(), () -> nothing; maxfragmentation = 2)
    W._process_incoming_frame!(fragmented, _ws_frame(W.WsOpcode.TEXT, "hel"; fin = false))
    W._process_incoming_frame!(fragmented, _ws_frame(W.WsOpcode.CONTINUATION, "lo"))
    @test W.receive(fragmented) == "hello"

    too_fragmented = _websocket_error_after_frames([
        _ws_frame(W.WsOpcode.TEXT, "a"; fin = false),
        _ws_frame(W.WsOpcode.CONTINUATION, "b"),
    ]; maxfragmentation = 1)
    @test too_fragmented.message.code == 1009
    @test too_fragmented.message.reason == "message too large"

    unexpected_data = _websocket_error_after_frames([
        _ws_frame(W.WsOpcode.TEXT, "a"; fin = false),
        _ws_frame(W.WsOpcode.BINARY, UInt8[0x62]),
    ])
    @test unexpected_data.message.code == 1002
    @test unexpected_data.message.reason == "unexpected new data frame"
end

@testset "HTTP.WebSockets server listen! over ws" begin
    server = W.listen!("127.0.0.1", 0) do ws
        msg = W.receive(ws)
        W.send(ws, msg)
    end
    try
        address = W.server_addr(server)
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
        address = W.server_addr(server)
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

@testset "HTTP.WebSockets client read_idle_timeout over wss (#1062)" begin
    server = W.listen!(
        "127.0.0.1",
        0;
        tls_config = TL.Config(verify_peer = false, cert_file = _TLS_CERT_PATH, key_file = _TLS_KEY_PATH),
    ) do ws
        W.send(ws, "hello")
        sleep(3)                       # stay silent so the client idle timeout fires first
    end
    try
        address = W.server_addr(server)
        msgs = String[]
        err = nothing
        try
            W.open("wss://$address/"; read_idle_timeout = 1.0, require_ssl_verification = false, suppress_close_error = true) do ws
                push!(msgs, String(W.receive(ws)))   # "hello" arrives during activity
                W.receive(ws)                          # no more data -> idle timeout
            end
        catch e
            err = e
        end
        @test msgs == ["hello"]
        @test err isa W.WebSocketError
        @test err !== nothing && (err::W.WebSocketError).message.code == 1006
        @test err !== nothing && occursin("idle timeout", (err::W.WebSocketError).message.reason)
    finally
        close(server)
    end
end

@testset "HTTP.WebSockets server subprotocol negotiation" begin
    server = W.listen!("127.0.0.1", 0; subprotocols = ["chat"]) do ws
        W.send(ws, "ok")
    end
    try
        address = W.server_addr(server)
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
        address = W.server_addr(server)
        response = _raw_upgrade_response(address; origin = "http://evil.example")
        @test response.status == 403
    finally
        close(server)
    end
end

@testset "HTTP.WebSockets default origin policy enforces scheme/host/port (JLSEC-2026-614)" begin
    # Build a minimal upgrade request carrying the given Origin and Host headers.
    function _origin_request(origin::Union{Nothing,String}, host::String)
        headers = HT.Headers()
        origin === nothing || HT.setheader(headers, "Origin", origin)
        return HT.Request("GET", "/ws"; headers = headers, host = host, content_length = 0)
    end
    allowed(origin, host; secure::Bool = false) =
        W._origin_allowed_default(_origin_request(origin, host), secure)

    # No Origin header (e.g. non-browser clients): the default policy allows it.
    @test allowed(nothing, "example.com")
    @test allowed(nothing, "example.com"; secure = true)

    # Exact same-origin requests are allowed for both ws/http and wss/https.
    @test allowed("http://example.com", "example.com")
    @test allowed("https://example.com", "example.com"; secure = true)
    @test allowed("http://example.com:8080", "example.com:8080")
    @test allowed("https://example.com:8443", "example.com:8443"; secure = true)

    # Cross-port origins on the same host must be rejected even when the Host
    # header omits the port (the default-port case the previous code mishandled).
    @test !allowed("http://example.com:8080", "example.com")
    @test !allowed("https://example.com:8443", "example.com"; secure = true)
    @test !allowed("http://example.com:8080", "example.com:80")
    @test !allowed("https://example.com:8443", "example.com:443"; secure = true)

    # Cross-scheme origins on the same host/effective port must be rejected: a
    # wss server must not accept an http origin, nor a ws server an https origin.
    @test !allowed("http://example.com", "example.com"; secure = true)
    @test !allowed("http://example.com:443", "example.com"; secure = true)
    @test !allowed("https://example.com", "example.com")
    @test !allowed("https://example.com:80", "example.com")

    # Cross-host origins remain rejected.
    @test !allowed("http://evil.example", "example.com")
    @test !allowed("https://evil.example", "example.com"; secure = true)

    # Malformed Origin headers are rejected.
    @test !allowed("not a url", "example.com")
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
        address = W.server_addr(server)
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
        address = W.server_addr(server)
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
        address = W.server_addr(server)
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
        ws === nothing || HTTP.@try_ignore close(ws::W.WebSocket)
    end
end
