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
const _ConnectionAcquireResult = Tuple{Any, Int}

# ─── Idle connection wrapper ───

mutable struct IdleConnection
    connection::Any
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

# ─── Connection manager options ───

struct HttpConnectionManagerOptions
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
    shutdown_complete_user_data::Any
    shutdown_complete_callback::Any  # (user_data) -> Nothing
    on_connection_setup::Any  # factory: (options) -> connection_or_nothing
end

function HttpConnectionManagerOptions(;
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
    shutdown_complete_user_data=nothing,
    shutdown_complete_callback=nothing,
    on_connection_setup=nothing,
)
    return HttpConnectionManagerOptions(
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
        shutdown_complete_user_data,
        shutdown_complete_callback,
        on_connection_setup,
    )
end

# ─── Connection manager ───

mutable struct HttpConnectionManager
    is_shut_down::Bool
    state::HttpConnectionManagerState.T
    options::HttpConnectionManagerOptions

    # Connection pools
    idle_connections::Vector{IdleConnection}   # LIFO: push!/pop! from end
    pending_acquisitions::Vector{PendingAcquisition}  # FIFO: push!/popfirst!

    # Internal reference tracking
    internal_ref::Vector{Int}  # indexed by HCMCT_COUNT

    # Total open connections (idle + vended + connecting)
    function HttpConnectionManager(options::HttpConnectionManagerOptions)
        return new(
            false,
            HttpConnectionManagerState.READY,
            options,
            IdleConnection[],
            PendingAcquisition[],
            zeros(Int, HCMCT_COUNT),
        )
    end
end

@inline function _connection_acquire_future()::EventLoops.Future{_ConnectionAcquireResult}
    return EventLoops.Future{_ConnectionAcquireResult}()
end

@inline function _complete_acquire!(future::EventLoops.Future{_ConnectionAcquireResult}, connection, error_code::Int)::Nothing
    notify(future, (connection, error_code))
    return nothing
end

"""
    http_connection_manager_new(options::HttpConnectionManagerOptions) -> HttpConnectionManager

Create a new connection manager with the given options.
"""
function http_connection_manager_new(options::HttpConnectionManagerOptions)::HttpConnectionManager
    if options.max_connections < 1
        raise_error(ERROR_INVALID_ARGUMENT)
        error("max_connections must be >= 1")
    end
    return HttpConnectionManager(options)
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
        if applicable(http_connection_close, idle.connection)
            http_connection_close(idle.connection)
        end
    end
    empty!(mgr.idle_connections)
    raise_error(ERROR_HTTP_CONNECTION_MANAGER_SHUTTING_DOWN)
    for pending in mgr.pending_acquisitions
        _complete_acquire!(pending.future, nothing, ERROR_HTTP_CONNECTION_MANAGER_SHUTTING_DOWN)
    end
    empty!(mgr.pending_acquisitions)
    fill!(mgr.internal_ref, 0)
    if mgr.options.shutdown_complete_callback !== nothing
        mgr.options.shutdown_complete_callback(mgr.options.shutdown_complete_user_data)
    end
    return nothing
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
    idle_timeout_ms = mgr.options.max_connection_idle_in_milliseconds
    idle_timeout_ms == 0 && return nothing
    now_ns = Reseau.monotonic_time_ns()
    while !isempty(mgr.idle_connections)
        oldest = mgr.idle_connections[1]  # front = oldest
        if now_ns >= oldest.cull_timestamp_ns
            popfirst!(mgr.idle_connections)
            mgr.internal_ref[Int(HttpConnectionManagerCountType.OPEN_CONNECTION) + 1] -= 1
            if applicable(http_connection_close, oldest.connection)
                http_connection_close(oldest.connection)
            end
        else
            break
        end
    end
    return nothing
end

# ─── Pending acquisition culling ───

function _connection_manager_cull_pending!(mgr::HttpConnectionManager)::Nothing
    timeout_ms = mgr.options.connection_acquisition_timeout_ms
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
    http_connection_manager_acquire_connection(manager) -> Future{Tuple{Any, Int}}

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
    max_pending = mgr.options.max_pending_connection_acquisitions
    if max_pending > 0 && length(mgr.pending_acquisitions) >= max_pending
        raise_error(ERROR_HTTP_CONNECTION_MANAGER_MAX_PENDING_ACQUISITIONS_EXCEEDED)
        _complete_acquire!(future, nothing, ERROR_HTTP_CONNECTION_MANAGER_MAX_PENDING_ACQUISITIONS_EXCEEDED)
        return future
    end
    _connection_manager_cull_idle!(mgr)
    while !isempty(mgr.idle_connections)
        idle = pop!(mgr.idle_connections)
        is_usable = true
        if applicable(http_connection_is_open, idle.connection)
            is_usable = http_connection_is_open(idle.connection)
        end
        if !is_usable
            mgr.internal_ref[Int(HttpConnectionManagerCountType.OPEN_CONNECTION) + 1] -= 1
            if applicable(http_connection_close, idle.connection)
                http_connection_close(idle.connection)
            end
            continue
        end
        mgr.internal_ref[Int(HttpConnectionManagerCountType.VENDED_CONNECTION) + 1] += 1
        _complete_acquire!(future, idle.connection, OP_SUCCESS)
        return future
    end
    total = _connection_manager_total_connections(mgr)
    if total < mgr.options.max_connections
        mgr.internal_ref[Int(HttpConnectionManagerCountType.PENDING_CONNECTIONS) + 1] += 1
        conn = nothing
        err = OP_SUCCESS
        if mgr.options.on_connection_setup !== nothing
            try
                conn = mgr.options.on_connection_setup(mgr.options)
            catch
                raise_error(ERROR_HTTP_CONNECTION_CLOSED)
                err = ERROR_HTTP_CONNECTION_CLOSED
            end
        end
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
    http_connection_manager_acquire_connection!(manager) -> Tuple{Any, Int}

Blocking helper for `http_connection_manager_acquire_connection`.
"""
function http_connection_manager_acquire_connection!(mgr::HttpConnectionManager)::Tuple{Any, Int}
    return wait(http_connection_manager_acquire_connection(mgr))
end

"""
    http_connection_manager_release_connection(manager, connection) -> Int

Return a connection to the pool for reuse. If there are pending acquisitions,
the connection is handed to the next waiter instead.
"""
function http_connection_manager_release_connection(mgr::HttpConnectionManager, connection)::Int
    _connection_manager_cull_pending!(mgr)
    vended_idx = Int(HttpConnectionManagerCountType.VENDED_CONNECTION) + 1
    if mgr.internal_ref[vended_idx] <= 0
        return raise_error(ERROR_INVALID_STATE)
    end
    mgr.internal_ref[vended_idx] -= 1
    is_usable = true
    if applicable(http_connection_is_open, connection)
        is_usable = http_connection_is_open(connection)
    end
    if !is_usable || mgr.state == HttpConnectionManagerState.SHUTTING_DOWN
        mgr.internal_ref[Int(HttpConnectionManagerCountType.OPEN_CONNECTION) + 1] -= 1
        if applicable(http_connection_close, connection)
            http_connection_close(connection)
        end
        return OP_SUCCESS
    end
    if !isempty(mgr.pending_acquisitions)
        pending = popfirst!(mgr.pending_acquisitions)
        mgr.internal_ref[vended_idx] += 1
        _complete_acquire!(pending.future, connection, OP_SUCCESS)
        return OP_SUCCESS
    end
    cull_ns = if mgr.options.max_connection_idle_in_milliseconds > 0
        Reseau.monotonic_time_ns() + mgr.options.max_connection_idle_in_milliseconds * 1_000_000
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
