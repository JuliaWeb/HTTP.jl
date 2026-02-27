# HTTP/2 Stream Manager - Manages H2 connections with stream multiplexing
# Port of aws-c-http/http2_stream_manager.h, http2_stream_manager.c

# ─── Stream manager state ───

@enumx H2SmState::UInt8 begin
    READY = 0
    DESTROYING = 1
end

# ─── Per-connection state ───

@enumx H2SmConnectionState::UInt8 begin
    IDEAL = 0       # below soft limit
    NEARLY_FULL = 1 # approaching limit
    FULL = 2        # at max concurrent streams
end

const _StreamAcquireResult = Tuple{Any, Int}

# ─── Per-connection wrapper ───

mutable struct H2SmConnection
    connection::Any
    num_streams_assigned::UInt32
    max_concurrent_streams::UInt32  # server-negotiated limit
    state::H2SmConnectionState.T
    stopped_new_requests::Bool
end

function H2SmConnection(connection; max_concurrent_streams::UInt32=UInt32(100))
    return H2SmConnection(
        connection,
        UInt32(0),
        max_concurrent_streams,
        H2SmConnectionState.IDEAL,
        false,
    )
end

# ─── Pending stream acquisition ───

mutable struct H2SmPendingStreamAcquisition
    request_options::Any
    future::EventLoops.Future{_StreamAcquireResult}
    # late-init: starts nothing, assigned during acquisition
    sm_connection::Union{H2SmConnection, Nothing}
end

# ─── Stream manager options ───

struct Http2StreamManagerOptions
    host::String
    port::UInt32
    max_connections::Int
    ideal_concurrent_streams_per_connection::Int
    max_concurrent_streams_per_connection::Int
    close_connection_on_server_error::Bool
    connection_ping_period_ms::UInt64
    connection_ping_timeout_ms::UInt64
    initial_window_size::Csize_t
    manual_window_management::Bool
    http2_prior_knowledge::Bool
    enable_read_back_pressure::Bool
    max_closed_streams::Int
    shutdown_complete_user_data::Any
    shutdown_complete_callback::Any  # (user_data) -> Nothing
    on_connection_setup::Any  # factory: (options) -> connection_or_nothing
end

function Http2StreamManagerOptions(;
    host::String="",
    port::UInt32=UInt32(0),
    max_connections::Int=1,
    ideal_concurrent_streams_per_connection::Int=100,
    max_concurrent_streams_per_connection::Int=0,
    close_connection_on_server_error::Bool=false,
    connection_ping_period_ms::UInt64=UInt64(0),
    connection_ping_timeout_ms::UInt64=UInt64(0),
    initial_window_size::Csize_t=Csize_t(typemax(Csize_t)),
    manual_window_management::Bool=false,
    http2_prior_knowledge::Bool=false,
    enable_read_back_pressure::Bool=false,
    max_closed_streams::Int=0,
    shutdown_complete_user_data=nothing,
    shutdown_complete_callback=nothing,
    on_connection_setup=nothing,
)
    return Http2StreamManagerOptions(
        host,
        port,
        max_connections,
        ideal_concurrent_streams_per_connection,
        max_concurrent_streams_per_connection,
        close_connection_on_server_error,
        connection_ping_period_ms,
        connection_ping_timeout_ms,
        initial_window_size,
        manual_window_management,
        http2_prior_knowledge,
        enable_read_back_pressure,
        max_closed_streams,
        shutdown_complete_user_data,
        shutdown_complete_callback,
        on_connection_setup,
    )
end

# ─── Stream manager ───

mutable struct Http2StreamManager
    is_shut_down::Bool
    state::H2SmState.T
    options::Http2StreamManagerOptions

    # Connection pools
    ideal_available::Vector{H2SmConnection}     # connections below ideal limit
    nonideal_available::Vector{H2SmConnection}  # connections above ideal but below max
    full_connections::Vector{H2SmConnection}    # connections at max

    # Pending stream acquisitions
    pending_acquisitions::Vector{H2SmPendingStreamAcquisition}

    # Internal activity tracking
    connections_acquiring::Int
    open_streams::Int
    pending_make_requests::Int

    function Http2StreamManager(options::Http2StreamManagerOptions)
        return new(
            false,
            H2SmState.READY,
            options,
            H2SmConnection[],
            H2SmConnection[],
            H2SmConnection[],
            H2SmPendingStreamAcquisition[],
            0,
            0,
            0,
        )
    end
end

@inline function _stream_acquire_future()::EventLoops.Future{_StreamAcquireResult}
    return EventLoops.Future{_StreamAcquireResult}()
end

@inline function _complete_stream_acquire!(future::EventLoops.Future{_StreamAcquireResult}, stream, error_code::Int)::Nothing
    notify(future, (stream, error_code))
    return nothing
end

"""
    http2_stream_manager_new(options::Http2StreamManagerOptions) -> Http2StreamManager

Create a new HTTP/2 stream manager.
"""
function http2_stream_manager_new(options::Http2StreamManagerOptions)::Http2StreamManager
    if options.max_connections < 1
        raise_error(ERROR_INVALID_ARGUMENT)
        error("max_connections must be >= 1")
    end
    return Http2StreamManager(options)
end

"""
    Base.close(manager) -> Nothing

Shut down the HTTP/2 stream manager, closing all connections and
failing pending acquisitions. Idempotent and safe to call multiple times.
"""
function Base.close(mgr::Http2StreamManager)::Nothing
    mgr.is_shut_down && return nothing
    mgr.is_shut_down = true
    _h2_stream_manager_shutdown!(mgr)
    return nothing
end

function _h2_stream_manager_shutdown!(mgr::Http2StreamManager)::Nothing
    mgr.state = H2SmState.DESTROYING
    for sm_conn in mgr.ideal_available
        if applicable(http_connection_close, sm_conn.connection)
            http_connection_close(sm_conn.connection)
        end
    end
    for sm_conn in mgr.nonideal_available
        if applicable(http_connection_close, sm_conn.connection)
            http_connection_close(sm_conn.connection)
        end
    end
    for sm_conn in mgr.full_connections
        if applicable(http_connection_close, sm_conn.connection)
            http_connection_close(sm_conn.connection)
        end
    end
    empty!(mgr.ideal_available)
    empty!(mgr.nonideal_available)
    empty!(mgr.full_connections)
    raise_error(ERROR_HTTP_CONNECTION_MANAGER_SHUTTING_DOWN)
    for pending in mgr.pending_acquisitions
        _complete_stream_acquire!(pending.future, nothing, ERROR_HTTP_CONNECTION_MANAGER_SHUTTING_DOWN)
    end
    empty!(mgr.pending_acquisitions)
    mgr.connections_acquiring = 0
    mgr.open_streams = 0
    mgr.pending_make_requests = 0
    if mgr.options.shutdown_complete_callback !== nothing
        mgr.options.shutdown_complete_callback(mgr.options.shutdown_complete_user_data)
    end
    return nothing
end

# ─── Connection state classification ───

function _h2_sm_classify_connection!(mgr::Http2StreamManager, sm_conn::H2SmConnection)::Nothing
    ideal_limit = mgr.options.ideal_concurrent_streams_per_connection
    max_limit = if mgr.options.max_concurrent_streams_per_connection > 0
        min(UInt32(mgr.options.max_concurrent_streams_per_connection), sm_conn.max_concurrent_streams)
    else
        sm_conn.max_concurrent_streams
    end
    _h2_sm_remove_from_pools!(mgr, sm_conn)
    if sm_conn.num_streams_assigned >= max_limit || sm_conn.stopped_new_requests
        sm_conn.state = H2SmConnectionState.FULL
        push!(mgr.full_connections, sm_conn)
    elseif sm_conn.num_streams_assigned >= UInt32(ideal_limit)
        sm_conn.state = H2SmConnectionState.NEARLY_FULL
        push!(mgr.nonideal_available, sm_conn)
    else
        sm_conn.state = H2SmConnectionState.IDEAL
        push!(mgr.ideal_available, sm_conn)
    end
    return nothing
end

function _h2_sm_remove_from_pools!(mgr::Http2StreamManager, sm_conn::H2SmConnection)::Nothing
    filter!(!=(sm_conn), mgr.ideal_available)
    filter!(!=(sm_conn), mgr.nonideal_available)
    filter!(!=(sm_conn), mgr.full_connections)
    return nothing
end

function _h2_sm_total_connections(mgr::Http2StreamManager)::Int
    return (
        length(mgr.ideal_available) +
        length(mgr.nonideal_available) +
        length(mgr.full_connections) +
        mgr.connections_acquiring
    )
end

# ─── Stream acquisition ───

"""
    http2_stream_manager_acquire_stream(manager; options=nothing) -> Future{Tuple{Any, Int}}

Acquire a stream from the stream manager. The future resolves to `(stream, error_code)`.
"""
function http2_stream_manager_acquire_stream(
    mgr::Http2StreamManager;
    options=nothing,
)::EventLoops.Future{_StreamAcquireResult}
    future = _stream_acquire_future()
    if mgr.state != H2SmState.READY
        raise_error(ERROR_HTTP_CONNECTION_MANAGER_SHUTTING_DOWN)
        _complete_stream_acquire!(future, nothing, ERROR_HTTP_CONNECTION_MANAGER_SHUTTING_DOWN)
        return future
    end
    sm_conn = _h2_sm_find_available_connection(mgr)
    if sm_conn !== nothing
        sm_conn.num_streams_assigned += UInt32(1)
        mgr.open_streams += 1
        _h2_sm_classify_connection!(mgr, sm_conn)
        _complete_stream_acquire!(future, sm_conn.connection, OP_SUCCESS)
        return future
    end
    total = _h2_sm_total_connections(mgr)
    if total < mgr.options.max_connections
        mgr.connections_acquiring += 1
        conn = nothing
        if mgr.options.on_connection_setup !== nothing
            try
                conn = mgr.options.on_connection_setup(mgr.options)
            catch
                conn = nothing
            end
        end
        mgr.connections_acquiring -= 1
        if conn !== nothing
            sm_conn = H2SmConnection(conn)
            sm_conn.num_streams_assigned = UInt32(1)
            mgr.open_streams += 1
            _h2_sm_classify_connection!(mgr, sm_conn)
            _complete_stream_acquire!(future, conn, OP_SUCCESS)
        else
            raise_error(ERROR_HTTP_CONNECTION_CLOSED)
            _complete_stream_acquire!(future, nothing, ERROR_HTTP_CONNECTION_CLOSED)
        end
        return future
    end
    push!(mgr.pending_acquisitions, H2SmPendingStreamAcquisition(options, future, nothing))
    return future
end

"""
    http2_stream_manager_acquire_stream!(manager; options=nothing) -> Tuple{Any, Int}

Blocking helper for `http2_stream_manager_acquire_stream`.
"""
function http2_stream_manager_acquire_stream!(mgr::Http2StreamManager; options=nothing)::Tuple{Any, Int}
    return wait(http2_stream_manager_acquire_stream(mgr; options))
end

function _h2_sm_find_available_connection(mgr::Http2StreamManager)::Union{H2SmConnection, Nothing}
    if !isempty(mgr.ideal_available)
        return mgr.ideal_available[end]  # LIFO
    end
    if !isempty(mgr.nonideal_available)
        return mgr.nonideal_available[end]
    end
    return nothing
end

"""
    http2_stream_manager_release_stream(manager, connection) -> Nothing

Release a stream back to the manager (decrement stream count, process pending).
"""
function http2_stream_manager_release_stream(mgr::Http2StreamManager, connection)::Nothing
    sm_conn = _h2_sm_find_by_connection(mgr, connection)
    sm_conn === nothing && return nothing
    if sm_conn.num_streams_assigned > 0
        sm_conn.num_streams_assigned -= UInt32(1)
        mgr.open_streams -= 1
    end
    _h2_sm_classify_connection!(mgr, sm_conn)
    _h2_sm_process_pending!(mgr)
    return nothing
end

function _h2_sm_find_by_connection(mgr::Http2StreamManager, connection)::Union{H2SmConnection, Nothing}
    for sm_conn in mgr.ideal_available
        sm_conn.connection === connection && return sm_conn
    end
    for sm_conn in mgr.nonideal_available
        sm_conn.connection === connection && return sm_conn
    end
    for sm_conn in mgr.full_connections
        sm_conn.connection === connection && return sm_conn
    end
    return nothing
end

function _h2_sm_process_pending!(mgr::Http2StreamManager)::Nothing
    while !isempty(mgr.pending_acquisitions)
        sm_conn = _h2_sm_find_available_connection(mgr)
        sm_conn === nothing && break
        pending = popfirst!(mgr.pending_acquisitions)
        sm_conn.num_streams_assigned += UInt32(1)
        mgr.open_streams += 1
        _h2_sm_classify_connection!(mgr, sm_conn)
        _complete_stream_acquire!(pending.future, sm_conn.connection, OP_SUCCESS)
    end
    return nothing
end

# ─── Close connection on 5xx ───

"""
    http2_stream_manager_on_stream_complete(manager, connection, status_code) -> Nothing

Notify the stream manager that a stream completed. If close_connection_on_server_error
is enabled and status is 5xx, stop new requests on that connection.
"""
function http2_stream_manager_on_stream_complete(mgr::Http2StreamManager, connection, status_code::Int)::Nothing
    if mgr.options.close_connection_on_server_error && 500 <= status_code <= 599
        sm_conn = _h2_sm_find_by_connection(mgr, connection)
        if sm_conn !== nothing
            sm_conn.stopped_new_requests = true
            _h2_sm_classify_connection!(mgr, sm_conn)
        end
    end
    return nothing
end

# ─── Metrics ───

"""
    http2_stream_manager_fetch_metrics(manager) -> HttpManagerMetrics

Get current stream manager metrics.
"""
function http2_stream_manager_fetch_metrics(mgr::Http2StreamManager)::HttpManagerMetrics
    available = 0
    for sm_conn in mgr.ideal_available
        max_per = if mgr.options.max_concurrent_streams_per_connection > 0
            min(UInt32(mgr.options.max_concurrent_streams_per_connection), sm_conn.max_concurrent_streams)
        else
            sm_conn.max_concurrent_streams
        end
        available += Int(max_per - sm_conn.num_streams_assigned)
    end
    for sm_conn in mgr.nonideal_available
        max_per = if mgr.options.max_concurrent_streams_per_connection > 0
            min(UInt32(mgr.options.max_concurrent_streams_per_connection), sm_conn.max_concurrent_streams)
        else
            sm_conn.max_concurrent_streams
        end
        available += Int(max_per - sm_conn.num_streams_assigned)
    end
    return HttpManagerMetrics(
        available,
        length(mgr.pending_acquisitions),
        mgr.open_streams,
    )
end
