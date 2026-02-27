# HTTP/1.1 Connection - Channel handler integrating encoder + decoder with streams
# Port of aws-c-http/source/h1_connection.c, h1_connection.h

using Reseau: ReseauError

# ─── Read state ───

@enumx H1ConnectionReadState::UInt8 begin
    OPEN = 0
    SHUTTING_DOWN = 1
    SHUT_DOWN_COMPLETE = 2
end

# ─── H1 Connection ───

mutable struct H1Connection <: HttpConnection
    # ── Connection identity ──
    http_version::HttpVersion.T
    is_client::Bool
    on_incoming_request::Union{Nothing, ConnectionIncomingRequestCallback}
    on_h2c_upgrade::Union{Nothing, ConnectionH2CUpgradeCallback}
    server_configured::Bool
    # ── h2c upgrade (client + server probe) ──
    h2c_enabled::Bool
    h2c_settings_header_value::Union{Vector{UInt8}, Nothing}

    # ── Stream management ──
    stream_list::Vector{H1Stream}
    # late-init: starts nothing, mutated during stream lifecycle
    outgoing_stream::Union{H1Stream, Nothing}
    incoming_stream::Union{H1Stream, Nothing}
    next_stream_id::UInt32  # starts at 1 (client) or 2 (server), increments by 2

    # ── Encoder / Decoder ──
    encoder::H1Encoder
    decoder::H1Decoder

    # ── Read state ──
    connection_window::Csize_t
    read_buffer_capacity::Csize_t  # 0 = unlimited
    read_state::H1ConnectionReadState.T

    # ── Flow control ──
    initial_stream_window_size::UInt64
    manual_window_management::Bool

    # ── State flags ──
    is_open::Bool
    is_writing_stopped::Bool
    has_switched_protocols::Bool
    new_stream_error_code::Int

    # ── Shutdown ──
    pending_shutdown_error_code::Int

    # ── Client/Server-specific ──
    response_first_byte_timeout_ms::UInt64
    on_shutdown::Union{Nothing, ConnectionShutdownCallback}  # (connection, error_code) -> Nothing

    # ── Channel integration ──
    # late-init: set by channel_slot_set_handler!
    slot::Union{Sockets.ChannelSlot, Nothing}
    remote_endpoint::String  # host:port or "" if unknown
end

# Set the channel slot when installed in a pipeline.
function Sockets.setchannelslot!(handler::H1Connection, slot::Sockets.ChannelSlot)::Nothing
    handler.slot = slot
    return nothing
end

# ─── h2c upgrade helpers ───

function _h1_request_has_body(headers::HttpHeaders)::Bool
    content_length = http_headers_get(headers, "content-length")
    if content_length !== nothing
        parsed = tryparse(UInt64, strip(content_length))
        parsed === nothing && return true
        parsed > 0 && return true
    end
    transfer_encoding = http_headers_get(headers, "transfer-encoding")
    transfer_encoding !== nothing && return true
    return false
end

function _h1_request_has_h2c_upgrade_tokens(headers::HttpHeaders)::Bool
    has_upgrade = false
    has_http2_settings = false
    has_h2c = false
    connection_value = http_headers_get_all(headers, "connection")
    if connection_value !== nothing
        has_upgrade = _header_value_has_token(connection_value, "upgrade")
        has_http2_settings = _header_value_has_token(connection_value, "http2-settings")
    end
    upgrade_value = http_headers_get_all(headers, "upgrade")
    if upgrade_value !== nothing
        has_h2c = _header_value_has_token(upgrade_value, "h2c")
    end
    return has_upgrade && has_http2_settings && has_h2c
end

function _h1_decode_http2_settings_header(headers::HttpHeaders)::Vector{Http2Setting}
    settings_value = http_headers_get(headers, "http2-settings")
    settings_value === nothing && Reseau.throw_error(Reseau.ERROR_INVALID_STATE)
    status, settings = h2_decode_http2_settings_header(codeunits(settings_value))
    status != OP_SUCCESS && Reseau.throw_error(Reseau.ERROR_INVALID_STATE)
    return settings
end

function _h1_deliver_buffered_headers!(stream::H1Stream)::Int
    if stream.h2c.request_message !== nothing && stream.on_incoming_headers !== nothing
        headers = http_message_get_headers(stream.h2c.request_message)
        count = http_headers_count(headers)
        for i in 0:(count - 1)
            h = http_headers_get_index(headers, i)
            h === nothing && return OP_ERR
            err = stream.on_incoming_headers(stream, HttpHeaderBlock.MAIN, [h])
            err != OP_SUCCESS && return OP_ERR
        end
    end
    stream.is_incoming_head_done = true
    stream.h2c.headers_buffered = false
    if stream.on_incoming_header_block_done !== nothing
        err = stream.on_incoming_header_block_done(stream, HttpHeaderBlock.MAIN)
        err != OP_SUCCESS && return OP_ERR
    end
    if stream.h2c.request_message !== nothing
        stream.h2c.request_message = nothing
    end
    return OP_SUCCESS
end

function _h1_stream_invoke_h2c_upgrade_callback(stream::H1Stream, h2_connection, h2_stream, error_code::Int)::Nothing
    cb = stream.h2c.on_h2c_upgrade
    cb === nothing && return nothing
    stream.h2c.upgrade_callback_invoked && return nothing
    stream.h2c.upgrade_callback_invoked = true
    cb(stream.owning_connection, h2_connection, h2_stream, error_code)
    return nothing
end

function _h1_fail_h2c_upgrade(stream::H1Stream, error_code::Int)::Int
    code = error_code != 0 ? error_code : ERROR_HTTP_PROTOCOL_SWITCH_FAILURE
    raise_error(code)
    _h1_stream_invoke_h2c_upgrade_callback(stream, nothing, nothing, code)
    return OP_ERR
end

function _h1_create_h2c_probe_stream(conn::H1Connection)::Union{H1Stream, Nothing}
    stream = h1_stream_new_request_handler(conn)
    stream === nothing && return nothing
    stream.h2c.is_h2c_probe = true
    if stream.api_state == H1StreamApiState.INIT
        status = h1_stream_activate!(stream)
        status != OP_SUCCESS && return nothing
    end
    conn.incoming_stream = stream
    return stream
end

function _h1_promote_h2c_probe_stream(conn::H1Connection, probe::H1Stream)::Union{H1Stream, Nothing}
    stream = conn.on_incoming_request(conn)
    stream === nothing && return (raise_error(ERROR_HTTP_REACTION_REQUIRED); nothing)
    stream isa H1Stream || return (raise_error(ERROR_INVALID_ARGUMENT); nothing)
    if stream.api_state == H1StreamApiState.INIT
        status = h1_stream_activate!(stream)
        status != OP_SUCCESS && return nothing
    end
    stream.request_method = probe.request_method
    stream.request_method_str = probe.request_method_str
    stream.request_path = probe.request_path
    stream.h2c.request_message = probe.h2c.request_message
    stream.h2c.headers_buffered = probe.h2c.headers_buffered
    probe.h2c.request_message = nothing
    probe.h2c.headers_buffered = false
    conn.incoming_stream = stream
    idx = findfirst(==(probe), conn.stream_list)
    idx !== nothing && deleteat!(conn.stream_list, idx)
    if _h1_deliver_buffered_headers!(stream) != OP_SUCCESS
        _finish_stream!(conn, stream)
        return nothing
    end
    return stream
end

function _h1_send_h2c_upgrade_response(stream::H1Stream)::Int
    response = http_message_new_response()
    response === nothing && return OP_ERR
    if http_message_set_response_status(response, HTTP_STATUS_CODE_101_SWITCHING_PROTOCOLS) != OP_SUCCESS
        return OP_ERR
    end
    if http_message_add_header(response, HttpHeader("Connection", "Upgrade")) != OP_SUCCESS
        return OP_ERR
    end
    if http_message_add_header(response, HttpHeader("Upgrade", "h2c")) != OP_SUCCESS
        return OP_ERR
    end
    return h1_stream_send_response!(stream, response)
end

function _h1_connection_build_h2c_settings_header!(conn::H1Connection)::Int
    settings = Http2Setting[]
    if conn.manual_window_management && conn.initial_stream_window_size != UInt64(H2_INIT_WINDOW_SIZE)
        if conn.initial_stream_window_size > UInt64(H2_WINDOW_UPDATE_MAX)
            return raise_error(ERROR_INVALID_ARGUMENT)
        end
        push!(settings, Http2Setting(Http2SettingsId.INITIAL_WINDOW_SIZE, UInt32(conn.initial_stream_window_size)))
    end
    status, encoded = h2_encode_http2_settings_header(settings)
    status != OP_SUCCESS && return OP_ERR
    conn.h2c_settings_header_value = encoded
    return OP_SUCCESS
end

function _h1_connection_get_h2c_settings_header(conn::H1Connection)::Vector{UInt8}
    if conn.h2c_settings_header_value === nothing
        status = _h1_connection_build_h2c_settings_header!(conn)
        status != OP_SUCCESS && Reseau.throw_error(Reseau.ERROR_INVALID_STATE)
    end
    conn.h2c_settings_header_value === nothing && Reseau.throw_error(ERROR_INVALID_STATE)
    return conn.h2c_settings_header_value
end

function _http1_switch_protocols!(conn::H1Connection)::Int
    if length(conn.stream_list) > 1
        return raise_error(ERROR_INVALID_STATE)
    end
    conn.has_switched_protocols = true
    conn.new_stream_error_code = ERROR_HTTP_SWITCHED_PROTOCOLS
    h1_decoder_stop_processing!(conn.decoder)
    return OP_SUCCESS
end

function _h1_create_h2_connection_for_upgrade(conn::H1Connection, is_server::Bool)
    conn.slot === nothing && return nothing
    channel = conn.slot.channel
    channel === nothing && return nothing
    initial_window = conn.manual_window_management ?
        UInt32(min(conn.initial_stream_window_size, UInt64(typemax(UInt32)))) :
        UInt32(H2_INIT_WINDOW_SIZE)
    h2_conn = h2_connection_new(
        is_client = !is_server,
        manual_window_management = conn.manual_window_management,
        initial_window_size = initial_window,
        on_shutdown = conn.on_shutdown,
    )
    h2_conn.remote_endpoint = conn.remote_endpoint
    new_slot = Sockets.channel_slot_new!(channel)
    Sockets.channel_slot_insert_right!(conn.slot, new_slot)
    Sockets.channel_slot_set_handler!(new_slot, h2_conn)
    if is_server
        if http_connection_configure_server(
            h2_conn;
            on_incoming_request = conn.on_incoming_request,
            on_h2c_upgrade = conn.on_h2c_upgrade,
            on_shutdown = conn.on_shutdown,
        ) != OP_SUCCESS
            http_connection_close(h2_conn)
            return nothing
        end
    end
    return h2_conn
end

function _h1_finish_client_h2c_upgrade!(conn::H1Connection, stream::H1Stream)::Int
    stream.h2c.original_request === nothing && return raise_error(ERROR_INVALID_STATE)
    if _http1_switch_protocols!(conn) != OP_SUCCESS
        return _h1_fail_h2c_upgrade(stream, Reseau.last_error())
    end
    h2_conn = _h1_create_h2_connection_for_upgrade(conn, false)
    h2_conn === nothing && return _h1_fail_h2c_upgrade(stream, Reseau.last_error())
    h2_stream = h2_stream_new_request(
        h2_conn;
        request = stream.h2c.original_request,
        on_response_headers = stream.on_incoming_headers,
        on_response_header_block_done = stream.on_incoming_header_block_done,
        on_response_body = stream.on_incoming_body,
        on_metrics = stream.on_metrics,
        on_complete = stream.on_complete,
        on_destroy = stream.on_destroy,
    )
    if h2_stream === nothing
        http_connection_close(h2_conn)
        return _h1_fail_h2c_upgrade(stream, Reseau.last_error())
    end
    h2_stream.outgoing_message = nothing
    h2_stream.id = UInt32(1)
    h2_stream.metrics = HttpStreamMetrics(
        h2_stream.metrics.send_start_timestamp_ns,
        h2_stream.metrics.send_end_timestamp_ns,
        h2_stream.metrics.sending_duration_ns,
        h2_stream.metrics.receive_start_timestamp_ns,
        h2_stream.metrics.receive_end_timestamp_ns,
        h2_stream.metrics.receiving_duration_ns,
        UInt32(1),
    )
    h2_stream.state = H2StreamState.HALF_CLOSED_LOCAL
    h2_stream.api_state = H2StreamApiState.ACTIVE
    h2_stream.manual_write = false
    h2_stream.manual_write_ended = true
    h2_stream.end_stream_sent = true
    h2_stream_init_window_sizes!(h2_stream, h2_conn)
    h2_conn.active_streams[UInt32(1)] = h2_stream
    h2_conn.next_stream_id = UInt32(3)
    stream.on_incoming_headers = nothing
    stream.on_incoming_header_block_done = nothing
    stream.on_incoming_body = nothing
    stream.on_metrics = nothing
    stream.on_complete = nothing
    stream.on_destroy = nothing
    _h1_stream_invoke_h2c_upgrade_callback(stream, h2_conn, h2_stream, 0)
    _finish_stream!(conn, stream)
    return OP_SUCCESS
end

function _h1_finish_server_h2c_upgrade!(conn::H1Connection, stream::H1Stream)::Int
    stream.h2c.request_message === nothing && return raise_error(ERROR_INVALID_STATE)
    if _http1_switch_protocols!(conn) != OP_SUCCESS
        return OP_ERR
    end
    h2_conn = _h1_create_h2_connection_for_upgrade(conn, true)
    h2_conn === nothing && return OP_ERR
    if stream.h2c.upgrade_settings !== nothing && !isempty(stream.h2c.upgrade_settings)
        h2_connection_apply_remote_settings!(h2_conn, stream.h2c.upgrade_settings) != OP_SUCCESS && return OP_ERR
    end
    request_stream = h2_conn.on_incoming_request === nothing ? nothing : h2_conn.on_incoming_request(h2_conn)
    request_stream isa H2Stream || return raise_error(ERROR_HTTP_PROTOCOL_SWITCH_FAILURE)
    request_stream.id = UInt32(1)
    request_stream.metrics = HttpStreamMetrics(
        request_stream.metrics.send_start_timestamp_ns,
        request_stream.metrics.send_end_timestamp_ns,
        request_stream.metrics.sending_duration_ns,
        request_stream.metrics.receive_start_timestamp_ns,
        request_stream.metrics.receive_end_timestamp_ns,
        request_stream.metrics.receiving_duration_ns,
        UInt32(1),
    )
    h2_stream_init_window_sizes!(request_stream, h2_conn)
    h2_conn.active_streams[UInt32(1)] = request_stream
    h2_conn.latest_peer_stream_id = UInt32(1)
    h2_message = http2_message_new_from_http1_with_scheme(stream.h2c.request_message, "http")
    h2_message === nothing && return OP_ERR
    headers = http_message_get_headers(h2_message)
    header_count = http_headers_count(headers)
    filtered = HttpHeader[]
    for i in 0:(header_count - 1)
        h = http_headers_get_index(headers, i)
        h === nothing && return OP_ERR
        lower_name = lowercase(h.name)
        if lower_name == "connection" || lower_name == "http2-settings" || lower_name == "upgrade"
            continue
        end
        push!(filtered, h)
    end
    h2_err = h2_stream_on_headers_begin!(request_stream)
    h2err_failed(h2_err) && return OP_ERR
    h2_err = h2_stream_on_headers!(request_stream, filtered, HttpHeaderBlock.MAIN, true)
    h2err_failed(h2_err) && return OP_ERR
    h2_err = h2_stream_on_headers_end!(request_stream, HttpHeaderBlock.MAIN, true)
    h2err_failed(h2_err) && return OP_ERR
    stream.h2c.upgrade_settings = nothing
    stream.h2c.request_message = nothing
    return OP_SUCCESS
end

# ─── Decoder callbacks (wired to the H1 decoder) ───

function _conn_decoder_on_request(method_enum, method_str, uri, conn)::Int
    stream = conn.incoming_stream
    stream === nothing && return OP_ERR
    stream.request_method = method_enum
    stream.request_method_str = method_str
    stream.request_path = uri
    if !stream.is_client && conn.h2c_enabled
        stream.h2c.headers_buffered = true
        stream.h2c.request_message = http_message_new_request()
        stream.h2c.request_message === nothing && return OP_ERR
        if http_message_set_request_method(stream.h2c.request_message, method_str) != OP_SUCCESS
            stream.h2c.request_message = nothing
            return OP_ERR
        end
        if http_message_set_request_path(stream.h2c.request_message, uri) != OP_SUCCESS
            stream.h2c.request_message = nothing
            return OP_ERR
        end
    end
    return OP_SUCCESS
end

function _conn_decoder_on_response(status_code, conn)::Int
    stream = conn.incoming_stream
    stream === nothing && return OP_ERR
    stream.response_status = status_code
    if stream.is_client
        ignore_body = h1_decoder_get_body_headers_ignored(conn.decoder) || (stream.request_method == HttpMethod.HEAD)
        h1_decoder_set_body_headers_ignored!(conn.decoder, ignore_body)
    end
    # Record receive-start timestamp on first response line (if not yet set)
    if stream.metrics.receive_start_timestamp_ns < 0
        stream.metrics = HttpStreamMetrics(
            stream.metrics.send_start_timestamp_ns,
            stream.metrics.send_end_timestamp_ns,
            stream.metrics.sending_duration_ns,
            Reseau.monotonic_time_ns() % Int64,
            stream.metrics.receive_end_timestamp_ns,
            stream.metrics.receiving_duration_ns,
            stream.metrics.stream_id,
        )
        _cancel_response_first_byte_timeout!(conn, stream)
    end
    return OP_SUCCESS
end

function _conn_decoder_on_header(header::H1DecodedHeader, conn)::Int
    stream = conn.incoming_stream
    stream === nothing && return OP_ERR

    # Check for "Connection: close"
    if header.name == HttpHeaderName.CONNECTION
        if lowercase(header.value_data) == "close"
            stream.is_final_stream = true
        end
    end
    header_block = h1_decoder_get_header_block(conn.decoder)
    if stream.is_client && stream.h2c.is_upgrade_request && header_block == HttpHeaderBlock.INFORMATIONAL
        if header.name == HttpHeaderName.UPGRADE
            if _header_value_has_token(header.value_data, "h2c")
                stream.h2c.response_upgrade_h2c = true
            end
        elseif header.name == HttpHeaderName.CONNECTION
            if _header_value_has_token(header.value_data, "upgrade")
                stream.h2c.response_connection_upgrade = true
            end
        end
    end
    if stream.is_client && stream.h2c.is_upgrade_request &&
       header_block == HttpHeaderBlock.MAIN &&
       stream.response_status != HTTP_STATUS_CODE_101_SWITCHING_PROTOCOLS
        return _h1_fail_h2c_upgrade(stream, ERROR_HTTP_PROTOCOL_SWITCH_FAILURE)
    end
    if stream.is_client && stream.h2c.is_upgrade_request && header_block == HttpHeaderBlock.INFORMATIONAL
        return OP_SUCCESS
    end
    if !stream.is_client && stream.h2c.headers_buffered
        stream.h2c.request_message === nothing && return OP_ERR
        if http_message_add_header(stream.h2c.request_message, HttpHeader(header.name_data, header.value_data)) != OP_SUCCESS
            return OP_ERR
        end
        return OP_SUCCESS
    end

    # Forward to stream callback
    if stream.on_incoming_headers !== nothing
        h = HttpHeader(header.name_data, header.value_data)
        err = stream.on_incoming_headers(stream, header_block, [h])
        err != OP_SUCCESS && return OP_ERR
    end

    return OP_SUCCESS
end

function _conn_mark_head_done!(conn::H1Connection, stream::H1Stream)::Int
    header_block = h1_decoder_get_header_block(conn.decoder)
    if header_block == HttpHeaderBlock.INFORMATIONAL
        if stream.is_client && stream.response_status == HTTP_STATUS_CODE_101_SWITCHING_PROTOCOLS
            if stream.h2c.is_upgrade_request
                if !stream.h2c.response_upgrade_h2c || !stream.h2c.response_connection_upgrade
                    return _h1_fail_h2c_upgrade(stream, ERROR_HTTP_PROTOCOL_SWITCH_FAILURE)
                end
                return _h1_finish_client_h2c_upgrade!(conn, stream)
            end
            if _http1_switch_protocols!(conn) != OP_SUCCESS
                return OP_ERR
            end
        end
        if stream.on_incoming_header_block_done !== nothing
            err = stream.on_incoming_header_block_done(stream, header_block)
            err != OP_SUCCESS && return OP_ERR
        end
        return OP_SUCCESS
    end
    stream.is_incoming_head_done && return OP_SUCCESS
    if !stream.is_client && conn.h2c_enabled && stream.h2c.is_h2c_probe
        stream.h2c.request_message === nothing && return OP_ERR
        headers = http_message_get_headers(stream.h2c.request_message)
        has_upgrade = _h1_request_has_h2c_upgrade_tokens(headers)
        has_body = _h1_request_has_body(headers)
        if !has_upgrade || has_body
            promoted = _h1_promote_h2c_probe_stream(conn, stream)
            promoted === nothing && return OP_ERR
            return OP_SUCCESS
        end
        if length(conn.stream_list) > 1
            promoted = _h1_promote_h2c_probe_stream(conn, stream)
            promoted === nothing && return OP_ERR
            return OP_SUCCESS
        end
        local settings
        try
            settings = _h1_decode_http2_settings_header(headers)
        catch
            promoted = _h1_promote_h2c_probe_stream(conn, stream)
            promoted === nothing && return OP_ERR
            return OP_SUCCESS
        end
        stream.h2c.upgrade_settings = settings
        accept = conn.on_h2c_upgrade !== nothing && conn.on_h2c_upgrade(conn, stream.h2c.request_message)
        if !accept
            promoted = _h1_promote_h2c_probe_stream(conn, stream)
            promoted === nothing && return OP_ERR
            return OP_SUCCESS
        end
        if _h1_send_h2c_upgrade_response(stream) != OP_SUCCESS
            return OP_ERR
        end
        stream.h2c.switch_on_outgoing_done = true
        stream.is_incoming_head_done = true
        return OP_SUCCESS
    end
    if stream.is_client && stream.h2c.is_upgrade_request &&
       stream.response_status != HTTP_STATUS_CODE_101_SWITCHING_PROTOCOLS
        return _h1_fail_h2c_upgrade(stream, ERROR_HTTP_PROTOCOL_SWITCH_FAILURE)
    end
    stream.is_incoming_head_done = true
    if stream.on_incoming_header_block_done !== nothing
        err = stream.on_incoming_header_block_done(stream, header_block)
        err != OP_SUCCESS && return OP_ERR
    end
    return OP_SUCCESS
end

function _conn_decoder_on_body(data::AbstractVector{UInt8}, finished::Bool, conn)::Int
    stream = conn.incoming_stream
    stream === nothing && return OP_ERR

    # Record receive-start timestamp on first body data
    if stream.metrics.receive_start_timestamp_ns < 0
        stream.metrics = HttpStreamMetrics(
            stream.metrics.send_start_timestamp_ns,
            stream.metrics.send_end_timestamp_ns,
            stream.metrics.sending_duration_ns,
            Reseau.monotonic_time_ns() % Int64,
            stream.metrics.receive_end_timestamp_ns,
            stream.metrics.receiving_duration_ns,
            stream.metrics.stream_id,
        )
        _cancel_response_first_byte_timeout!(conn, stream)
    end

    err = _conn_mark_head_done!(conn, stream)
    err != OP_SUCCESS && return OP_ERR
    stream = conn.incoming_stream
    stream === nothing && return raise_error(ERROR_INVALID_STATE)

    # Flow control: decrement stream window
    data_len = UInt64(length(data))
    if conn.manual_window_management && data_len > 0
        if data_len > stream.stream_window
            return raise_error(ERROR_HTTP_STREAM_WINDOW_EXCEEDED)
        end
        stream.stream_window -= data_len
    end

    # Forward body data to stream
    if !isempty(data) && stream.on_incoming_body !== nothing
        err = stream.on_incoming_body(stream, data)
        err != OP_SUCCESS && return OP_ERR
    end

    return OP_SUCCESS
end

function _conn_decoder_on_done(conn)::Int
    stream = conn.incoming_stream
    stream === nothing && return OP_ERR

    # Check if this was an informational (1xx) response.
    # 101 Switching Protocols is 1xx but is a final response — complete normally.
    block = h1_decoder_get_header_block(conn.decoder)
    if block == HttpHeaderBlock.INFORMATIONAL &&
       stream.response_status != HTTP_STATUS_CODE_101_SWITCHING_PROTOCOLS
        err = _conn_mark_head_done!(conn, stream)
        err != OP_SUCCESS && return OP_ERR
        return OP_SUCCESS
    end

    err = _conn_mark_head_done!(conn, stream)
    err != OP_SUCCESS && return OP_ERR
    if stream.api_state == H1StreamApiState.COMPLETE || conn.incoming_stream !== stream
        return OP_SUCCESS
    end

    stream.is_incoming_message_done = true

    # Record receive-end timestamp and receiving duration
    now = Reseau.monotonic_time_ns() % Int64
    recv_start = stream.metrics.receive_start_timestamp_ns
    recv_dur = recv_start >= 0 ? (now - recv_start) : Int64(-1)
    stream.metrics = HttpStreamMetrics(
        stream.metrics.send_start_timestamp_ns,
        stream.metrics.send_end_timestamp_ns,
        stream.metrics.sending_duration_ns,
        recv_start, now, recv_dur,
        stream.id,
    )

    # If server: on_request_done fires
    if !stream.is_client && stream.on_request_done !== nothing
        stream.on_request_done(stream)
    end

    # Try to complete the stream
    _try_complete_stream!(conn, stream)

    # Advance incoming pointer to next stream
    _advance_incoming_stream!(conn)

    return OP_SUCCESS
end

# ─── H1 decoder dispatch ───

function h1_decoder_on_header(decoder::H1Decoder, header::H1DecodedHeader)::Int
    conn = decoder.context
    conn isa H1Connection || return OP_ERR
    return _conn_decoder_on_header(header, conn)
end

function h1_decoder_on_body(decoder::H1Decoder, data::AbstractVector{UInt8}, finished::Bool)::Int
    conn = decoder.context
    conn isa H1Connection || return OP_ERR
    return _conn_decoder_on_body(data, finished, conn)
end

function h1_decoder_on_request(decoder::H1Decoder, method_enum::HttpMethod.T, method_str::String, uri::String)::Int
    conn = decoder.context
    conn isa H1Connection || return OP_ERR
    return _conn_decoder_on_request(method_enum, method_str, uri, conn)
end

function h1_decoder_on_response(decoder::H1Decoder, status_code::Int)::Int
    conn = decoder.context
    conn isa H1Connection || return OP_ERR
    return _conn_decoder_on_response(status_code, conn)
end

function h1_decoder_on_done(decoder::H1Decoder)::Int
    conn = decoder.context
    conn isa H1Connection || return OP_ERR
    return _conn_decoder_on_done(conn)
end

# ─── Constructor ───

"""
    h1_connection_new_client(; kwargs...) -> H1Connection

Create a new HTTP/1.1 client connection.
"""
function h1_connection_new_client(;
    manual_window_management::Bool = false,
    initial_window_size::Csize_t = Csize_t(typemax(Csize_t)),
    read_buffer_capacity::Csize_t = Csize_t(0),
    on_shutdown = nothing,
    response_first_byte_timeout_ms::UInt64 = UInt64(0),
    h2c_upgrade::Bool = false,
)::H1Connection
    conn_window = manual_window_management ? initial_window_size : Csize_t(typemax(Csize_t))
    encoder = h1_encoder_init()
    conn = H1Connection(
        HttpVersion.HTTP_1_1, true,
        nothing, nothing, false,
        h2c_upgrade, nothing,
        H1Stream[], nothing, nothing, UInt32(1),
        encoder,
        h1_decoder_new(H1DecoderParams(1024, false)),
        conn_window, read_buffer_capacity, H1ConnectionReadState.OPEN,
        manual_window_management ? UInt64(initial_window_size) : typemax(UInt64),
        manual_window_management,
        true, false, false, 0, 0,
        response_first_byte_timeout_ms, _connection_shutdown_callback(on_shutdown),
        nothing, "",
    )
    h1_decoder_set_context!(conn.decoder, conn)
    return conn
end

"""
    h1_connection_new_server(; kwargs...) -> H1Connection

Create a new HTTP/1.1 server connection.
"""
function h1_connection_new_server(;
    manual_window_management::Bool = false,
    initial_window_size::Csize_t = Csize_t(typemax(Csize_t)),
    read_buffer_capacity::Csize_t = Csize_t(0),
    on_shutdown = nothing,
)::H1Connection
    conn_window = manual_window_management ? initial_window_size : Csize_t(typemax(Csize_t))
    encoder = h1_encoder_init()
    conn = H1Connection(
        HttpVersion.HTTP_1_1, false,
        nothing, nothing, false,
        false, nothing,
        H1Stream[], nothing, nothing, UInt32(2),
        encoder,
        h1_decoder_new(H1DecoderParams(1024, true)),
        conn_window, read_buffer_capacity, H1ConnectionReadState.OPEN,
        manual_window_management ? UInt64(initial_window_size) : typemax(UInt64),
        manual_window_management,
        true, false, false, 0, 0,
        UInt64(0), _connection_shutdown_callback(on_shutdown),
        nothing, "",
    )
    h1_decoder_set_context!(conn.decoder, conn)
    return conn
end

# ─── Connection public API ───

function http_connection_close(conn::H1Connection)::Nothing
    conn.is_open = false
    if conn.new_stream_error_code == 0
        conn.new_stream_error_code = ERROR_HTTP_CONNECTION_CLOSED
    end
    return nothing
end

http_connection_is_open(conn::H1Connection)::Bool = conn.is_open
http_connection_is_client(conn::H1Connection)::Bool = conn.is_client
http_connection_get_version(conn::H1Connection)::HttpVersion.T = conn.http_version

function http_connection_new_requests_allowed(conn::H1Connection)::Bool
    return conn.is_open && conn.new_stream_error_code == 0
end

function http_connection_stop_new_requests(conn::H1Connection)::Nothing
    if conn.new_stream_error_code == 0
        conn.new_stream_error_code = ERROR_HTTP_CONNECTION_CLOSED
    end
    return nothing
end

http_connection_get_remote_endpoint(conn::H1Connection)::String = conn.remote_endpoint

"""
    http_connection_has_switched_protocols(conn) -> Bool

Return whether this connection has completed a 101 Switching Protocols exchange.
"""
http_connection_has_switched_protocols(conn::H1Connection)::Bool = conn.has_switched_protocols

function _get_next_stream_id!(conn::H1Connection)::UInt32
    id = conn.next_stream_id
    conn.next_stream_id += UInt32(2)
    return id
end

# ─── Make request (client API) ───

function http_connection_make_request(
    conn::H1Connection;
    request::HttpMessage,
    on_response_headers=nothing,
    on_response_header_block_done=nothing,
    on_response_body=nothing,
    on_metrics=nothing,
    on_complete=nothing,
    on_destroy=nothing,
    response_first_byte_timeout_ms::UInt64=UInt64(0),
    http2_use_manual_data_writes::Bool=false,
    http2_priority=nothing,
    http2_headers_pad_length::UInt32=UInt32(0),
    h2c_upgrade::Bool=false,
    on_h2c_upgrade=nothing,
)::Union{H1Stream, Nothing}
    if !conn.is_client
        raise_error(ERROR_INVALID_STATE)
        return nothing
    end
    if conn.new_stream_error_code != 0
        raise_error(conn.new_stream_error_code)
        return nothing
    end
    return h1_stream_new_request(
        conn;
        request=request,
        on_response_headers=on_response_headers,
        on_response_header_block_done=on_response_header_block_done,
        on_response_body=on_response_body,
        on_metrics=on_metrics,
        on_complete=on_complete,
        on_destroy=on_destroy,
        response_first_byte_timeout_ms=response_first_byte_timeout_ms,
        http2_use_manual_data_writes=http2_use_manual_data_writes,
        http2_priority=http2_priority,
        http2_headers_pad_length=http2_headers_pad_length,
        h2c_upgrade=h2c_upgrade,
        on_h2c_upgrade=on_h2c_upgrade,
    )
end

# ─── Make server request handler (server API) ───

function http_connection_new_request_handler(
    conn::H1Connection;
    on_request_headers=nothing,
    on_request_header_block_done=nothing,
    on_request_body=nothing,
    on_request_done=nothing,
    on_complete=nothing,
    on_destroy=nothing,
)::Union{H1Stream, Nothing}
    if conn.is_client
        raise_error(ERROR_INVALID_STATE)
        return nothing
    end
    if conn.new_stream_error_code != 0
        raise_error(conn.new_stream_error_code)
        return nothing
    end
    return h1_stream_new_request_handler(
        conn;
        on_request_headers=on_request_headers,
        on_request_header_block_done=on_request_header_block_done,
        on_request_body=on_request_body,
        on_request_done=on_request_done,
        on_complete=on_complete,
        on_destroy=on_destroy,
    )
end

# ─── Stream activation ───

"""
    h1_stream_activate!(stream::H1Stream) -> Int

Activate a stream, adding it to the connection's pipeline.
"""
function h1_stream_activate!(stream::H1Stream)::Int
    conn = stream.owning_connection::H1Connection
    if conn.new_stream_error_code != 0
        return raise_error(conn.new_stream_error_code)
    end

    stream.id = _get_next_stream_id!(conn)
    stream.api_state = H1StreamApiState.ACTIVE
    push!(conn.stream_list, stream)

    if conn.incoming_stream === nothing
        conn.incoming_stream = stream
    end

    return OP_SUCCESS
end

# ─── Stream management ───

function _advance_incoming_stream!(conn::H1Connection)
    conn.incoming_stream = nothing
    for s in conn.stream_list
        if !s.is_incoming_message_done
            conn.incoming_stream = s
            return
        end
    end
end

function _try_complete_stream!(conn::H1Connection, stream::H1Stream)
    if stream.is_outgoing_message_done && stream.is_incoming_message_done
        _finish_stream!(conn, stream)
    end
end

function _finish_stream!(conn::H1Connection, stream::H1Stream)
    filter!(s -> s !== stream, conn.stream_list)

    if conn.outgoing_stream === stream
        conn.outgoing_stream = nothing
    end
    if conn.incoming_stream === stream
        _advance_incoming_stream!(conn)
    end

    _cancel_response_first_byte_timeout!(conn, stream)
    _stream_complete!(stream, 0)

    if stream.is_final_stream
        conn.is_open = false
        if conn.new_stream_error_code == 0
            conn.new_stream_error_code = ERROR_HTTP_CONNECTION_CLOSED
        end
        if conn.slot !== nothing
            Sockets.channel_shutdown!(conn.slot.channel; shutdown_immediately=true)
        end
    end

    # Detect 101 Switching Protocols
    if stream.is_client && stream.response_status == HTTP_STATUS_CODE_101_SWITCHING_PROTOCOLS
        conn.has_switched_protocols = true
        if conn.new_stream_error_code == 0
            conn.new_stream_error_code = ERROR_HTTP_SWITCHED_PROTOCOLS
        end
    end
end

function _response_first_byte_timeout_task(stream, status::Reseau.TaskStatus.T)
    status == Reseau.TaskStatus.RUN_READY || return nothing
    stream.api_state == H1StreamApiState.COMPLETE && return nothing
    conn = stream.owning_connection
    if conn.slot !== nothing
        Sockets.channel_shutdown!(conn.slot.channel, ERROR_HTTP_RESPONSE_FIRST_BYTE_TIMEOUT; shutdown_immediately=true)
    else
        _stream_complete!(stream, ERROR_HTTP_RESPONSE_FIRST_BYTE_TIMEOUT)
    end
    return nothing
end

function _schedule_response_first_byte_timeout!(conn::H1Connection, stream::H1Stream)::Nothing
    conn.slot === nothing && return nothing
    stream.metrics.receive_start_timestamp_ns >= 0 && return nothing
    timeout_ms = stream.response_first_byte_timeout_ms == 0 ? conn.response_first_byte_timeout_ms : stream.response_first_byte_timeout_ms
    timeout_ms == 0 && return nothing
    task = stream.response_first_byte_timeout_task
    if task === nothing
        task = Reseau.ScheduledTask(; type_tag = "http_response_first_byte_timeout") do status
            try
                _response_first_byte_timeout_task(stream, Reseau.TaskStatus.T(status))
            catch e
                Core.println("http_response_first_byte_timeout task errored: $e")
            end
            return nothing
        end
        stream.response_first_byte_timeout_task = task
    end
    task.scheduled && return nothing
    event_loop = conn.slot.channel.event_loop
    now = Reseau.clock_now_ns()
    EventLoops.schedule_task_future!(event_loop, task, now + timeout_ms * 1_000_000)
    return nothing
end

function _cancel_response_first_byte_timeout!(conn::H1Connection, stream::H1Stream)::Nothing
    task = stream.response_first_byte_timeout_task
    task === nothing && return nothing
    conn.slot === nothing && return nothing
    if task.scheduled
        EventLoops.cancel_task!(conn.slot.channel.event_loop, task)
    end
    return nothing
end

# ─── Write path: encode outgoing stream data ───

"""
    h1_connection_encode_outgoing!(conn) -> (Int, Vector{UInt8})

Encode the current outgoing stream's data into bytes.
Returns `(status, encoded_bytes)`. The caller is responsible for
transmitting the bytes (e.g., via channel or directly to socket).
"""
function h1_connection_encode_outgoing!(conn::H1Connection)::Tuple{Int, Vector{UInt8}}
    if conn.outgoing_stream === nothing
        _update_outgoing_stream!(conn)
    end

    stream = conn.outgoing_stream
    stream === nothing && return (OP_SUCCESS, UInt8[])
    stream.encoder_message === nothing && return (OP_SUCCESS, UInt8[])

    if !h1_encoder_is_message_in_progress(conn.encoder)
        err = h1_encoder_start_message!(conn.encoder, stream.encoder_message)
        err != OP_SUCCESS && return (OP_ERR, UInt8[])
        # Record send-start timestamp
        if stream.metrics.send_start_timestamp_ns < 0
            stream.metrics = HttpStreamMetrics(
                Reseau.monotonic_time_ns() % Int64,
                stream.metrics.send_end_timestamp_ns,
                stream.metrics.sending_duration_ns,
                stream.metrics.receive_start_timestamp_ns,
                stream.metrics.receive_end_timestamp_ns,
                stream.metrics.receiving_duration_ns,
                stream.metrics.stream_id,
            )
        end
    end

    dst = IOBuffer(; maxsize=16384)
    err = h1_encoder_process!(conn.encoder, dst)
    err != OP_SUCCESS && return (OP_ERR, UInt8[])

    encoded = take!(dst)

    if !h1_encoder_is_message_in_progress(conn.encoder)
        stream.is_outgoing_message_done = true
        # Record send-end timestamp and sending duration
        now = Reseau.monotonic_time_ns() % Int64
        send_start = stream.metrics.send_start_timestamp_ns
        sending_dur = send_start >= 0 ? (now - send_start) : Int64(-1)
        stream.metrics = HttpStreamMetrics(
            send_start, now, sending_dur,
            stream.metrics.receive_start_timestamp_ns,
            stream.metrics.receive_end_timestamp_ns,
            stream.metrics.receiving_duration_ns,
            stream.metrics.stream_id,
        )
        h1_encoder_message_clean_up!(stream.encoder_message)
        stream.encoder_message = nothing
        if stream.h2c.switch_on_outgoing_done && !stream.is_client
            stream.h2c.switch_on_outgoing_done = false
            if _h1_finish_server_h2c_upgrade!(conn, stream) != OP_SUCCESS
                if conn.slot !== nothing && conn.slot.channel !== nothing
                    err = Reseau.last_error()
                    err == 0 && (err = ERROR_HTTP_PROTOCOL_SWITCH_FAILURE)
                    Sockets.channel_shutdown!(conn.slot.channel, err; shutdown_immediately=true)
                end
            end
        end
        _schedule_response_first_byte_timeout!(conn, stream)
        _try_complete_stream!(conn, stream)
        conn.outgoing_stream = nothing
        _update_outgoing_stream!(conn)
    end

    return (OP_SUCCESS, encoded)
end

function _update_outgoing_stream!(conn::H1Connection)
    for s in conn.stream_list
        if s.encoder_message !== nothing && !s.is_outgoing_message_done
            conn.outgoing_stream = s
            return
        end
    end
    conn.outgoing_stream = nothing
end

# ─── Read path: decode incoming data ───

function _ensure_server_incoming_stream!(conn::H1Connection)::Nothing
    if conn.incoming_stream !== nothing || conn.is_client || conn.on_incoming_request === nothing
        return nothing
    end
    if conn.h2c_enabled
        probe = _h1_create_h2c_probe_stream(conn)
        probe === nothing && Reseau.throw_error(Reseau.ERROR_UNKNOWN)
        return nothing
    end
    stream = conn.on_incoming_request(conn)
    stream === nothing && Reseau.throw_error(ERROR_HTTP_REACTION_REQUIRED)
    if !(stream isa H1Stream)
        Reseau.throw_error(ERROR_INVALID_ARGUMENT)
    end
    if stream.api_state == H1StreamApiState.INIT
        status = h1_stream_activate!(stream)
        status != OP_SUCCESS && Reseau.throw_error(status)
    end
    return nothing
end

"""
    h1_connection_process_read_data!(conn, data) -> Int

Feed incoming data to the decoder. Decoder callbacks fire and
dispatch to the current incoming stream.
"""
function _h1_connection_process_read_data_internal!(conn::H1Connection, data::AbstractVector{UInt8})::Tuple{Int, Int}
    if conn.incoming_stream === nothing
        try
            _ensure_server_incoming_stream!(conn)
        catch
            return (OP_ERR, 0)
        end
        conn.incoming_stream === nothing && return (OP_SUCCESS, length(data))
    end
    status, consumed = h1_decode!(conn.decoder, data)
    status != OP_SUCCESS && return (OP_ERR, 0)
    return (OP_SUCCESS, consumed)
end

function h1_connection_process_read_data!(conn::H1Connection, data::AbstractVector{UInt8})::Int
    status, _ = _h1_connection_process_read_data_internal!(conn, data)
    return status
end

function h1_connection_process_read_data!(conn::H1Connection, data::AbstractString)::Int
    return h1_connection_process_read_data!(conn, Vector{UInt8}(codeunits(String(data))))
end

function _h1_forward_remaining_bytes!(conn::H1Connection, data::AbstractVector{UInt8}, start_pos::Int)::Nothing
    conn.slot === nothing && return nothing
    channel = conn.slot.channel
    channel === nothing && return nothing
    start_pos > length(data) && return nothing
    leftover_len = length(data) - start_pos + 1
    msg = Sockets.channel_acquire_message_from_pool(channel, Sockets.IoMessageType.APPLICATION_DATA, leftover_len)
    msg === nothing && Reseau.throw_error(Reseau.ERROR_OOM)
    buf = msg.message_data
    @inbounds for i in 1:leftover_len
        buf.mem[i] = data[start_pos - 1 + i]
    end
    buf.len = Csize_t(leftover_len)
    Sockets.channel_slot_send_message(conn.slot, msg, Sockets.ChannelDirection.READ)
    return nothing
end

# ─── Connection cleanup ───

function h1_connection_destroy!(conn::H1Connection)::Nothing
    # Complete any remaining streams with error
    for stream in copy(conn.stream_list)
        _stream_complete!(stream, ERROR_HTTP_CONNECTION_CLOSED)
    end
    empty!(conn.stream_list)
    conn.incoming_stream = nothing
    conn.outgoing_stream = nothing

    h1_encoder_clean_up!(conn.encoder)
    h1_decoder_destroy!(conn.decoder)
    return nothing
end

# ─── Channel handler interface ───
# These methods integrate H1Connection into the Reseau channel pipeline.

function Sockets.handler_process_read_message(conn::H1Connection, slot::Sockets.ChannelSlot, message::Sockets.IoMessage)::Nothing
    if conn.has_switched_protocols
        Sockets.channel_slot_send_message(slot, message, Sockets.ChannelDirection.READ)
        return nothing
    end

    data = Reseau.byte_buffer_as_vector(message.message_data)
    consumed = 0
    try
        if !isempty(data)
            status, consumed = _h1_connection_process_read_data_internal!(conn, data)
            status == OP_SUCCESS || Reseau.throw_error(ERROR_HTTP_PROTOCOL_ERROR)
        end
        if conn.has_switched_protocols && consumed < length(data)
            _h1_forward_remaining_bytes!(conn, data, consumed + 1)
        end
        Sockets.channel_slot_increment_read_window!(slot, message.message_data.len)
    finally
        if slot.channel !== nothing
            Sockets.channel_release_message_to_pool!(slot.channel, message)
        end
    end
    return nothing
end

function Sockets.handler_process_write_message(conn::H1Connection, slot::Sockets.ChannelSlot, message::Sockets.IoMessage)::Nothing
    Sockets.channel_slot_send_message(slot, message, Sockets.ChannelDirection.WRITE)
    return nothing
end

function Sockets.handler_increment_read_window(conn::H1Connection, slot::Sockets.ChannelSlot, size::Csize_t)::Nothing
    Sockets.channel_slot_increment_read_window!(slot, size)
    return nothing
end

function Sockets.handler_shutdown(
    conn::H1Connection,
    slot::Sockets.ChannelSlot,
    direction::Sockets.ChannelDirection.T,
    error_code::Int,
    free_scarce_resources_immediately::Bool,
)::Nothing
    conn.is_open = false
    err_code = error_code != 0 ? error_code : ERROR_HTTP_CONNECTION_CLOSED
    conn.new_stream_error_code = err_code

    for stream in copy(conn.stream_list)
        _cancel_response_first_byte_timeout!(conn, stream)
        _stream_complete!(stream, err_code)
    end
    empty!(conn.stream_list)
    conn.incoming_stream = nothing
    conn.outgoing_stream = nothing

    Sockets.channel_slot_on_handler_shutdown_complete!(slot, direction, error_code, free_scarce_resources_immediately)
    return nothing
end

Sockets.handler_initial_window_size(conn::H1Connection)::Csize_t = conn.connection_window
Sockets.handler_message_overhead(conn::H1Connection)::Csize_t = Csize_t(0)

function Sockets.handler_destroy(conn::H1Connection)::Nothing
    h1_connection_destroy!(conn)
    return nothing
end
