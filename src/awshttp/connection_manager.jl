# HTTP Connection Manager - Connection pool with acquire/release
# Port of aws-c-http/include/aws/http/connection_manager.h, source/connection_manager.c

# ─── Manager state machine ───

@enumx HttpConnectionManagerState::UInt8 begin
    UNINITIALIZED = 0
    READY = 1
    SHUTTING_DOWN = 2
end

# ─── Internal count types ───

@enumx HttpConnectionManagerCountType::UInt8 begin
    VENDED_CONNECTION = 0
    PENDING_CONNECTIONS = 1
    OPEN_CONNECTION = 2
end

const HCMCT_COUNT = 3
const _ManagedConnection = Union{H1Connection, H2Connection}
const _ConnectionAcquireResult = Tuple{Union{_ManagedConnection, Nothing}, Int}

# ─── Idle connection wrapper ───

mutable struct IdleConnection
    connection::_ManagedConnection
    cull_timestamp_ns::UInt64  # monotonic_time_ns() when this becomes eligible for culling
end

# ─── Pending acquisition ───

mutable struct PendingAcquisition
    future::EventLoops.Future{_ConnectionAcquireResult}
    timestamp_ns::UInt64  # when the request was made
end

# ─── Manager metrics ───

struct HttpManagerMetrics
    available_concurrency::Int
    pending_concurrency_acquires::Int
    leased_concurrency::Int
end

# ─── Connection manager ───

mutable struct HttpConnectionManager
    is_shut_down::Bool
    state::HttpConnectionManagerState.T
    host::String
    port::UInt32
    max_connections::Int
    initial_window_size::Csize_t
    manual_window_management::Bool
    http2_prior_knowledge::Bool
    enable_read_back_pressure::Bool
    max_connection_idle_in_milliseconds::UInt64
    connection_acquisition_timeout_ms::UInt64
    max_pending_connection_acquisitions::Int
    response_first_byte_timeout_ms::UInt64
    max_closed_streams::Int
    http2_conn_manual_window_management::Bool
    connection_options::Union{HttpClientConnectionOptions, Nothing}

    # Connection pools
    idle_connections::Vector{IdleConnection}   # LIFO: push!/pop! from end
    pending_acquisitions::Vector{PendingAcquisition}  # FIFO: push!/popfirst!

    # Internal reference tracking
    internal_ref::Vector{Int}  # indexed by HCMCT_COUNT

end

@inline function _connection_acquire_future()::EventLoops.Future{_ConnectionAcquireResult}
    return EventLoops.Future{_ConnectionAcquireResult}()
end

@inline function _complete_acquire!(
    future::EventLoops.Future{_ConnectionAcquireResult},
    connection::Union{_ManagedConnection, Nothing},
    error_code::Int,
)::Nothing
    notify(future, (connection, error_code))
    return nothing
end

"""
    http_connection_manager_new(; kwargs...) -> HttpConnectionManager

Create a new connection manager with the given configuration.
"""
function http_connection_manager_new(;
    host::String="",
    port::UInt32=UInt32(0),
    max_connections::Int=1,
    initial_window_size::Csize_t=Csize_t(typemax(Csize_t)),
    manual_window_management::Bool=false,
    http2_prior_knowledge::Bool=false,
    enable_read_back_pressure::Bool=false,
    max_connection_idle_in_milliseconds::UInt64=UInt64(0),
    connection_acquisition_timeout_ms::UInt64=UInt64(0),
    max_pending_connection_acquisitions::Int=0,
    response_first_byte_timeout_ms::UInt64=UInt64(0),
    max_closed_streams::Int=0,
    http2_conn_manual_window_management::Bool=false,
    connection_options::Union{HttpClientConnectionOptions, Nothing}=nothing,
)::HttpConnectionManager
    if max_connections < 1
        raise_error(ERROR_INVALID_ARGUMENT)
        error("max_connections must be >= 1")
    end
    return HttpConnectionManager(
        false,
        HttpConnectionManagerState.READY,
        host,
        port,
        max_connections,
        initial_window_size,
        manual_window_management,
        http2_prior_knowledge,
        enable_read_back_pressure,
        max_connection_idle_in_milliseconds,
        connection_acquisition_timeout_ms,
        max_pending_connection_acquisitions,
        response_first_byte_timeout_ms,
        max_closed_streams,
        http2_conn_manual_window_management,
        connection_options,
        IdleConnection[],
        PendingAcquisition[],
        zeros(Int, HCMCT_COUNT),
    )
end

"""
    Base.close(manager) -> Nothing

Shut down the connection manager, closing all idle connections and
failing pending acquisitions. Idempotent and safe to call multiple times.
"""
function Base.close(mgr::HttpConnectionManager)::Nothing
    mgr.is_shut_down && return nothing
    mgr.is_shut_down = true
    _connection_manager_shutdown!(mgr)
    return nothing
end

function _connection_manager_shutdown!(mgr::HttpConnectionManager)::Nothing
    mgr.state = HttpConnectionManagerState.SHUTTING_DOWN
    for idle in mgr.idle_connections
        http_connection_close(idle.connection)
    end
    empty!(mgr.idle_connections)
    raise_error(ERROR_HTTP_CONNECTION_MANAGER_SHUTTING_DOWN)
    for pending in mgr.pending_acquisitions
        _complete_acquire!(pending.future, nothing, ERROR_HTTP_CONNECTION_MANAGER_SHUTTING_DOWN)
    end
    empty!(mgr.pending_acquisitions)
    fill!(mgr.internal_ref, 0)
    return nothing
end

function _connection_manager_connect_options(mgr::HttpConnectionManager)::HttpClientConnectionOptions
    conn_opts = mgr.connection_options
    conn_opts !== nothing && return conn_opts
    return HttpClientConnectionOptions(
        host_name=mgr.host,
        port=mgr.port,
        prior_knowledge_http2=mgr.http2_prior_knowledge,
        manual_window_management=mgr.http2_conn_manual_window_management,
        initial_window_size=mgr.initial_window_size,
        response_first_byte_timeout_ms=mgr.response_first_byte_timeout_ms,
    )
end

function _connection_manager_connect(mgr::HttpConnectionManager)::Tuple{Union{_ManagedConnection, Nothing}, Int}
    return http_client_connect_sync(_connection_manager_connect_options(mgr))
end

# ─── Connection total helpers ───

function _connection_manager_total_connections(mgr::HttpConnectionManager)::Int
    return (
        mgr.internal_ref[Int(HttpConnectionManagerCountType.VENDED_CONNECTION) + 1] +
        mgr.internal_ref[Int(HttpConnectionManagerCountType.PENDING_CONNECTIONS) + 1] +
        length(mgr.idle_connections)
    )
end

# ─── Idle connection culling ───

function _connection_manager_cull_idle!(mgr::HttpConnectionManager)::Nothing
    idle_timeout_ms = mgr.max_connection_idle_in_milliseconds
    idle_timeout_ms == 0 && return nothing
    now_ns = Reseau.monotonic_time_ns()
    while !isempty(mgr.idle_connections)
        oldest = mgr.idle_connections[1]  # front = oldest
        if now_ns >= oldest.cull_timestamp_ns
            popfirst!(mgr.idle_connections)
            mgr.internal_ref[Int(HttpConnectionManagerCountType.OPEN_CONNECTION) + 1] -= 1
            http_connection_close(oldest.connection)
        else
            break
        end
    end
    return nothing
end

# ─── Pending acquisition culling ───

function _connection_manager_cull_pending!(mgr::HttpConnectionManager)::Nothing
    timeout_ms = mgr.connection_acquisition_timeout_ms
    timeout_ms == 0 && return nothing
    now_ns = Reseau.monotonic_time_ns()
    timeout_ns = timeout_ms * 1_000_000
    i = 1
    while i <= length(mgr.pending_acquisitions)
        pending = mgr.pending_acquisitions[i]
        if now_ns >= pending.timestamp_ns + timeout_ns
            deleteat!(mgr.pending_acquisitions, i)
            raise_error(ERROR_HTTP_CONNECTION_MANAGER_ACQUISITION_TIMEOUT)
            _complete_acquire!(pending.future, nothing, ERROR_HTTP_CONNECTION_MANAGER_ACQUISITION_TIMEOUT)
        else
            i += 1
        end
    end
    return nothing
end

# ─── Acquire connection ───

"""
    http_connection_manager_acquire_connection(manager) -> Future{Tuple{Union{HttpConnection, Nothing}, Int}}

Acquire a connection from the pool. The future resolves to `(connection, error_code)`.
If no idle connection is available, the request is queued.
"""
function http_connection_manager_acquire_connection(mgr::HttpConnectionManager)::EventLoops.Future{_ConnectionAcquireResult}
    future = _connection_acquire_future()
    if mgr.state != HttpConnectionManagerState.READY
        raise_error(ERROR_INVALID_STATE)
        _complete_acquire!(future, nothing, ERROR_INVALID_STATE)
        return future
    end
    _connection_manager_cull_pending!(mgr)
    max_pending = mgr.max_pending_connection_acquisitions
    if max_pending > 0 && length(mgr.pending_acquisitions) >= max_pending
        raise_error(ERROR_HTTP_CONNECTION_MANAGER_MAX_PENDING_ACQUISITIONS_EXCEEDED)
        _complete_acquire!(future, nothing, ERROR_HTTP_CONNECTION_MANAGER_MAX_PENDING_ACQUISITIONS_EXCEEDED)
        return future
    end
    _connection_manager_cull_idle!(mgr)
    while !isempty(mgr.idle_connections)
        idle = pop!(mgr.idle_connections)
        is_usable = true
        is_usable = http_connection_is_open(idle.connection)
        if !is_usable
            mgr.internal_ref[Int(HttpConnectionManagerCountType.OPEN_CONNECTION) + 1] -= 1
            http_connection_close(idle.connection)
            continue
        end
        mgr.internal_ref[Int(HttpConnectionManagerCountType.VENDED_CONNECTION) + 1] += 1
        _complete_acquire!(future, idle.connection, OP_SUCCESS)
        return future
    end
    total = _connection_manager_total_connections(mgr)
    if total < mgr.max_connections
        mgr.internal_ref[Int(HttpConnectionManagerCountType.PENDING_CONNECTIONS) + 1] += 1
        conn, err = _connection_manager_connect(mgr)
        if conn === nothing && err == OP_SUCCESS
            raise_error(ERROR_HTTP_CONNECTION_CLOSED)
            err = ERROR_HTTP_CONNECTION_CLOSED
        end
        mgr.internal_ref[Int(HttpConnectionManagerCountType.PENDING_CONNECTIONS) + 1] -= 1
        if conn !== nothing
            mgr.internal_ref[Int(HttpConnectionManagerCountType.VENDED_CONNECTION) + 1] += 1
            mgr.internal_ref[Int(HttpConnectionManagerCountType.OPEN_CONNECTION) + 1] += 1
            _complete_acquire!(future, conn, OP_SUCCESS)
        else
            _complete_acquire!(future, nothing, err)
        end
        return future
    end
    push!(mgr.pending_acquisitions, PendingAcquisition(future, Reseau.monotonic_time_ns()))
    return future
end

"""
    http_connection_manager_acquire_connection!(manager) -> Tuple{Union{H1Connection, H2Connection, Nothing}, Int}

Blocking helper for `http_connection_manager_acquire_connection`.
"""
function http_connection_manager_acquire_connection!(mgr::HttpConnectionManager)::Tuple{Union{_ManagedConnection, Nothing}, Int}
    return wait(http_connection_manager_acquire_connection(mgr))
end

"""
    http_connection_manager_release_connection(manager, connection) -> Int

Return a connection to the pool for reuse. If there are pending acquisitions,
the connection is handed to the next waiter instead.
"""
function http_connection_manager_release_connection(mgr::HttpConnectionManager, connection::_ManagedConnection)::Int
    _connection_manager_cull_pending!(mgr)
    vended_idx = Int(HttpConnectionManagerCountType.VENDED_CONNECTION) + 1
    if mgr.internal_ref[vended_idx] <= 0
        return raise_error(ERROR_INVALID_STATE)
    end
    mgr.internal_ref[vended_idx] -= 1
    is_usable = true
    is_usable = http_connection_is_open(connection)
    if !is_usable || mgr.state == HttpConnectionManagerState.SHUTTING_DOWN
        mgr.internal_ref[Int(HttpConnectionManagerCountType.OPEN_CONNECTION) + 1] -= 1
        http_connection_close(connection)
        return OP_SUCCESS
    end
    if !isempty(mgr.pending_acquisitions)
        pending = popfirst!(mgr.pending_acquisitions)
        mgr.internal_ref[vended_idx] += 1
        _complete_acquire!(pending.future, connection, OP_SUCCESS)
        return OP_SUCCESS
    end
    cull_ns = if mgr.max_connection_idle_in_milliseconds > 0
        Reseau.monotonic_time_ns() + mgr.max_connection_idle_in_milliseconds * 1_000_000
    else
        typemax(UInt64)
    end
    push!(mgr.idle_connections, IdleConnection(connection, cull_ns))
    return OP_SUCCESS
end

# ─── Metrics ───

"""
    http_connection_manager_fetch_metrics(manager) -> HttpManagerMetrics

Get current pool metrics.
"""
function http_connection_manager_fetch_metrics(mgr::HttpConnectionManager)::HttpManagerMetrics
    _connection_manager_cull_pending!(mgr)
    return HttpManagerMetrics(
        length(mgr.idle_connections),
        length(mgr.pending_acquisitions),
        mgr.internal_ref[Int(HttpConnectionManagerCountType.VENDED_CONNECTION) + 1],
    )
end
