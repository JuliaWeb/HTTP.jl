# High-level HTTP client retry policy and request retry controller helpers.
mutable struct _RetryController{F}
    enabled::Bool
    remaining::Int
    retry_non_idempotent::Bool
    retry_if::F
    respect_retry_after::Bool
    bucket::Union{Nothing,RetryBucket}
end

"""
    RequestRetryError(err)

Wrapper passed to `retry_if` for request-path failures. Inspect `err.err` to
check the underlying transport or protocol exception.
"""
struct RequestRetryError <: HTTPError
    err::Exception
end

@inline function _retryable_status(status::Int)::Bool
    return status == 408 || status == 429 || status == 500 || status == 502 || status == 503 || status == 504
end

@inline function _retryable_request_method(method::String)::Bool
    return method == "GET" || method == "HEAD" || method == "OPTIONS" || method == "TRACE" || method == "PUT" || method == "DELETE"
end

@inline function _retryable_request_headers(request::Request)::Bool
    key = header(request.headers, "Idempotency-Key", nothing)
    key !== nothing && !isempty(key::String) && return true
    legacy = header(request.headers, "X-Idempotency-Key", nothing)
    return legacy !== nothing && !isempty(legacy::String)
end

@inline function _retryable_request_body(request::Request)::Bool
    return request.content_length == 0 || request.body isa EmptyBody || request.body isa BytesBody
end

@inline function _retryable_policy_request(request::Request, retry_non_idempotent::Bool)::Bool
    _retryable_request_body(request) || return false
    retry_non_idempotent && return true
    return _retryable_request_method(request.method) || _retryable_request_headers(request)
end

function _retryable_request_error(err::Exception)::Bool
    current = err
    while true
        current isa EOFError && return true
        current isa SystemError && return true
        current isa ParseError && return true
        current isa HostResolvers.DialTimeoutError && return true
        current isa IOPoll.NetClosingError && return true
        current isa IOPoll.NotPollableError && return true
        current isa IOPoll.DeadlineExceededError && return false
        current isa TLS.TLSHandshakeTimeoutError && return true
        if current isa HostResolvers.OpError
            current = (current::HostResolvers.OpError).err
            continue
        end
        if current isa TLS.TLSError
            cause = (current::TLS.TLSError).cause
            cause === nothing && return false
            current = cause::Exception
            continue
        end
        return false
    end
end

function _retryable_request_error(err::RequestRetryError)::Bool
    current = err.err
    while true
        current isa EOFError && return true
        current isa SystemError && return true
        current isa ParseError && return true
        current isa HostResolvers.DialTimeoutError && return true
        current isa IOPoll.NetClosingError && return true
        current isa IOPoll.NotPollableError && return true
        current isa IOPoll.DeadlineExceededError && return false
        current isa TLS.TLSHandshakeTimeoutError && return true
        if current isa HostResolvers.OpError
            current = (current::HostResolvers.OpError).err
            continue
        end
        if current isa TLS.TLSError
            cause = (current::TLS.TLSError).cause
            cause === nothing && return false
            current = cause::Exception
            continue
        end
        return false
    end
end

function _retry_hook_decision(controller::_RetryController, attempt::Int, err, req::Request, resp)
    hook = controller.retry_if
    hook === nothing && return nothing
    decision = hook(attempt, err, req, resp)
    (decision === nothing || decision isa Bool) || throw(ArgumentError("retry_if must return Bool or nothing"))
    return decision
end

function _should_retry_request_attempt(controller::_RetryController, attempt::Int, req::Request, err, resp)::Bool
    controller.enabled || return false
    controller.remaining > 0 || return false
    _retryable_request_body(req) || return false
    built_in = false
    if err !== nothing
        built_in = _retryable_policy_request(req, controller.retry_non_idempotent) && _retryable_request_error(err)
    elseif resp !== nothing
        built_in = _retryable_policy_request(req, controller.retry_non_idempotent) && _retryable_status((resp::Response).status)
    end
    decision = _retry_hook_decision(controller, attempt, err, req, resp)
    decision === nothing && return built_in
    return decision::Bool
end

@inline function _retry_bucket_for_request(client::Client, retry_bucket::Bool)
    retry_bucket || return nothing
    return client.transport.retry_bucket
end

@inline function _retry_bucket_for_request(client::Client, retry_bucket::RetryBucket)
    _ = client
    return retry_bucket
end

@inline function _retry_partition_for_address(address::AbstractString)::String
    host, _ = HostResolvers.split_host_port(address)
    return lowercase(host)
end

function _retry_delay_ns(
    controller::_RetryController,
    attempt::Int,
    response::Union{Nothing,Response},
)::Int64
    retry_after_ns = nothing
    if controller.respect_retry_after && response !== nothing
        status = (response::Response).status
        if status == 429 || status == 503
            retry_after_ns = _retry_after_delay_ns((response::Response).headers)
        end
    end
    return _retry_delay_ns(controller.bucket, attempt, retry_after_ns)
end

@inline function _retry_release_error(status::Int)::Union{Nothing,Exception}
    if status == 429 || (500 <= status < 600)
        return ErrorResponseStatus(status)
    end
    return nothing
end

function _sleep_retry_delay!(request::Request, delay_ns::Int64)::Bool
    delay_ns < 0 && return false
    deadline_ns = _request_deadline_ns(request)
    if deadline_ns != 0
        now_ns = Int64(time_ns())
        now_ns >= deadline_ns && return false
        now_ns > typemax(Int64) - delay_ns && return false
        now_ns + delay_ns <= deadline_ns || return false
    end
    delay_ns == 0 && return true
    sleep(delay_ns / 1.0e9)
    return true
end

function _arm_request_retry!(
    controller::_RetryController,
    address::AbstractString,
    request::Request,
    attempt::Int,
    response::Union{Nothing,Response},
)
    delay_ns = _retry_delay_ns(controller, attempt, response)
    token = nothing
    bucket = controller.bucket
    if bucket !== nothing
        try
            token = Base.acquire(bucket::RetryBucket, _retry_partition_for_address(address))
        catch err
            err isa RetryDeniedError || rethrow(err)
            return false, nothing, delay_ns
        end
    end
    ok = false
    try
        _sleep_retry_delay!(request, delay_ns) || return false, nothing, delay_ns
        ok = true
    finally
        ok || (bucket !== nothing && token !== nothing && release(bucket::RetryBucket, token, nothing))
    end
    controller.remaining -= 1
    return true, token, delay_ns
end

function _retry_controller(
    client::Client,
    retry::Bool,
    retries::Integer,
    retry_non_idempotent::Bool,
    retry_if,
    respect_retry_after::Bool,
    retry_bucket::Union{Bool,RetryBucket},
)::_RetryController
    retries isa Bool && throw(ArgumentError("retries must be >= 0"))
    retries >= 0 || throw(ArgumentError("retries must be >= 0"))
    return _RetryController(
        retry && retries > 0,
        Int(retries),
        retry_non_idempotent,
        retry_if,
        respect_retry_after,
        _retry_bucket_for_request(client, retry_bucket),
    )
end

function _retry_policy_response(incoming::_IncomingResponse, fallback_request::Request)::Response
    head = incoming.head
    return _response_nocopy_exact(
        head.status,
        head.reason,
        head.headers,
        head.trailers,
        nothing,
        head.content_length,
        head.proto_major,
        head.proto_minor,
        head.close,
        head.request === nothing ? fallback_request : (head.request::Request),
        head.request_url,
        head.previous,
        head.redirect_count,
    )
end
