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

function _write_response_all!(conn, response::HT.Response)
    io = IOBuffer()
    HT.write_response!(io, response)
    write(conn, take!(io))
    return nothing
end

function _listener_address(listener)::String
    if listener isa TL.Listener
        laddr = TL.addr(listener)::NC.SocketAddrV4
        return ND.join_host_port("127.0.0.1", Int(laddr.port))
    end
    laddr = NC.addr(listener)::NC.SocketAddrV4
    return ND.join_host_port("127.0.0.1", Int(laddr.port))
end

function _ws_server(serve_one::Function; secure::Bool = false)
    listener = if secure
        TL.listen(
            "tcp",
            "127.0.0.1:0",
            TL.Config(verify_peer = false, cert_file = _TLS_CERT_PATH, key_file = _TLS_KEY_PATH),
        )
    else
        NC.listen("tcp", "127.0.0.1:0")
    end
    address = _listener_address(listener)
    task = errormonitor(Threads.@spawn begin
        try
            conn = secure ? TL.accept(listener) : NC.accept(listener)
            serve_one(conn)
        finally
            @isdefined(conn) && _close_quiet!(conn)
        end
    end)
    return listener, task, address
end

function _wait_task_ok(task::Task)
    try
        wait(task)
    catch err
        err isa Reseau.IOPoll.NetClosingError && return nothing
        err isa EOFError && return nothing
        rethrow(err)
    end
    return nothing
end

function _close_quiet!(x::Task)
    HTTP.@try_ignore _wait_task_ok(x)
    return nothing
end

function _close_quiet!(x)
    x === nothing && return nothing
    HTTP.@try_ignore begin
        if x isa TL.Listener
            TL.close(x)
        elseif x isa NC.Listener
            NC.close(x)
        elseif x isa TL.Conn
            TL.close(x)
        elseif x isa NC.Conn
            NC.close(x)
        end
    end
    return nothing
end

function _read_ws_request(conn)
    reader = HT._ConnReader(conn)
    request = HT.read_request(reader)
    return request
end

function _accept_ws_request!(conn, request::HT.Request; subprotocol::Union{Nothing, String} = nothing)
    headers = HT.Headers()
    HT.setheader(headers, "Upgrade", "websocket")
    HT.setheader(headers, "Connection", "Upgrade")
    key = HT.WebSockets.ws_get_request_sec_websocket_key(request)
    key === nothing && error("missing websocket key")
    HT.setheader(headers, "Sec-WebSocket-Accept", HT.WebSockets.ws_compute_accept_key(key))
    subprotocol === nothing || HT.setheader(headers, "Sec-WebSocket-Protocol", subprotocol)
    _write_response_all!(conn, HT.Response(101, HT.EmptyBody(); headers = headers, content_length = 0))
    return nothing
end

function _write_ws_frame!(conn, opcode::UInt8, payload::AbstractVector{UInt8}; fin::Bool = true, masked::Bool = false)
    frame = HT.WebSockets.WsFrame(opcode = opcode, payload = payload, fin = fin, masked = masked, masking_key = (0x01, 0x02, 0x03, 0x04))
    encoded = HT.WebSockets.ws_encode_frame(frame)
    write(conn, encoded, length(encoded))
    return nothing
end

function _read_ws_frames(conn, ws::W.Conn)
    buf = readavailable(conn)
    isempty(buf) && return HT.WebSockets.WsFrame{Vector{UInt8}}[]
    return HT.WebSockets.ws_on_incoming_data!(ws, buf)
end

@testset "HTTP.WebSockets client open over ws" begin
    listener = nothing
    task = nothing
    ws = nothing
    try
        listener, task, address = _ws_server() do conn
            request = _read_ws_request(conn)
            @test W.isupgrade(request)
            _accept_ws_request!(conn, request)
            _write_ws_frame!(conn, UInt8(HT.WebSockets.WsOpcode.TEXT), Vector{UInt8}("hello"))
            server_ws = W.Conn(is_client = false)
            frames = _read_ws_frames(conn, server_ws)
            @test length(frames) == 1
            @test frames[1].opcode == UInt8(HT.WebSockets.WsOpcode.TEXT)
            @test frames[1].payload == Vector{UInt8}("pong")
            HT.WebSockets.ws_close!(server_ws; status_code = UInt16(1000), reason = UInt8[])
            write(conn, HT.WebSockets.ws_get_outgoing_data!(server_ws))
        end
        ws = W.open(
            "ws://$address/chat";
            request_timeout = 0.25,
            response_header_timeout = 0.25,
            read_idle_timeout = 0.25,
            write_idle_timeout = 0.25,
        )
        @test HT.get_request_context(ws.handshake_request).deadline_ns != 0
        timeout_config = HT.get_request_context(ws.handshake_request).timeout_config
        @test timeout_config !== nothing
        @test (timeout_config::HT._RequestTimeoutConfig).response_header_timeout_ns == 250_000_000
        @test timeout_config.read_idle_timeout_ns == 250_000_000
        @test timeout_config.write_idle_timeout_ns == 250_000_000
        @test W.receive(ws) == "hello"
        W.send(ws, "pong")
        err = try
            W.receive(ws)
            nothing
        catch ex
            ex
        end
        @test err isa W.WebSocketError
        @test W.isok(err)
    finally
        ws === nothing || HTTP.@try_ignore close(ws)
        _close_quiet!(listener)
        _close_quiet!(task)
    end
end

@testset "HTTP.WebSockets client open over wss" begin
    listener = nothing
    task = nothing
    ws = nothing
    try
        listener, task, address = _ws_server(; secure = true) do conn
            request = _read_ws_request(conn)
            _accept_ws_request!(conn, request)
            _write_ws_frame!(conn, UInt8(HT.WebSockets.WsOpcode.TEXT), Vector{UInt8}("secure"))
            server_ws = W.Conn(is_client = false)
            HT.WebSockets.ws_close!(server_ws; status_code = UInt16(1000), reason = UInt8[])
            write(conn, HT.WebSockets.ws_get_outgoing_data!(server_ws))
        end
        ws = W.open("wss://$address/secure"; require_ssl_verification = false)
        @test W.receive(ws) == "secure"
    finally
        ws === nothing || HTTP.@try_ignore close(ws)
        _close_quiet!(listener)
        _close_quiet!(task)
    end
end

@testset "HTTP.WebSockets client subprotocol negotiation" begin
    listener = nothing
    task = nothing
    ws = nothing
    try
        listener, task, address = _ws_server() do conn
            request = _read_ws_request(conn)
            @test HT.WebSockets.ws_select_subprotocol(request, ["chat", "superchat"]) == "chat"
            _accept_ws_request!(conn, request; subprotocol = "chat")
            server_ws = W.Conn(is_client = false)
            HT.WebSockets.ws_close!(server_ws; status_code = UInt16(1000), reason = UInt8[])
            write(conn, HT.WebSockets.ws_get_outgoing_data!(server_ws))
        end
        ws = W.open("ws://$address/subproto"; subprotocols = ["chat", "superchat"])
        @test ws.subprotocol == "chat"
    finally
        ws === nothing || HTTP.@try_ignore close(ws)
        _close_quiet!(listener)
        _close_quiet!(task)
    end
end

@testset "HTTP.WebSockets client rejects unexpected subprotocols" begin
    for (requested, returned, expected_reason) in (
        (String[], "chat", "unexpected websocket subprotocol in response"),
        (["superchat"], "chat", "unrequested websocket subprotocol in response"),
    )
        listener = nothing
        task = nothing
        try
            listener, task, address = _ws_server() do conn
                request = _read_ws_request(conn)
                _accept_ws_request!(conn, request; subprotocol = returned)
            end
            err = try
                W.open("ws://$address/subproto"; subprotocols = requested)
                nothing
            catch ex
                ex
            end
            @test err isa W.WebSocketError
            @test (err::W.WebSocketError).message.code == 1002
            @test err.message.reason == expected_reason
        finally
            _close_quiet!(listener)
            _close_quiet!(task)
        end
    end
end

@testset "HTTP.WebSockets client redirects and cookies" begin
    redirect_listener = nothing
    redirect_task = nothing
    target_listener = nothing
    target_task = nothing
    ws = nothing
    try
        target_listener, target_task, target_address = _ws_server() do conn
            request = _read_ws_request(conn)
            @test HT.header(request.headers, "Cookie") == "session=abc"
            _accept_ws_request!(conn, request)
            server_ws = W.Conn(is_client = false)
            HT.WebSockets.ws_close!(server_ws; status_code = UInt16(1000), reason = UInt8[])
            write(conn, HT.WebSockets.ws_get_outgoing_data!(server_ws))
        end
        redirect_listener, redirect_task, redirect_address = _ws_server() do conn
            request = _read_ws_request(conn)
            headers = HT.Headers()
            HT.setheader(headers, "Location", "ws://$target_address/final")
            HT.setheader(headers, "Set-Cookie", "session=abc; Path=/")
            _write_response_all!(conn, HT.Response(302, HT.EmptyBody(); headers = headers, content_length = 0))
        end
        ws = W.open("ws://$redirect_address/start"; cookiejar = HT.CookieJar())
        @test ws.handshake_response.status == 101
    finally
        ws === nothing || HTTP.@try_ignore close(ws)
        _close_quiet!(redirect_listener)
        _close_quiet!(redirect_task)
        _close_quiet!(target_listener)
        _close_quiet!(target_task)
    end
end

@testset "HTTP.WebSockets client handshake response_header_timeout" begin
    listener = nothing
    task = nothing
    try
        listener, task, address = _ws_server() do conn
            request = _read_ws_request(conn)
            @test request.target == "/slow"
            sleep(0.20)
        end
        err = try
            W.open("ws://$address/slow"; response_header_timeout = 0.05)
            nothing
        catch ex
            ex
        end
        @test err isa HTTP.TimeoutError
    finally
        _close_quiet!(listener)
        _close_quiet!(task)
    end
end
