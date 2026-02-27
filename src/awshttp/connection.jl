# HTTP Connection - Base connection types and public API
# Port of aws-c-http/source/connection.c, connection_impl.h, connection.h

# ─── Connection monitoring options ───

struct HttpConnectionMonitoringOptions
    minimum_throughput_bytes_per_second::UInt64
    allowable_throughput_failure_interval_seconds::UInt32
end

# ─── HTTP/1 connection options ───

struct Http1ConnectionOptions
    read_buffer_capacity::Csize_t  # 0 = default
end

Http1ConnectionOptions() = Http1ConnectionOptions(Csize_t(0))

# ─── Shared connection abstraction ───

abstract type HttpConnection end

# ─── Client connection options ───

Base.@kwdef struct HttpClientConnectionOptions
    # ── Networking ──
    bootstrap::Union{EventLoops.EventLoopGroup, Nothing} = nothing
    socket_options::Union{Sockets.SocketOptions, Nothing} = nothing
    tls_connection_options::Union{Sockets.TlsConnectionOptions, Nothing} = nothing
    # ── Host/port ──
    host_name::String
    port::UInt32
    # ── ALPN/Version ──
    alpn_string_map::Union{HttpAlpnMap, Nothing} = nothing  # ALPN protocol → HttpVersion map
    prior_knowledge_http2::Bool = false  # skip ALPN, assume HTTP/2
    h2c_upgrade::Bool = false  # attempt HTTP/2 cleartext upgrade via Upgrade: h2c
    # ── Window management ──
    manual_window_management::Bool = false
    initial_window_size::Csize_t = Csize_t(typemax(Csize_t))
    # ── Timeouts ──
    response_first_byte_timeout_ms::UInt64 = UInt64(0)
    # ── Protocol-specific options ──
    http1_options::Http1ConnectionOptions = Http1ConnectionOptions()
    # ── Advanced ──
    requested_event_loop::Union{EventLoops.EventLoop, Nothing} = nothing
end

function _dispatch_user_callback(f, args...; subject::LogSubject = LS_HTTP_CONNECTION, label::AbstractString = "callback")
    f === nothing && return nothing
    Reseau.logf(Reseau.LogLevel.TRACE, subject, "HTTP user $(label) dispatching")
    errormonitor(Threads.@spawn begin
        try
            Reseau.logf(Reseau.LogLevel.TRACE, subject, "HTTP user $(label) starting")
            f(args...)
        catch err
            Reseau.logf(
                Reseau.LogLevel.ERROR,
                subject,
                "HTTP user $(label) threw: $(sprint(showerror, err, catch_backtrace()))",
            )
        end
    end)
    return nothing
end

function http_client_connect_sync(
    options::HttpClientConnectionOptions;
    on_setup=nothing,
    on_shutdown=nothing,
)::Tuple{Union{HttpConnection, Nothing}, Int}
    result = Base.Channel{Tuple{Union{HttpConnection, Nothing}, Int}}(1)
    sync_on_setup = function (connection, error_code)
        on_setup === nothing || _dispatch_user_callback(on_setup, connection, error_code; label="on_setup")
        put!(result, (error_code == OP_SUCCESS ? connection : nothing, error_code))
        return nothing
    end
    http_client_connect(options; on_setup=sync_on_setup, on_shutdown=on_shutdown)
    return take!(result)
end

# ─── Abstract connection interface ───
# Concrete connections (H1Connection, H2Connection) implement these functions via dispatch.

"""
    http_connection_close(connection) -> Nothing

Begin graceful shutdown of the connection.
"""
function http_connection_close end

"""
    http_connection_is_open(connection) -> Bool

Return whether the connection is still open.
"""
function http_connection_is_open end

"""
    http_connection_new_requests_allowed(connection) -> Bool

Return whether new requests can be created on this connection.
"""
function http_connection_new_requests_allowed end

"""
    http_connection_is_client(connection) -> Bool

Return whether this connection is in client mode.
"""
function http_connection_is_client end

"""
    http_connection_get_version(connection) -> HttpVersion.T

Return the HTTP version of this connection.
"""
function http_connection_get_version end

"""
    http_connection_make_request(connection; kwargs...) -> H1Stream

Create a new client request stream on this connection.
"""
function http_connection_make_request end

"""
    http_connection_stop_new_requests(connection) -> Nothing

Stop accepting new requests on this connection.
"""
function http_connection_stop_new_requests end

"""
    http_connection_new_request_handler(connection; kwargs...) -> H1Stream

Create a new server request handler stream on this connection (server only).
"""
function http_connection_new_request_handler end

"""
    http_connection_get_remote_endpoint(connection) -> String

Return the remote endpoint string (host:port or empty).
"""
function http_connection_get_remote_endpoint end

"""
    http_connection_has_switched_protocols(connection) -> Bool

Return whether the connection has completed a 101 Switching Protocols exchange.
"""
function http_connection_has_switched_protocols end

"""
    http_connection_get_channel(connection) -> Union{Channel, Nothing}

Return the channel associated with this connection, or nothing if not yet installed.
"""
function http_connection_get_channel end

function _http_version_from_alpn_protocol(protocol::Reseau.ByteBuffer, alpn_map::Union{HttpAlpnMap, Nothing})::HttpVersion.T
    protocol.len == 0 && return HttpVersion.HTTP_1_1
    return _http_version_from_alpn_string(Reseau.byte_buffer_as_string(protocol), alpn_map)
end

function _http_version_from_alpn_string(protocol_str::AbstractString, alpn_map::Union{HttpAlpnMap, Nothing})::HttpVersion.T
    if alpn_map !== nothing
        version = http_alpn_map_get(alpn_map, protocol_str)
        if version == HttpVersion.UNKNOWN
            Reseau.logf(
                Reseau.LogLevel.ERROR,
                LS_HTTP_CONNECTION,
                "Customized ALPN protocol $(protocol_str) used. However it is not found in the ALPN map provided.",
            )
        else
            Reseau.logf(
                Reseau.LogLevel.DEBUG,
                LS_HTTP_CONNECTION,
                "Customized ALPN protocol $(protocol_str) used. $(http_version_to_str(version)) connection established.",
            )
        end
        return version
    end
    if protocol_str == "http/1.1"
        return HttpVersion.HTTP_1_1
    elseif protocol_str == "h2"
        return HttpVersion.HTTP_2
    end
    Reseau.logf(Reseau.LogLevel.WARN, LS_HTTP_CONNECTION, "Unrecognized ALPN protocol. Assuming HTTP/1.1")
    Reseau.logf(Reseau.LogLevel.DEBUG, LS_HTTP_CONNECTION, "Unrecognized ALPN protocol $(protocol_str)")
    return HttpVersion.HTTP_1_1
end

function _http_select_version(
        channel::Sockets.Channel,
        is_using_tls::Bool,
        prior_knowledge_http2::Bool,
        alpn_map::Union{HttpAlpnMap, Nothing},
        negotiated_protocol::Union{String, Nothing} = nothing,
    )
    version = HttpVersion.HTTP_1_1
    if is_using_tls
        if negotiated_protocol !== nothing && !isempty(negotiated_protocol)
            version = _http_version_from_alpn_string(negotiated_protocol, alpn_map)
        elseif channel.socket !== nothing
            protocol = Sockets.socket_get_protocol(channel.socket)
            if protocol.len > 0
                version = _http_version_from_alpn_protocol(protocol, alpn_map)
            end
        end
    elseif prior_knowledge_http2
        Reseau.logf(Reseau.LogLevel.TRACE, LS_HTTP_CONNECTION, "Using prior knowledge to start HTTP/2 connection")
        version = HttpVersion.HTTP_2
    end
    return version
end
