struct DontRetry{T} <: Exception
    error::T
end

Base.showerror(io::IO, e::DontRetry) = print(io, e.error)

struct StreamError{T} <: Exception
    error::Exception
    stream::T # Stream
end

Base.showerror(io::IO, e::StreamError) = print(io, e.error)

retryable_status(status::Integer) = status in (403, 408, 409, 429, 500, 502, 503, 504, 599)

isrecoverable(ex::StatusError) = retryable_status(ex.status)
isrecoverable(::Union{Base.EOFError, Base.IOError}) = true
isrecoverable(ex::ArgumentError) = ex.msg == "stream is closed or unusable"
isrecoverable(ex::CompositeException) = all(isrecoverable, ex.exceptions)
isrecoverable(ex::Sockets.DNSError) = (ex.code == Base.UV_EAI_AGAIN)
isrecoverable(::AWSError) = true
isrecoverable(::Exception) = false

const on_acquired = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_acquired(retry_strategy, error_code, retry_token, fut_ptr)
    fut = unsafe_pointer_to_objref(fut_ptr)
    if error_code != 0
        notify(fut, DontRetry(CapturedException(aws_error(error_code), Base.backtrace())))
    else
        notify(fut, retry_token)
    end
    return
end

const retry_ready = Ref{Ptr{Cvoid}}(C_NULL)

function c_retry_ready(token, error_code::Cint, fut_ptr)
    fut = unsafe_pointer_to_objref(fut_ptr)
    if error_code != 0
        notify(fut, DontRetry(CapturedException(aws_error(error_code), Base.backtrace())))
    else
        notify(fut, token)
    end
    return
end

function _default_retryable(method, err, retryable_body::Bool, retry_non_idempotent::Bool)
    retryable_body || return false
    method === nothing && return false
    method_str = string(method)
    if !(isidempotent(method_str) || retry_non_idempotent)
        return false
    end
    if err isa StatusError
        return retryable_status(err.status)
    end
    return isrecoverable(err)
end

function _normalize_retry_delays(retry_delays, max_retries::Int)
    if retry_delays === nothing
        return Base.ExponentialBackOff(n=max_retries, factor=3.0)
    elseif retry_delays isa Number
        return Iterators.repeated(retry_delays, max_retries)
    else
        return retry_delays
    end
end

function _set_nretries!(x, nretries::Int)
    if x isa Response
        x.metrics.nretries = nretries
    elseif x isa StatusError
        x.response.metrics.nretries = nretries
    elseif x isa StreamError && x.stream !== nothing
        x.stream.response !== nothing && (x.stream.response.metrics.nretries = nretries)
    end
    return
end

function with_retry_token(
    f::Function,
    client::Client;
    logerrors::Bool=false,
    logtag=nothing,
    method=nothing,
    uri=nothing,
    retry_check=nothing,
    retry_delays=nothing,
    retry_non_idempotent::Bool=false,
    retryable_body::Bool=true,
    req_ref=nothing,
)
    # If max_retries is 0, we don't need to bother with any retrying
    max_retries = client.settings.max_retries
    if max_retries == 0
        try
            return f()
        catch e
            if logerrors
                url = uri === nothing ? nothing : (uri isa aws_uri ? makeuri(uri) : uri)
                @error "HTTP request error" exception=(e, catch_backtrace()) method=method url=url logtag=logtag
            end
            rethrow()
        end
    end
    retry_check_fn = retry_check === nothing ? nothing : retry_check
    delays = _normalize_retry_delays(retry_delays, max_retries)
    delay_state = nothing
    nretries = 0
    while true
        try
            ret = f()
            _set_nretries!(ret, nretries)
            return ret
        catch e
            stream = nothing
            err = e
            if err isa StreamError
                stream = err.stream
                err = err.error
            end
            if logerrors
                log_err = err isa DontRetry ? err.error : err
                url = uri === nothing ? nothing : (uri isa aws_uri ? makeuri(uri) : uri)
                @error "HTTP request error" exception=(log_err, catch_backtrace()) method=method url=url logtag=logtag
            end
            if err isa DontRetry
                if stream !== nothing && iserror(stream.response.status) && stream.bufferstream !== nothing
                    # for error responses, we need to commit the temporary body buffer
                    stream.response.body = readavailable(stream.bufferstream)
                end
                err = err.error
                _set_nretries!(err, nretries)
                throw(err)
            end
            nretries >= max_retries && (_set_nretries!(err, nretries); throw(err))
            delay_iter = delay_state === nothing ? iterate(delays) : iterate(delays, delay_state)
            delay_iter === nothing && (_set_nretries!(err, nretries); throw(err))
            delay, delay_state = delay_iter
            req = req_ref === nothing ? nothing : req_ref[]
            resp = err isa StatusError ? err.response : nothing
            resp_body = resp === nothing ? nothing : resp.body
            retry = _default_retryable(method, err, retryable_body, retry_non_idempotent)
            if !retry && retry_check_fn !== nothing && retryable_body
                retry = retry_check_fn(delay, err, req, resp, resp_body)
            end
            if !retry
                _set_nretries!(err, nretries)
                throw(err)
            end
            nretries += 1
            sleep(delay)
        end
    end
end
