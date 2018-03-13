module BufferedLogs

using Logging

export BufferedLogger, flush_logger

flush_logger() = flush(Logging.current_logger())

mutable struct BufferedLogger{T} <: Logging.AbstractLogger
    logger::T
    logs::Vector{Any}
    min_level::Logging.LogLevel
    function BufferedLogger(logger::T, logs::Vector{Any}, min::Logging.LogLevel) where {T <: Logging.AbstractLogger}
        l = new{T}(logger, logs, min)
        return l
    end
end
BufferedLogger(logger::T) where {T <: Logging.AbstractLogger} =
    BufferedLogger(logger, [], Logging.min_enabled_level(logger))
BufferedLogger() = BufferedLogger(Logging.current_logger())

Logging.shouldlog(logger::BufferedLogger, level, _module, group, id) =
    Logging.shouldlog(logger.logger, level, _module, group, id)
Logging.min_enabled_level(logger::BufferedLogger) = Logging.min_enabled_level(logger.logger)
Logging.catch_exceptions(logger::BufferedLogger) = Logging.catch_exceptions(logger.logger)

function Logging.handle_message(logger::BufferedLogger, args...; kwargs...)
    push!(logger.logs, (args, kwargs))
    return
end

function Base.flush(logger::BufferedLogger)
    logs = splice!(logger.logs, 1:length(logger.logs))
    for log in logs
        Logging.handle_message(logger.logger, log[1]...; log[2]...)
    end
end


end # module
