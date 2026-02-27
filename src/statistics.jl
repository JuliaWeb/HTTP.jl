export AWSCRT_STAT_CAT_HTTP1_CHANNEL, AWSCRT_STAT_CAT_HTTP2_CHANNEL
export aws_crt_statistics_http1_channel, aws_crt_statistics_http2_channel
export _decode_statistics, _call_statistics_observer

const AWSCRT_STAT_CAT_HTTP1_CHANNEL = :http1_channel
const AWSCRT_STAT_CAT_HTTP2_CHANNEL = :http2_channel

struct aws_crt_statistics_http1_channel
    category::Symbol
    pending_outgoing_stream_ms::UInt64
    pending_incoming_stream_ms::UInt64
    current_outgoing_stream_id::UInt32
    current_incoming_stream_id::UInt32
end

struct aws_crt_statistics_http2_channel
    category::Symbol
    pending_outgoing_stream_ms::UInt64
    pending_incoming_stream_ms::UInt64
    was_inactive::Bool
end

function _normalize_stat_category(category)
    if category === AWSCRT_STAT_CAT_HTTP1_CHANNEL || category === AWSCRT_STAT_CAT_HTTP2_CHANNEL
        return category
    end
    category isa Symbol && return category
    return Symbol(category)
end

function _normalize_stat(stat::aws_crt_statistics_http1_channel)
    cat = _normalize_stat_category(stat.category)
    cat === stat.category && return stat
    return aws_crt_statistics_http1_channel(
        cat,
        stat.pending_outgoing_stream_ms,
        stat.pending_incoming_stream_ms,
        stat.current_outgoing_stream_id,
        stat.current_incoming_stream_id,
    )
end

function _normalize_stat(stat::aws_crt_statistics_http2_channel)
    cat = _normalize_stat_category(stat.category)
    cat === stat.category && return stat
    return aws_crt_statistics_http2_channel(
        cat,
        stat.pending_outgoing_stream_ms,
        stat.pending_incoming_stream_ms,
        stat.was_inactive,
    )
end

_normalize_stat(stat) = stat

function _decode_statistics(stats_list)
    list = stats_list isa Base.RefValue ? stats_list[] : stats_list
    out = Any[]
    if list isa AbstractVector
        for item in list
            item = item isa Base.RefValue ? item[] : item
            push!(out, _normalize_stat(item))
        end
        return out
    end
    throw(ArgumentError("stats_list must be an AbstractVector"))
end

struct _StatisticsObserverCallbackWrapper <: Function end

@inline function (::_StatisticsObserverCallbackWrapper)(f::F, nonce, stats)::Nothing where {F}
    f(nonce, stats)
    return nothing
end

@generated function _statistics_observer_callback_fptr(::Type{F}) where {F}
    quote
        @cfunction($(_StatisticsObserverCallbackWrapper()), Cvoid, (Ref{$F}, Any, Any))
    end
end

struct StatisticsObserverCallback
    ptr::Ptr{Cvoid}
    objptr::Ptr{Cvoid}
    _root::Any
end

function StatisticsObserverCallback(callable::F) where {F}
    ptr = _statistics_observer_callback_fptr(F)
    objref = Base.cconvert(Ref{F}, callable)
    objptr = Ptr{Cvoid}(Base.unsafe_convert(Ref{F}, objref))
    return StatisticsObserverCallback(ptr, objptr, objref)
end

@inline _statistics_observer_callback(cb::StatisticsObserverCallback) = cb
@inline _statistics_observer_callback(::Nothing) = nothing
@inline _statistics_observer_callback(cb) = StatisticsObserverCallback(cb)

Base.convert(::Type{Union{Nothing, StatisticsObserverCallback}}, cb::StatisticsObserverCallback) = cb
Base.convert(::Type{Union{Nothing, StatisticsObserverCallback}}, ::Nothing) = nothing
Base.convert(::Type{Union{Nothing, StatisticsObserverCallback}}, cb) = _statistics_observer_callback(cb)

@inline function (f::StatisticsObserverCallback)(nonce, stats)::Nothing
    ccall(f.ptr, Cvoid, (Ptr{Cvoid}, Any, Any), f.objptr, nonce, stats)
    return nothing
end

function _call_statistics_observer(observer, nonce, stats_list)
    observer === nothing && return nothing
    stats = _decode_statistics(stats_list)
    observer(nonce, stats)
    return nothing
end
