# Shared retry bucket primitives used by the higher-level HTTP client retry flow.

import Base: acquire, release
using Dates
using Random

const _RETRY_BUCKET_DEFAULT_BACKOFF_SCALE_FACTOR_MS = 25
const _RETRY_BUCKET_DEFAULT_MAX_BACKOFF_SECS = 20
const _RETRY_BUCKET_DEFAULT_CAPACITY = 500
const _RETRY_BUCKET_ACQUIRE_COST = 10
const _RETRY_BUCKET_RETRYABLE_RESPONSE_COST = 5
const _RETRY_BUCKET_DEFAULT_BACKOFF_SCALE_FACTOR_NS = Int64(_RETRY_BUCKET_DEFAULT_BACKOFF_SCALE_FACTOR_MS) * Int64(1_000_000)
const _RETRY_BUCKET_DEFAULT_MAX_BACKOFF_NS = Int64(_RETRY_BUCKET_DEFAULT_MAX_BACKOFF_SECS) * Int64(1_000_000_000)

"""Retry capacity tracked independently for one retry partition key."""
mutable struct _RetryPartition
    capacity::Int
end

"""
    RetryBucket(; backoff_scale_factor_ms=25, max_backoff_secs=20, capacity=500)

Shared retry-budget bucket keyed by caller-supplied partitions.

Each partition tracks its own remaining capacity. `acquire(bucket, partition)`
reserves retry capacity for one retry attempt, and
`release(bucket, token, failure_cost)` returns all or part of that reserved
capacity. Use `failure_cost = 0` for a full refund, or a positive cost to keep
some or all of the reserved retry capacity consumed.

The built-in client retry flow refunds a reservation in full when the retried
attempt reaches a non-retryable response (the retry did its job), keeps part of
the cost for retryable responses (429/5xx), keeps the full cost when the
retried attempt fails with an exception, and slowly restores consumed capacity
by crediting one unit per successful non-retried request — so a burst of real
failures can drain a partition, but healthy traffic always heals it.
"""
mutable struct RetryBucket
    backoff_scale_factor_ms::Int
    max_backoff_secs::Int
    capacity::Int
    partitions::Dict{String,_RetryPartition}
    lock::ReentrantLock
    # Number of partitions currently below full capacity. Maintained under
    # `lock`; read without it as a fast path so per-request replenish checks
    # stay lock-free while every partition is full.
    @atomic depleted::Int
end

"""Handle returned by `acquire` and consumed by `release` to refund retry budget."""
mutable struct RetryToken
    bucket::RetryBucket
    partition::String
    reserved_capacity::Int
    released::Bool
end

struct RetryDeniedError <: HTTPError
    partition::String
end

struct ErrorResponseStatus <: HTTPError
    status::Int
end

function Base.showerror(io::IO, err::RetryDeniedError)
    return print(io, "retry bucket denied retry capacity for partition ", repr(err.partition))
end

function Base.showerror(io::IO, err::ErrorResponseStatus)
    return print(io, "retryable HTTP response status ", err.status)
end

function RetryBucket(;
    backoff_scale_factor_ms::Integer=_RETRY_BUCKET_DEFAULT_BACKOFF_SCALE_FACTOR_MS,
    max_backoff_secs::Integer=_RETRY_BUCKET_DEFAULT_MAX_BACKOFF_SECS,
    capacity::Integer=_RETRY_BUCKET_DEFAULT_CAPACITY,
)
    backoff_scale_factor_ms >= 0 || throw(ArgumentError("backoff_scale_factor_ms must be >= 0"))
    max_backoff_secs >= 0 || throw(ArgumentError("max_backoff_secs must be >= 0"))
    capacity > 0 || throw(ArgumentError("capacity must be > 0"))
    return RetryBucket(
        Int(backoff_scale_factor_ms),
        Int(max_backoff_secs),
        Int(capacity),
        Dict{String,_RetryPartition}(),
        ReentrantLock(),
        0,
    )
end

# Set a partition's capacity while keeping the bucket's depleted-partition
# count in sync. Must be called with `bucket.lock` held.
@inline function _retry_partition_set_capacity!(bucket::RetryBucket, state::_RetryPartition, new_capacity::Int)::Nothing
    was_full = state.capacity >= bucket.capacity
    now_full = new_capacity >= bucket.capacity
    state.capacity = new_capacity
    if was_full && !now_full
        @atomic bucket.depleted += 1
    elseif !was_full && now_full
        @atomic bucket.depleted -= 1
    end
    return nothing
end

@inline function _retry_bucket_partition_key(partition)::String
    partition === nothing && throw(ArgumentError("retry bucket partition is required"))
    key = lowercase(String(partition))
    isempty(key) && throw(ArgumentError("retry bucket partition must not be empty"))
    return key
end

function _retry_bucket_partition!(bucket::RetryBucket, partition_key::String)::_RetryPartition
    return Base.get!(bucket.partitions, partition_key) do
        _RetryPartition(bucket.capacity)
    end
end

function acquire(bucket::RetryBucket, partition)
    partition_key = _retry_bucket_partition_key(partition)
    return lock(bucket.lock) do
        state = _retry_bucket_partition!(bucket, partition_key)
        if state.capacity < _RETRY_BUCKET_ACQUIRE_COST
            throw(RetryDeniedError(partition_key))
        end
        _retry_partition_set_capacity!(bucket, state, state.capacity - _RETRY_BUCKET_ACQUIRE_COST)
        return RetryToken(bucket, partition_key, _RETRY_BUCKET_ACQUIRE_COST, false)
    end
end

@inline function _retry_bucket_reserved_cost(token::RetryToken)::Int
    return min(token.reserved_capacity, _RETRY_BUCKET_ACQUIRE_COST)
end

# Cost to keep from a retry reservation given the retried attempt's response
# status. A non-retryable status means the retry did its job (the request
# completed, whatever the outcome), so the reservation is refunded in full;
# charging successes would make the budget a strictly-decreasing resource that
# eventually denies every retry for the transport's lifetime (#1353).
@inline function _retry_bucket_failure_cost(status::Union{Nothing,Int})::Int
    status === nothing && return 0
    return _retryable_status(status) ? _RETRY_BUCKET_RETRYABLE_RESPONSE_COST : 0
end

@inline function release(bucket::RetryBucket, token::RetryToken, failure_cost::Int)::Nothing
    token.bucket === bucket || throw(ArgumentError("retry token does not belong to the provided retry bucket"))
    lock(bucket.lock)
    try
        token.released && return nothing
        state = _retry_bucket_partition!(bucket, token.partition)
        reserved = _retry_bucket_reserved_cost(token)
        consumed = min(reserved, max(0, failure_cost))
        refund = reserved - consumed
        _retry_partition_set_capacity!(bucket, state, min(bucket.capacity, state.capacity + refund))
        token.released = true
        return nothing
    finally
        unlock(bucket.lock)
    end
end

"""
    _retry_bucket_replenish!(bucket, partition)

Credit one unit of retry capacity back to `partition` after a successful
non-retried request, capped at the bucket's full capacity. This is the slow
recovery path that lets a partition legitimately drained by a burst of real
failures regain retry budget from healthy traffic instead of staying empty for
the transport's lifetime. Partitions that have never spent capacity are left
untouched, and the depleted-partition fast path keeps this lock-free while
every partition is full.
"""
function _retry_bucket_replenish!(bucket::RetryBucket, partition)::Nothing
    (@atomic :monotonic bucket.depleted) == 0 && return nothing
    partition_key = _retry_bucket_partition_key(partition)
    lock(bucket.lock)
    try
        state = get(() -> nothing, bucket.partitions, partition_key)
        state === nothing && return nothing
        partition_state = state::_RetryPartition
        partition_state.capacity >= bucket.capacity && return nothing
        _retry_partition_set_capacity!(bucket, partition_state, partition_state.capacity + 1)
        return nothing
    finally
        unlock(bucket.lock)
    end
end

@inline function _retry_bucket_max_backoff_ns(bucket::RetryBucket)::Int64
    max_secs = max(0, bucket.max_backoff_secs)
    max_secs > typemax(Int64) ÷ 1_000_000_000 && return typemax(Int64)
    return Int64(max_secs) * Int64(1_000_000_000)
end

@inline function _retry_bucket_backoff_scale_ns(bucket::RetryBucket)::Int64
    scale_ms = max(0, bucket.backoff_scale_factor_ms)
    scale_ms > typemax(Int64) ÷ 1_000_000 && return typemax(Int64)
    return Int64(scale_ms) * Int64(1_000_000)
end

@inline function _retry_backoff_cap_ns(bucket::Union{Nothing,RetryBucket}, attempt::Int)::Int64
    attempt <= 0 && return Int64(0)
    max_backoff_ns = bucket === nothing ? _RETRY_BUCKET_DEFAULT_MAX_BACKOFF_NS : _retry_bucket_max_backoff_ns(bucket::RetryBucket)
    scale_ns = bucket === nothing ? _RETRY_BUCKET_DEFAULT_BACKOFF_SCALE_FACTOR_NS : _retry_bucket_backoff_scale_ns(bucket::RetryBucket)
    scale_ns == 0 && return Int64(0)
    shift = min(attempt - 1, 62)
    backoff = Int128(scale_ns) * (Int128(1) << shift)
    cap_ns = min(backoff, Int128(max_backoff_ns))
    return Int64(max(cap_ns, Int128(0)))
end

function _retry_delay_ns(
    bucket::Union{Nothing,RetryBucket},
    attempt::Int,
    retry_after_ns::Union{Nothing,Int64}=nothing,
)::Int64
    cap_ns = _retry_backoff_cap_ns(bucket, attempt)
    if retry_after_ns !== nothing
        max_backoff_ns = bucket === nothing ? _RETRY_BUCKET_DEFAULT_MAX_BACKOFF_NS : _retry_bucket_max_backoff_ns(bucket::RetryBucket)
        return min(max(Int64(0), retry_after_ns::Int64), max_backoff_ns)
    end
    cap_ns <= 0 && return Int64(0)
    return Random.rand(Int64(0):cap_ns)
end

function _retry_after_delay_ns(headers::Headers)::Union{Nothing,Int64}
    value = header(headers, "Retry-After", nothing)
    value === nothing && return nothing
    return _parse_retry_after_delay_ns(value::String)
end

function _parse_retry_after_delay_ns(
    value::AbstractString;
    now::Dates.DateTime=Dates.now(Dates.UTC),
)::Union{Nothing,Int64}
    stripped = strip(String(value))
    isempty(stripped) && return nothing
    parsed_secs = try
        parse(Int, stripped)
    catch
        nothing
    end
    if parsed_secs !== nothing
        secs = parsed_secs::Int
        secs < 0 && return nothing
        secs > typemax(Int64) ÷ 1_000_000_000 && return typemax(Int64)
        return Int64(secs) * Int64(1_000_000_000)
    end
    parsed_dt = Cookies._parse_http_gmt_datetime(stripped)
    parsed_dt === nothing && return nothing
    delta = parsed_dt::Dates.DateTime - now
    millis = Dates.value(delta)
    millis <= 0 && return Int64(0)
    millis > typemax(Int64) ÷ 1_000_000 && return typemax(Int64)
    return Int64(millis) * Int64(1_000_000)
end
