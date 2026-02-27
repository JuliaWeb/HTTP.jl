using HTTP

function run_request_response_smoke()::Nothing
    req = HTTP.Request("GET", "/trim"; context=Dict{Symbol, Any}(:trim => true))
    HTTP.setheader(req, "host" => "localhost")
    HTTP.setheader(req, "accept" => "application/json")
    HTTP.issafe(req) || error("expected GET request to be safe")

    resp = HTTP.Response(200, ["content-type" => "application/json"], nothing)
    HTTP.iserror(resp) && error("expected 200 response to be non-error")
    HTTP.getheader(resp, "content-type") == "application/json" || error("unexpected response content-type")

    req.path = "/trim/updated"
    req.path == "/trim/updated" || error("request path mutation failed")
    HTTP.isidempotent(req) || error("GET request should be idempotent")

    redirected = HTTP.Response(302, ["location" => "/next"], nothing)
    HTTP.isredirect(redirected) || error("expected redirect response")
    return nothing
end

function run_websocket_codec_smoke()::Nothing
    client = HTTP.AwsHTTP.WebSocket(; is_client=true)
    server = HTTP.AwsHTTP.WebSocket(; is_client=false)

    HTTP.AwsHTTP.ws_send_text!(client, UInt8[0x68, 0x69])
    client_bytes = HTTP.AwsHTTP.ws_get_outgoing_data!(client)
    isempty(client_bytes) && error("expected client websocket bytes")
    status, frames = HTTP.AwsHTTP.ws_on_incoming_data!(server, client_bytes)
    status == HTTP.AwsHTTP.OP_SUCCESS || error("server decode failed")
    isempty(frames) && error("expected server decoded frame")

    HTTP.AwsHTTP.ws_send_text!(server, UInt8[0x6f, 0x6b])
    server_bytes = HTTP.AwsHTTP.ws_get_outgoing_data!(server)
    isempty(server_bytes) && error("expected server websocket bytes")
    status, frames = HTTP.AwsHTTP.ws_on_incoming_data!(client, server_bytes)
    status == HTTP.AwsHTTP.OP_SUCCESS || error("client decode failed")
    isempty(frames) && error("expected client decoded frame")
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_request_response_smoke()
    run_websocket_codec_smoke()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
