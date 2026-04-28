include("trim_workload_common.jl")

const W = HT.WebSockets

function run_http_trim_websocket()::Nothing
    # Desired future coverage once package-local background Tasks are trim-safe:
    #
    # server = W.listen!("127.0.0.1", 0) do ws
    #     message = W.receive(ws)
    #     W.send(ws, message * "!")
    # end
    # ws = W.open("ws://$(W.server_addr(server))/echo")
    # W.send(ws, "ping")
    # W.receive(ws) == "ping!" || error("unexpected websocket echo payload")

    payload = collect(codeunits("ping"))
    frame = HT.WebSockets.WsFrame(
        opcode = UInt8(HT.WebSockets.WsOpcode.TEXT),
        payload = payload,
        fin = true,
        masked = true,
        masking_key = (0x01, 0x02, 0x03, 0x04),
    )
    encoded = HT.WebSockets.ws_encode_frame(frame)
    isempty(encoded) && error("expected websocket frame bytes")

    decoder = HT.WebSockets.ws_decoder_new()
    decoded = HT.WebSockets.ws_decoder_process!(decoder, encoded)
    length(decoded) == 1 || error("expected one decoded websocket frame")
    rf = decoded[1]
    rf.fin || error("expected final websocket frame")
    rf.opcode == UInt8(HT.WebSockets.WsOpcode.TEXT) || error("unexpected websocket opcode")
    String(rf.payload) == "ping" || error("unexpected websocket payload")
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_http_trim_websocket()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
