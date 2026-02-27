# Connection Monitor + HTTP Statistics
# Port of aws-c-http/connection_monitor.h, connection_monitor.c, statistics.h, statistics.c

# ─── HTTP/1.1 channel statistics ───

mutable struct CrtStatisticsHttp1Channel
    pending_outgoing_stream_ms::UInt64
    pending_incoming_stream_ms::UInt64
    current_outgoing_stream_id::UInt32
    current_incoming_stream_id::UInt32
end

function crt_statistics_http1_channel_init()::CrtStatisticsHttp1Channel
    return CrtStatisticsHttp1Channel(UInt64(0), UInt64(0), UInt32(0), UInt32(0))
end

function crt_statistics_http1_channel_reset!(stats::CrtStatisticsHttp1Channel)::Nothing
    stats.pending_outgoing_stream_ms = UInt64(0)
    stats.pending_incoming_stream_ms = UInt64(0)
    return nothing
end

# ─── HTTP/2 channel statistics ───

mutable struct CrtStatisticsHttp2Channel
    pending_outgoing_stream_ms::UInt64
    pending_incoming_stream_ms::UInt64
    was_inactive::Bool
end

function crt_statistics_http2_channel_init()::CrtStatisticsHttp2Channel
    return CrtStatisticsHttp2Channel(UInt64(0), UInt64(0), false)
end

function crt_statistics_http2_channel_reset!(stats::CrtStatisticsHttp2Channel)::Nothing
    stats.pending_outgoing_stream_ms = UInt64(0)
    stats.pending_incoming_stream_ms = UInt64(0)
    stats.was_inactive = false
    return nothing
end

# ─── Statistics observer ───

# Callback: (stats, channel_handler_type, user_data) -> Nothing
# channel_handler_type is 1 for H1, 2 for H2

# ─── Connection monitor ───

@enumx ConnectionHealthState::UInt8 begin
    HEALTHY = 0
    DEGRADED = 1
    UNHEALTHY = 2
end

mutable struct HttpConnectionMonitor{FU, UD}
    options::HttpConnectionMonitoringOptions
    bytes_read::UInt64
    bytes_written::UInt64
    last_check_time_ns::UInt64
    consecutive_failure_seconds::UInt32
    health_state::ConnectionHealthState.T
    on_unhealthy::FU   # (monitor, user_data) -> Nothing
    user_data::UD
end

function http_connection_monitor_new(;
    options::HttpConnectionMonitoringOptions=HttpConnectionMonitoringOptions(UInt64(0), UInt32(0)),
    on_unhealthy=nothing,
    user_data=nothing,
)::HttpConnectionMonitor
    return HttpConnectionMonitor(
        options,
        UInt64(0), UInt64(0),
        Reseau.monotonic_time_ns(),
        UInt32(0),
        ConnectionHealthState.HEALTHY,
        on_unhealthy,
        user_data,
    )
end

"""
    http_connection_monitor_record_bytes!(monitor; bytes_read=0, bytes_written=0) -> Nothing

Record bytes transferred for throughput calculation.
"""
function http_connection_monitor_record_bytes!(monitor::HttpConnectionMonitor;
    bytes_read::UInt64=UInt64(0),
    bytes_written::UInt64=UInt64(0),
)::Nothing
    monitor.bytes_read += bytes_read
    monitor.bytes_written += bytes_written
    return nothing
end

"""
    http_connection_monitor_check_throughput!(monitor) -> ConnectionHealthState.T

Check if the connection meets the minimum throughput threshold.
Called periodically (typically every second).
"""
function http_connection_monitor_check_throughput!(monitor::HttpConnectionMonitor)::ConnectionHealthState.T
    min_throughput = monitor.options.minimum_throughput_bytes_per_second
    if min_throughput == 0
        return ConnectionHealthState.HEALTHY
    end

    now_ns = Reseau.monotonic_time_ns()
    elapsed_ns = now_ns - monitor.last_check_time_ns
    elapsed_s = elapsed_ns / 1_000_000_000

    if elapsed_s < 0.5
        return monitor.health_state
    end

    total_bytes = monitor.bytes_read + monitor.bytes_written
    throughput = UInt64(round(total_bytes / elapsed_s))

    # Reset counters
    monitor.bytes_read = UInt64(0)
    monitor.bytes_written = UInt64(0)
    monitor.last_check_time_ns = now_ns

    if throughput >= min_throughput
        monitor.consecutive_failure_seconds = UInt32(0)
        monitor.health_state = ConnectionHealthState.HEALTHY
        return ConnectionHealthState.HEALTHY
    end

    # Below threshold
    monitor.consecutive_failure_seconds += UInt32(max(1, round(Int, elapsed_s)))

    if monitor.consecutive_failure_seconds >= monitor.options.allowable_throughput_failure_interval_seconds
        monitor.health_state = ConnectionHealthState.UNHEALTHY
        if monitor.on_unhealthy !== nothing
            monitor.on_unhealthy(monitor, monitor.user_data)
        end
        return ConnectionHealthState.UNHEALTHY
    end

    monitor.health_state = ConnectionHealthState.DEGRADED
    return ConnectionHealthState.DEGRADED
end
