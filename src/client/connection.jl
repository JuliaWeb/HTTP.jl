const on_setup = Ref{Ptr{Cvoid}}(C_NULL)
const on_change_settings_complete = Ref{Ptr{Cvoid}}(C_NULL)
const on_ping_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_setup(conn, error_code, fut_ptr)
    fut = unsafe_pointer_to_objref(fut_ptr)
    if error_code == AWS_IO_DNS_INVALID_NAME# || error_code == AWS_IO_TLS_ERROR_NEGOTIATION_FAILURE
        notify(fut, DontRetry(CapturedException(aws_error(error_code), Base.backtrace())))
    elseif error_code != 0
        notify(fut, CapturedException(aws_error(error_code), Base.backtrace()))
    else
        notify(fut, conn)
    end
    return
end

function c_on_change_settings_complete(conn, error_code, fut_ptr)
    fut = unsafe_pointer_to_objref(fut_ptr)
    if error_code != 0
        notify(fut, CapturedException(aws_error(error_code), Base.backtrace()))
    else
        notify(fut, nothing)
    end
    return
end

function c_on_ping_complete(conn, round_trip_time_ns, error_code, fut_ptr)
    fut = unsafe_pointer_to_objref(fut_ptr)
    if error_code != 0
        notify(fut, CapturedException(aws_error(error_code), Base.backtrace()))
    else
        notify(fut, round_trip_time_ns)
    end
    return
end

function _client_url(client::Client)
    host = client.settings.host
    port = client.settings.port
    return string(client.settings.scheme, "://", host, ":", port)
end

function with_connection(f::Function, client::Client; context=nothing)
    if context === nothing
        fut = Future{Ptr{aws_http_connection}}()
        GC.@preserve fut begin
            aws_http_connection_manager_acquire_connection(client.connection_manager, on_setup[], pointer_from_objref(fut))
            connection = try
                wait(fut)
            catch e
                throw(ConnectError(_client_url(client), e))
            end
        end
        try
            return f(connection)
        finally
            aws_http_connection_manager_release_connection(client.connection_manager, connection)
        end
    end
    start_time = time()
    fut = Future{Ptr{aws_http_connection}}()
    GC.@preserve fut begin
        aws_http_connection_manager_acquire_connection(client.connection_manager, on_setup[], pointer_from_objref(fut))
        connection = try
            wait(fut)
        catch e
            throw(ConnectError(_client_url(client), e))
        end
    end
    try
        return f(connection)
    finally
        aws_http_connection_manager_release_connection(client.connection_manager, connection)
        _record_layer!(context, :connectionlayer, start_time)
    end
end

function _ensure_http2_connection(conn::Ptr{aws_http_connection})
    conn == C_NULL && throw(ArgumentError("HTTP/2 connection is null"))
    aws_http_connection_get_version(conn) == AWS_HTTP_VERSION_2 || throw(ArgumentError("HTTP/2 connection required"))
    return conn
end

function _with_http2_connection(f::Function, client::Client)
    return with_connection(client) do conn
        f(_ensure_http2_connection(conn))
    end
end

function http2_ping(conn::Ptr{aws_http_connection}; data=nothing)
    _ensure_http2_connection(conn)
    fut = Future{UInt64}()
    cursor_ref = Ref{aws_byte_cursor}()
    cursor_ptr = C_NULL
    bytes = nothing
    if data !== nothing
        bytes = data isa AbstractString ? Vector{UInt8}(codeunits(data)) : Vector{UInt8}(data)
        length(bytes) == AWS_HTTP2_PING_DATA_SIZE || throw(ArgumentError("PING data must be $(AWS_HTTP2_PING_DATA_SIZE) bytes"))
        GC.@preserve bytes begin
            cursor_ref[] = aws_byte_cursor_from_array(pointer(bytes), length(bytes))
        end
        cursor_ptr = cursor_ref
    end
    GC.@preserve fut cursor_ref bytes begin
        aws_http2_connection_ping(conn, cursor_ptr, on_ping_complete[], pointer_from_objref(fut)) != 0 && aws_throw_error()
        return wait(fut)
    end
end

http2_ping(client::Client; data=nothing) = _with_http2_connection(conn -> http2_ping(conn; data=data), client)

function _settings_from_pairs(settings::AbstractVector{<:Pair})
    out = Vector{aws_http2_setting}(undef, length(settings))
    for (i, (k, v)) in enumerate(settings)
        out[i] = aws_http2_setting(aws_http2_settings_id(k), UInt32(v))
    end
    return out
end

function http2_change_settings(conn::Ptr{aws_http_connection}, settings::AbstractVector{aws_http2_setting})
    _ensure_http2_connection(conn)
    fut = Future{Nothing}()
    settings_ptr = isempty(settings) ? C_NULL : pointer(settings)
    GC.@preserve settings fut begin
        aws_http2_connection_change_settings(conn, settings_ptr, length(settings), on_change_settings_complete[], pointer_from_objref(fut)) != 0 && aws_throw_error()
        wait(fut)
    end
    return
end

http2_change_settings(conn::Ptr{aws_http_connection}, settings::AbstractVector{<:Pair}) =
    http2_change_settings(conn, _settings_from_pairs(settings))

http2_change_settings(client::Client, settings) =
    _with_http2_connection(conn -> http2_change_settings(conn, settings), client)


function http2_local_settings(conn::Ptr{aws_http_connection})
    _ensure_http2_connection(conn)
    settings = Vector{aws_http2_setting}(undef, AWS_HTTP2_SETTINGS_COUNT)
    aws_http2_connection_get_local_settings(conn, pointer(settings))
    return settings
end

http2_local_settings(client::Client) = _with_http2_connection(http2_local_settings, client)

function http2_remote_settings(conn::Ptr{aws_http_connection})
    _ensure_http2_connection(conn)
    settings = Vector{aws_http2_setting}(undef, AWS_HTTP2_SETTINGS_COUNT)
    aws_http2_connection_get_remote_settings(conn, pointer(settings))
    return settings
end

http2_remote_settings(client::Client) = _with_http2_connection(http2_remote_settings, client)

function http2_send_goaway(conn::Ptr{aws_http_connection}, http2_error::Integer; allow_more_streams::Bool=true, debug_data=nothing)
    _ensure_http2_connection(conn)
    cursor_ref = Ref{aws_byte_cursor}()
    cursor_ptr = C_NULL
    bytes = nothing
    if debug_data !== nothing
        bytes = debug_data isa AbstractString ? Vector{UInt8}(codeunits(debug_data)) : Vector{UInt8}(debug_data)
        length(bytes) <= 16 * 1024 || throw(ArgumentError("debug_data must be <= 16KB"))
        GC.@preserve bytes begin
            cursor_ref[] = aws_byte_cursor_from_array(pointer(bytes), length(bytes))
        end
        cursor_ptr = cursor_ref
    end
    GC.@preserve bytes cursor_ref begin
        aws_http2_connection_send_goaway(conn, UInt32(http2_error), allow_more_streams, cursor_ptr)
    end
    return
end

http2_send_goaway(client::Client, http2_error::Integer; allow_more_streams::Bool=true, debug_data=nothing) =
    _with_http2_connection(conn -> http2_send_goaway(conn, http2_error; allow_more_streams=allow_more_streams, debug_data=debug_data), client)


function _get_goaway(get_fn, conn::Ptr{aws_http_connection})
    _ensure_http2_connection(conn)
    http2_error = Ref{UInt32}()
    last_stream_id = Ref{UInt32}()
    ret = get_fn(conn, http2_error, last_stream_id)
    if ret == 0
        return (http2_error=http2_error[], last_stream_id=last_stream_id[])
    elseif ret == AWS_ERROR_HTTP_DATA_NOT_AVAILABLE
        return nothing
    else
        aws_throw_error()
    end
end

http2_get_sent_goaway(conn::Ptr{aws_http_connection}) = _get_goaway(aws_http2_connection_get_sent_goaway, conn)
http2_get_received_goaway(conn::Ptr{aws_http_connection}) = _get_goaway(aws_http2_connection_get_received_goaway, conn)

http2_get_sent_goaway(client::Client) = _with_http2_connection(http2_get_sent_goaway, client)

http2_get_received_goaway(client::Client) = _with_http2_connection(http2_get_received_goaway, client)
