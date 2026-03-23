# Internal request-scoped client timeout parsing and context helpers.

const _REQUEST_TIMEOUT_CONTEXT_KEY = :_http_request_timeout_config

@inline function _min_nonzero_ns(a::Int64, b::Int64)::Int64
    a == 0 && return b
    b == 0 && return a
    return min(a, b)
end

function _phase_deadline_ns(timeout_ns::Int64, overall_deadline_ns::Int64)::Int64
    timeout_ns < 0 && throw(ArgumentError("timeout_ns must be >= 0"))
    overall_deadline_ns < 0 && throw(ArgumentError("overall_deadline_ns must be >= 0"))
    timeout_deadline_ns = Int64(0)
    if timeout_ns > 0
        now_ns = Int64(time_ns())
        timeout_deadline_ns = now_ns > typemax(Int64) - timeout_ns ? typemax(Int64) : now_ns + timeout_ns
    end
    return _min_nonzero_ns(timeout_deadline_ns, overall_deadline_ns)
end

struct _RequestTimeoutConfig
    connect_timeout_ns::Int64
    response_header_timeout_ns::Int64
    read_idle_timeout_ns::Int64
    write_idle_timeout_ns::Int64
    expect_continue_timeout_ns::Int64
end

@inline function _request_timeout_config_empty(config::_RequestTimeoutConfig)::Bool
    return config.connect_timeout_ns == 0 &&
           config.response_header_timeout_ns == 0 &&
           config.read_idle_timeout_ns == 0 &&
           config.write_idle_timeout_ns == 0 &&
           config.expect_continue_timeout_ns == 0
end

function _timeout_ns_from_seconds(name::AbstractString, value)::Int64
    value isa Bool && throw(ArgumentError("$(name) must be a real number of seconds"))
    value isa Real || throw(ArgumentError("$(name) must be a real number of seconds"))
    seconds = Float64(value)
    isfinite(seconds) || throw(ArgumentError("$(name) must be finite"))
    seconds >= 0 || throw(ArgumentError("$(name) must be >= 0"))
    seconds == 0 && return Int64(0)
    nanoseconds = round(Int128, seconds * 1.0e9)
    nanoseconds <= typemax(Int64) || throw(ArgumentError("$(name) is too large"))
    return Int64(nanoseconds)
end

function _warn_deprecated_readtimeout()::Nothing
    @warn "`readtimeout` is deprecated; use `read_idle_timeout` for inactivity timeouts or `request_timeout` for overall request deadlines" maxlog=1
    return nothing
end

function _resolve_request_timeout_settings(;
    request_timeout::Real=0,
    connect_timeout::Real=0,
    response_header_timeout::Real=0,
    read_idle_timeout::Real=0,
    write_idle_timeout::Real=0,
    expect_continue_timeout=nothing,
    readtimeout=nothing,
)::Tuple{Int64,Union{Nothing,_RequestTimeoutConfig}}
    read_idle_timeout_value = read_idle_timeout
    if readtimeout !== nothing
        read_idle_timeout == 0 || throw(ArgumentError("readtimeout is deprecated and cannot be combined with read_idle_timeout"))
        _warn_deprecated_readtimeout()
        read_idle_timeout_value = readtimeout
    end
    request_timeout_ns = _timeout_ns_from_seconds("request_timeout", request_timeout)
    connect_timeout_ns = _timeout_ns_from_seconds("connect_timeout", connect_timeout)
    response_header_timeout_ns = _timeout_ns_from_seconds("response_header_timeout", response_header_timeout)
    read_idle_timeout_ns = _timeout_ns_from_seconds("read_idle_timeout", read_idle_timeout_value)
    write_idle_timeout_ns = _timeout_ns_from_seconds("write_idle_timeout", write_idle_timeout)
    expect_continue_timeout_ns = expect_continue_timeout === nothing ? Int64(0) : _timeout_ns_from_seconds("expect_continue_timeout", expect_continue_timeout)
    config = _RequestTimeoutConfig(
        connect_timeout_ns,
        response_header_timeout_ns,
        read_idle_timeout_ns,
        write_idle_timeout_ns,
        expect_continue_timeout_ns,
    )
    return request_timeout_ns, _request_timeout_config_empty(config) ? nothing : config
end

@inline function _request_context_timeout_config(ctx::RequestContext)::Union{Nothing,_RequestTimeoutConfig}
    metadata = ctx.metadata
    metadata === nothing && return nothing
    return get(() -> nothing, metadata::Dict{Symbol,Any}, _REQUEST_TIMEOUT_CONTEXT_KEY)
end

@inline function _set_request_context_timeout_config!(ctx::RequestContext, config::Union{Nothing,_RequestTimeoutConfig})::Nothing
    if config === nothing
        metadata = ctx.metadata
        metadata === nothing || delete!(metadata::Dict{Symbol,Any}, _REQUEST_TIMEOUT_CONTEXT_KEY)
        return nothing
    end
    ctx[_REQUEST_TIMEOUT_CONTEXT_KEY] = config
    return nothing
end

function _apply_request_timeout_settings!(
    ctx::RequestContext,
    request_timeout_ns::Int64,
    config::Union{Nothing,_RequestTimeoutConfig},
)::RequestContext
    request_timeout_ns < 0 && throw(ArgumentError("request_timeout_ns must be >= 0"))
    if request_timeout_ns > 0
        now_ns = Int64(time_ns())
        deadline_ns = now_ns > typemax(Int64) - request_timeout_ns ? typemax(Int64) : now_ns + request_timeout_ns
        set_deadline!(ctx, deadline_ns)
    end
    _set_request_context_timeout_config!(ctx, config)
    return ctx
end

@inline function _request_connect_timeout_ns(request::Request)::Int64
    config = _request_context_timeout_config(request.context)
    config === nothing && return Int64(0)
    return (config::_RequestTimeoutConfig).connect_timeout_ns
end

@inline function _request_response_header_timeout_ns(request::Request)::Int64
    config = _request_context_timeout_config(request.context)
    config === nothing && return Int64(0)
    return (config::_RequestTimeoutConfig).response_header_timeout_ns
end

@inline function _request_response_header_deadline_ns(request::Request)::Int64
    timeout_ns = _min_nonzero_ns(_request_response_header_timeout_ns(request), _request_read_idle_timeout_ns(request))
    return _phase_deadline_ns(timeout_ns, _request_deadline_ns(request))
end

@inline function _request_read_idle_timeout_ns(request::Request)::Int64
    config = _request_context_timeout_config(request.context)
    config === nothing && return Int64(0)
    return (config::_RequestTimeoutConfig).read_idle_timeout_ns
end

@inline function _request_read_deadline_ns(request::Request)::Int64
    return _phase_deadline_ns(_request_read_idle_timeout_ns(request), _request_deadline_ns(request))
end

@inline function _request_write_idle_timeout_ns(request::Request)::Int64
    config = _request_context_timeout_config(request.context)
    config === nothing && return Int64(0)
    return (config::_RequestTimeoutConfig).write_idle_timeout_ns
end

@inline function _request_write_deadline_ns(request::Request)::Int64
    return _phase_deadline_ns(_request_write_idle_timeout_ns(request), _request_deadline_ns(request))
end

@inline function _request_expect_continue_timeout_ns(request::Request)::Int64
    config = _request_context_timeout_config(request.context)
    config === nothing && return Int64(0)
    return (config::_RequestTimeoutConfig).expect_continue_timeout_ns
end
