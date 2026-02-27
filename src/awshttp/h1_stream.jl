# HTTP/1.1 Stream - Client/server stream on an H1 connection
# Port of aws-c-http/source/h1_stream.c, h1_stream.h, request_response_impl.h

# ─── Stream API state ───

@enumx H1StreamApiState::UInt8 begin
    INIT = 0
    ACTIVE = 1
    COMPLETE = 2
end

# ─── h2c upgrade state ───

mutable struct H2CState
    is_upgrade_request::Bool
    is_h2c_probe::Bool
    headers_buffered::Bool
    response_upgrade_h2c::Bool
    response_connection_upgrade::Bool
    upgrade_callback_invoked::Bool
    switch_on_outgoing_done::Bool
    request_message::Union{HttpMessage, Nothing}
    original_request::Union{HttpMessage, Nothing}
    upgrade_settings::Union{AbstractVector, Nothing}
    on_h2c_upgrade::Union{Nothing, Function}
end

function H2CState(on_h2c_upgrade = nothing)
    return H2CState(
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        nothing,
        nothing,
        nothing,
        on_h2c_upgrade,
    )
end

function _h1_create_h2c_upgrade_request(
        original_request::HttpMessage,
        settings_value::AbstractVector{UInt8},
    )::Union{HttpMessage, Nothing}
    upgrade_request = http_message_new_request()
    method = http_message_get_request_method(original_request)
    path = http_message_get_request_path(original_request)
    if method === nothing || path === nothing
        raise_error(ERROR_INVALID_ARGUMENT)
        return nothing
    end
    if http_message_set_request_method(upgrade_request, method) != OP_SUCCESS ||
            http_message_set_request_path(upgrade_request, path) != OP_SUCCESS
        return nothing
    end

    headers = http_message_get_headers(original_request)
    count = http_headers_count(headers)
    for i in 0:(count - 1)
        h = http_headers_get_index(headers, i)
        h === nothing && continue
        lower_name = lowercase(h.name)
        if lower_name == "connection" || lower_name == "upgrade" || lower_name == "http2-settings"
            continue
        end
        if http_message_add_header(upgrade_request, h) != OP_SUCCESS
            return nothing
        end
    end

    if http_message_add_header(upgrade_request, HttpHeader("Upgrade", "h2c")) != OP_SUCCESS ||
            http_message_add_header(upgrade_request, HttpHeader("Connection", "Upgrade, HTTP2-Settings")) != OP_SUCCESS ||
            http_message_add_header(upgrade_request, HttpHeader("HTTP2-Settings", String(settings_value))) != OP_SUCCESS
        return nothing
    end

    return upgrade_request
end

# ─── Callback types (see Phase 5.5 of parity roadmap) ───
# All callbacks are stored as `Any` to allow flexible function types.
# Signature conventions:
#   on_incoming_headers(stream, header_block, headers::Vector{HttpHeader}) -> Int
#   on_incoming_header_block_done(stream, header_block) -> Int
#   on_incoming_body(stream, data::AbstractVector{UInt8}) -> Int
#   on_stream_complete(stream, error_code::Int) -> Nothing
#   on_stream_destroy(stream) -> Nothing
#   on_stream_metrics(stream, metrics::HttpStreamMetrics) -> Nothing

# ─── H1 Stream ───

mutable struct H1Stream
    # ── Base stream fields ──
    owning_connection::HttpConnection
    id::UInt32
    request_method::HttpMethod.T
    metrics::HttpStreamMetrics

    # Callbacks
    on_incoming_headers::Union{Nothing, Function}
    on_incoming_header_block_done::Union{Nothing, Function}
    on_incoming_body::Union{Nothing, Function}
    on_metrics::Union{Nothing, Function}
    on_complete::Union{Nothing, Function}
    on_destroy::Union{Nothing, Function}

    # Client-specific
    response_status::Int
    response_first_byte_timeout_ms::UInt64
    response_first_byte_timeout_task::Union{Reseau.ScheduledTask, Nothing}

    # Server-specific
    request_method_str::String
    request_path::String
    on_request_done::Union{Nothing, Function}

    is_client::Bool

    # ── Thread data (event-loop thread only) ──
    # late-init: starts nothing, assigned during message start
    encoder_message::Union{H1EncoderMessage, Nothing}
    is_outgoing_message_done::Bool
    is_incoming_message_done::Bool
    is_incoming_head_done::Bool
    is_final_stream::Bool
    stream_window::UInt64
    has_outgoing_response::Bool

    # ── Synced data ──
    api_state::H1StreamApiState.T

    # ── h2c upgrade state ──
    h2c::H2CState
end

"""
    h1_stream_new_request(connection; kwargs...) -> H1Stream

Create a new client request stream. The stream is not yet active; call `h1_stream_activate!`.
"""
function h1_stream_new_request(
    connection;
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
    msg = request
    method_str = http_message_get_request_method(msg)
    method_enum = http_str_to_method(method_str)

    h2c_state = H2CState(on_h2c_upgrade)
    request_for_encoder = msg
    use_h2c_upgrade = h2c_upgrade || connection.h2c_enabled
    if use_h2c_upgrade
        if http2_use_manual_data_writes || _h1_request_has_body(http_message_get_headers(msg)) ||
                http_message_get_body_stream(msg) !== nothing
            raise_error(ERROR_INVALID_ARGUMENT)
            return nothing
        end
        local settings_value
        try
            settings_value = _h1_connection_get_h2c_settings_header(connection)
        catch
            return nothing
        end
        upgrade_req = _h1_create_h2c_upgrade_request(msg, settings_value)
        upgrade_req === nothing && return nothing
        request_for_encoder = upgrade_req
        h2c_state.is_upgrade_request = true
        h2c_state.original_request = msg
    end

    # Build encoder message from request
    enc_msg = H1EncoderMessage()
    err = h1_encoder_message_init_from_request!(enc_msg, request_for_encoder)
    err != OP_SUCCESS && return nothing  # should not happen if request is valid

    stream = H1Stream(
        connection,
        UInt32(0),   # id assigned on activation
        method_enum,
        HttpStreamMetrics(),
        # callbacks
        on_response_headers,
        on_response_header_block_done,
        on_response_body,
        on_metrics,
        on_complete,
        on_destroy,
        # client
        HTTP_STATUS_CODE_UNKNOWN,
        response_first_byte_timeout_ms,
        nothing,
        # server (unused for client)
        "", "", nothing,
        true,  # is_client
        # thread data
        enc_msg,
        false, false, false, false,
        typemax(UInt64),  # stream_window (auto: unlimited)
        false,
        # synced
        H1StreamApiState.INIT,
        h2c_state,
    )
    return stream
end

"""
    h1_stream_new_request_handler(connection; kwargs...) -> H1Stream

Create a new server request handler stream.
"""
function h1_stream_new_request_handler(
    connection::HttpConnection;
    on_request_headers=nothing,
    on_request_header_block_done=nothing,
    on_request_body=nothing,
    on_request_done=nothing,
    on_complete=nothing,
    on_destroy=nothing,
)::H1Stream
    stream = H1Stream(
        connection,
        UInt32(0),
        HttpMethod.UNKNOWN,
        HttpStreamMetrics(),
        # callbacks
        on_request_headers,
        on_request_header_block_done,
        on_request_body,
        nothing,  # on_metrics
        on_complete,
        on_destroy,
        # client (unused)
        HTTP_STATUS_CODE_UNKNOWN, UInt64(0), nothing,
        # server
        "", "", on_request_done,
        false,  # is_client = false (server)
        # thread data
        nothing, false, false, false, false,
        typemax(UInt64),
        false,
        # synced
        H1StreamApiState.INIT,
        H2CState(),
    )
    return stream
end

# ─── Stream lifecycle ───


http_stream_get_id(stream::H1Stream)::UInt32 = stream.id

function http_stream_get_incoming_response_status(stream::H1Stream)::Int
    return stream.response_status
end

function http_stream_get_connection(stream::H1Stream)
    return stream.owning_connection
end

http_stream_get_incoming_request_method(stream::H1Stream)::String = stream.request_method_str
http_stream_get_incoming_request_uri(stream::H1Stream)::String = stream.request_path

# ─── Stream cancel ───

"""
    http_stream_cancel(stream::H1Stream) -> Nothing

Cancel an in-flight stream. Completes it with ERROR_HTTP_STREAM_CANCELLED.
"""
function http_stream_cancel(stream::H1Stream)::Nothing
    if stream.api_state != H1StreamApiState.COMPLETE
        _stream_complete!(stream, ERROR_HTTP_STREAM_CANCELLED)
    end
    return nothing
end

# ─── Stream window update ───

"""
    http_stream_update_window(stream::H1Stream, increment::UInt64) -> Int

Increment the stream's flow control window by the given amount.
Only valid when manual window management is enabled on the connection.
"""
function http_stream_update_window(stream::H1Stream, increment::UInt64)::Int
    increment == 0 && return raise_error(ERROR_INVALID_ARGUMENT)
    stream.stream_window += increment
    return OP_SUCCESS
end

# ─── Server: send response ───

"""
    h1_stream_send_response!(stream::H1Stream, response::HttpMessage) -> Int

Send a response on a server-side stream. Builds the encoder message
from the response and sets it on the stream for the connection to encode.
"""
function h1_stream_send_response!(stream::H1Stream, response::HttpMessage)::Int
    stream.is_client && return raise_error(ERROR_INVALID_STATE)
    stream.has_outgoing_response && return raise_error(ERROR_INVALID_STATE)

    enc_msg = H1EncoderMessage()
    err = h1_encoder_message_init_from_response!(enc_msg, response)
    err != OP_SUCCESS && return OP_ERR

    stream.encoder_message = enc_msg
    stream.has_outgoing_response = true
    return OP_SUCCESS
end

# ─── Chunked encoding API ───

"""
    h1_stream_write_chunk!(stream::H1Stream, chunk::H1Chunk) -> Int

Submit a chunk to be sent on this stream. The stream's encoder message must
use chunked transfer encoding. A final zero-length chunk terminates the body.
"""
function h1_stream_write_chunk!(stream::H1Stream, chunk::H1Chunk)::Int
    enc = stream.encoder_message
    enc === nothing && return raise_error(ERROR_INVALID_STATE)
    !enc.has_chunked_encoding_header && return raise_error(ERROR_INVALID_STATE)
    push!(enc.pending_chunk_list, chunk)
    return OP_SUCCESS
end

"""
    h1_stream_add_chunked_trailer!(stream::H1Stream, headers::HttpHeaders) -> Int

Set trailing headers on the stream's chunked message. Trailers are sent after
the final zero-length chunk. The headers are pre-encoded into the H1Trailer format.
"""
function h1_stream_add_chunked_trailer!(stream::H1Stream, headers::HttpHeaders)::Int
    enc = stream.encoder_message
    enc === nothing && return raise_error(ERROR_INVALID_STATE)
    !enc.has_chunked_encoding_header && return raise_error(ERROR_INVALID_STATE)
    trailer = h1_trailer_new(headers)
    trailer === nothing && return OP_ERR
    enc.trailer = trailer
    return OP_SUCCESS
end

# ─── Stream completion ───

function _stream_complete!(stream::H1Stream, error_code::Int)::Nothing
    stream.api_state = H1StreamApiState.COMPLETE

    if stream.on_metrics !== nothing
        stream.on_metrics(stream, stream.metrics)
    end

    if stream.on_complete !== nothing
        stream.on_complete(stream, error_code)
    end

    if stream.on_destroy !== nothing
        stream.on_destroy(stream)
    end
    return nothing
end
