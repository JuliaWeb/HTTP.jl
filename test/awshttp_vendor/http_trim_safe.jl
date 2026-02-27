using AwsHTTP
using Reseau

const _RS_SUCCESS = Reseau.OP_SUCCESS

@inline function _expect_success(code::Int, what::AbstractString)::Nothing
    code == _RS_SUCCESS || error("$what failed with code $code")
    return nothing
end

@inline function _expect_true(cond::Bool, what::AbstractString)::Nothing
    cond || error(what)
    return nothing
end

function _make_h1_request(method::AbstractString, path::AbstractString, body::AbstractString = "")::AwsHTTP.HttpMessage
    msg = AwsHTTP.http_message_new_request()
    _expect_success(AwsHTTP.http_message_set_request_method(msg, method), "set request method")
    _expect_success(AwsHTTP.http_message_set_request_path(msg, path), "set request path")
    headers = AwsHTTP.http_message_get_headers(msg)
    _expect_success(AwsHTTP.http_headers_add(headers, "Host", "example.com"), "set host header")
    if !isempty(body)
        _expect_success(
            AwsHTTP.http_headers_add(headers, "Content-Length", string(length(body))),
            "set content-length header",
        )
        _expect_success(
            AwsHTTP.http_message_set_body_stream(msg, Vector{UInt8}(body)),
            "set request body",
        )
    end
    return msg
end

function _make_h1_response(status::Int, body::AbstractString = "")::AwsHTTP.HttpMessage
    msg = AwsHTTP.http_message_new_response()
    _expect_success(AwsHTTP.http_message_set_response_status(msg, status), "set response status")
    headers = AwsHTTP.http_message_get_headers(msg)
    _expect_success(AwsHTTP.http_headers_add(headers, "Content-Length", string(length(body))), "set response content-length")
    if !isempty(body)
        _expect_success(
            AwsHTTP.http_message_set_body_stream(msg, Vector{UInt8}(body)),
            "set response body",
        )
    end
    return msg
end

function _collect_h1_outgoing!(conn)::Vector{UInt8}
    out = UInt8[]
    while true
        status, chunk = AwsHTTP.h1_connection_encode_outgoing!(conn)
        _expect_success(status, "encode outgoing h1 bytes")
        isempty(chunk) && break
        append!(out, chunk)
    end
    return out
end

function run_h1_roundtrip_smoke()::Nothing
    client_conn = AwsHTTP.h1_connection_new_client()
    server_conn = AwsHTTP.h1_connection_new_server()
    request = _make_h1_request("POST", "/trim", "hello")
    response = _make_h1_response(201, "done")
    client_status = Ref{Int}(0)
    client_body = UInt8[]
    server_method = Ref("")
    server_path = Ref("")
    server_body = UInt8[]
    client_stream = AwsHTTP.h1_stream_new_request(
        client_conn,
        AwsHTTP.HttpMakeRequestOptions(
            request = request,
            on_response_body = (stream, data, user_data) -> begin
                append!(client_body, data)
                return _RS_SUCCESS
            end,
            on_complete = (stream, error_code, user_data) -> begin
                _expect_success(error_code, "client stream completion")
                client_status[] = AwsHTTP.h1_stream_get_incoming_response_status(stream)
                return nothing
            end,
        ),
    )
    client_stream === nothing && error("failed to create client h1 stream")
    _expect_success(AwsHTTP.h1_stream_activate!(client_stream), "activate client h1 stream")
    request_bytes = _collect_h1_outgoing!(client_conn)
    server_stream = AwsHTTP.h1_stream_new_request_handler(
        AwsHTTP.HttpRequestHandlerOptions(
            server_conn,
            nothing,
            (stream, header_block, headers, user_data) -> _RS_SUCCESS,
            nothing,
            (stream, data, user_data) -> begin
                append!(server_body, data)
                return _RS_SUCCESS
            end,
            (stream, user_data) -> begin
                server_method[] = AwsHTTP.http_stream_get_incoming_request_method(stream)
                server_path[] = AwsHTTP.http_stream_get_incoming_request_uri(stream)
                return nothing
            end,
            nothing,
            nothing,
        ),
    )
    _expect_success(AwsHTTP.h1_stream_activate!(server_stream), "activate server h1 stream")
    _expect_success(AwsHTTP.h1_connection_process_read_data!(server_conn, request_bytes), "server decode request")
    enc_msg = AwsHTTP.H1EncoderMessage()
    _expect_success(AwsHTTP.h1_encoder_message_init_from_response!(enc_msg, response), "init response encoder message")
    server_stream.encoder_message = enc_msg
    response_bytes = _collect_h1_outgoing!(server_conn)
    _expect_success(AwsHTTP.h1_connection_process_read_data!(client_conn, response_bytes), "client decode response")
    _expect_true(client_status[] == 201, "expected h1 response status 201")
    _expect_true(String(client_body) == "done", "expected h1 response body")
    _expect_true(server_method[] == "POST", "expected server method POST")
    _expect_true(server_path[] == "/trim", "expected server path /trim")
    _expect_true(String(server_body) == "hello", "expected server request body")
    AwsHTTP.h1_connection_destroy!(client_conn)
    AwsHTTP.h1_connection_destroy!(server_conn)
    return nothing
end

function _exchange_h2_prefaces!(client, server)::Nothing
    status_c, cp = AwsHTTP.h2_connection_get_preface(client)
    _expect_success(status_c, "client h2 preface")
    status_s, sp = AwsHTTP.h2_connection_get_preface(server)
    _expect_success(status_s, "server h2 preface")
    err1, _, _ = AwsHTTP.h2_connection_decode!(server, cp)
    _expect_true(!AwsHTTP.h2err_failed(err1), "server failed to decode client preface")
    err2, _, _ = AwsHTTP.h2_connection_decode!(client, sp)
    _expect_true(!AwsHTTP.h2err_failed(err2), "client failed to decode server preface")
    sa = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    ca = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    err3, _, _ = AwsHTTP.h2_connection_decode!(server, ca)
    _expect_true(!AwsHTTP.h2err_failed(err3), "server failed to decode settings ack")
    err4, _, _ = AwsHTTP.h2_connection_decode!(client, sa)
    _expect_true(!AwsHTTP.h2err_failed(err4), "client failed to decode settings ack")
    return nothing
end

function run_h2_smoke()::Nothing
    client = AwsHTTP.h2_connection_new(is_client = true)
    server = AwsHTTP.h2_connection_new(is_client = false)
    _exchange_h2_prefaces!(client, server)
    settings = [AwsHTTP.Http2Setting(AwsHTTP.Http2SettingsId.MAX_CONCURRENT_STREAMS, UInt32(64))]
    settings_future = AwsHTTP.h2_connection_change_settings!(client, settings)
    settings_bytes = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    err1, _, _ = AwsHTTP.h2_connection_decode!(server, settings_bytes)
    _expect_true(!AwsHTTP.h2err_failed(err1), "server failed to decode settings")
    settings_ack_bytes = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    err2, _, _ = AwsHTTP.h2_connection_decode!(client, settings_ack_bytes)
    _expect_true(!AwsHTTP.h2err_failed(err2), "client failed to decode settings ack")
    _expect_success(wait(settings_future), "h2 settings completion")
    ping_future = AwsHTTP.h2_connection_send_ping!(client, UInt8[1, 2, 3, 4, 5, 6, 7, 8])
    ping_bytes = AwsHTTP.h2_connection_get_outgoing_frames!(client)
    err3, _, _ = AwsHTTP.h2_connection_decode!(server, ping_bytes)
    _expect_true(!AwsHTTP.h2err_failed(err3), "server failed to decode ping")
    ping_ack_bytes = AwsHTTP.h2_connection_get_outgoing_frames!(server)
    err4, _, _ = AwsHTTP.h2_connection_decode!(client, ping_ack_bytes)
    _expect_true(!AwsHTTP.h2err_failed(err4), "client failed to decode ping ack")
    rtt_ns, ping_error = wait(ping_future)
    _expect_true(rtt_ns > 0, "expected ping RTT")
    _expect_success(ping_error, "h2 ping completion")
    return nothing
end

mutable struct TrimMockConnection
    is_open::Bool
    closed::Bool
    id::Int
end

AwsHTTP.http_connection_is_open(conn::TrimMockConnection) = conn.is_open

function AwsHTTP.http_connection_close(conn::TrimMockConnection)
    conn.closed = true
    conn.is_open = false
    return nothing
end

function run_manager_smoke()::Nothing
    next_id = Ref(0)
    options = AwsHTTP.HttpConnectionManagerOptions(
        max_connections = 1,
        max_pending_connection_acquisitions = 2,
        on_connection_setup = _ -> begin
            next_id[] += 1
            return TrimMockConnection(true, false, next_id[])
        end,
    )
    manager = AwsHTTP.http_connection_manager_new(options)
    first_conn, first_error = AwsHTTP.http_connection_manager_acquire_connection!(manager)
    _expect_success(first_error, "first manager acquire")
    _expect_true(first_conn !== nothing, "first manager acquire returned nothing")
    AwsHTTP.http_connection_manager_release_connection(manager, first_conn)
    second_conn, second_error = AwsHTTP.http_connection_manager_acquire_connection!(manager)
    _expect_success(second_error, "second manager acquire")
    _expect_true(second_conn !== nothing, "second manager acquire returned nothing")
    _expect_true(second_conn.id == first_conn.id, "expected manager to reuse idle connection")
    close(manager)
    _expect_true(second_conn.closed, "expected manager close to close idle connection")
    return nothing
end

function @main(args::Vector{String})::Cint
    _ = args
    run_h1_roundtrip_smoke()
    run_h2_smoke()
    run_manager_smoke()
    return 0
end

Base.Experimental.entrypoint(main, (Vector{String},))
