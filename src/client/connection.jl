function _client_url(client::Client)
    host = client.settings.host
    port = client.settings.port
    return string(client.settings.scheme, "://", host, ":", port)
end

function with_connection(f, client::Client; context=nothing)
    start_time = context !== nothing ? time() : 0.0
    connection, error_code = wait(AwsHTTP.http_connection_manager_acquire_connection(client.connection_manager))
    if error_code != AwsHTTP.OP_SUCCESS || connection === nothing
        ec = error_code != AwsHTTP.OP_SUCCESS ? error_code : Reseau.last_error()
        throw(ConnectError(_client_url(client), aws_error(ec)))
    end
    try
        return f(connection)
    finally
        AwsHTTP.http_connection_manager_release_connection(client.connection_manager, connection)
        context !== nothing && _record_layer!(context, :connectionlayer, start_time)
    end
end

function _ensure_http2_connection(conn)
    conn === nothing && throw(ArgumentError("HTTP/2 connection is null"))
    AwsHTTP.http_connection_get_version(conn) == AwsHTTP.HttpVersion.HTTP_2 || throw(ArgumentError("HTTP/2 connection required"))
    return conn
end

function _with_http2_connection(f, client::Client)
    return with_connection(client) do conn
        f(_ensure_http2_connection(conn))
    end
end

function http2_ping(conn; data=nothing)
    _ensure_http2_connection(conn)
    opaque_data = if data !== nothing
        bytes = data isa AbstractString ? Vector{UInt8}(codeunits(data)) : Vector{UInt8}(data)
        length(bytes) == AwsHTTP.H2_PING_DATA_SIZE || throw(ArgumentError("PING data must be $(AwsHTTP.H2_PING_DATA_SIZE) bytes"))
        bytes
    else
        zeros(UInt8, AwsHTTP.H2_PING_DATA_SIZE)
    end
    rtt_ns, error_code = wait(AwsHTTP.h2_connection_send_ping!(conn, opaque_data))
    error_code == AwsHTTP.OP_SUCCESS || throw(aws_error(error_code))
    return rtt_ns
end

http2_ping(client::Client; data=nothing) = _with_http2_connection(conn -> http2_ping(conn; data=data), client)

function _settings_from_pairs(settings::AbstractVector{<:Pair})
    out = Vector{AwsHTTP.Http2Setting}(undef, length(settings))
    for (i, (k, v)) in enumerate(settings)
        id = k isa AwsHTTP.Http2SettingsId.T ? k : AwsHTTP.Http2SettingsId.T(k)
        out[i] = AwsHTTP.Http2Setting(id, UInt32(v))
    end
    return out
end

function http2_change_settings(conn, settings::Vector{AwsHTTP.Http2Setting})
    _ensure_http2_connection(conn)
    error_code = wait(AwsHTTP.h2_connection_change_settings!(conn, settings))
    error_code == AwsHTTP.OP_SUCCESS || throw(aws_error(error_code))
    return
end

http2_change_settings(conn, settings::AbstractVector{<:Pair}) =
    http2_change_settings(conn, _settings_from_pairs(settings))

http2_change_settings(client::Client, settings) =
    _with_http2_connection(conn -> http2_change_settings(conn, settings), client)


function http2_local_settings(conn)
    _ensure_http2_connection(conn)
    return AwsHTTP.h2_connection_get_local_settings(conn)
end

http2_local_settings(client::Client) = _with_http2_connection(http2_local_settings, client)

function http2_remote_settings(conn)
    _ensure_http2_connection(conn)
    return AwsHTTP.h2_connection_get_remote_settings(conn)
end

http2_remote_settings(client::Client) = _with_http2_connection(http2_remote_settings, client)

function http2_send_goaway(conn, http2_error::Integer; allow_more_streams::Bool=true, debug_data=nothing)
    _ensure_http2_connection(conn)
    dd = if debug_data !== nothing
        bytes = debug_data isa AbstractString ? Vector{UInt8}(codeunits(debug_data)) : Vector{UInt8}(debug_data)
        length(bytes) <= 16 * 1024 || throw(ArgumentError("debug_data must be <= 16KB"))
        bytes
    else
        UInt8[]
    end
    AwsHTTP.h2_connection_send_goaway!(conn;
        allow_more_streams=allow_more_streams,
        error_code=UInt32(http2_error),
        debug_data=dd
    )
    return
end

http2_send_goaway(client::Client, http2_error::Integer; allow_more_streams::Bool=true, debug_data=nothing) =
    _with_http2_connection(conn -> http2_send_goaway(conn, http2_error; allow_more_streams=allow_more_streams, debug_data=debug_data), client)

function http2_update_window(conn, increment::Integer)
    _ensure_http2_connection(conn)
    increment < 0 && throw(ArgumentError("increment must be >= 0"))
    increment > HTTP2_MAX_WINDOW_SIZE && throw(ArgumentError("increment must be <= $(HTTP2_MAX_WINDOW_SIZE)"))
    AwsHTTP.h2_connection_update_window!(conn, UInt32(increment))
    return
end

http2_update_window(client::Client, increment::Integer) =
    _with_http2_connection(conn -> http2_update_window(conn, increment), client)


function _get_goaway(get_fn, conn)
    _ensure_http2_connection(conn)
    sent_or_received, last_stream_id, error_code = get_fn(conn)
    if sent_or_received
        return (http2_error=error_code, last_stream_id=last_stream_id)
    else
        return nothing
    end
end

http2_get_sent_goaway(conn) = _get_goaway(AwsHTTP.h2_connection_get_sent_goaway, conn)
http2_get_received_goaway(conn) = _get_goaway(AwsHTTP.h2_connection_get_received_goaway, conn)

http2_get_sent_goaway(client::Client) = _with_http2_connection(http2_get_sent_goaway, client)
http2_get_received_goaway(client::Client) = _with_http2_connection(http2_get_received_goaway, client)
