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
isrecoverable(ex::ConnectError) = isrecoverable(ex.error)
isrecoverable(ex::TimeoutError) = true
isrecoverable(ex::RequestError) = isrecoverable(ex.error)
isrecoverable(::Union{Base.EOFError, Base.IOError}) = true
isrecoverable(ex::ArgumentError) = ex.msg == "stream is closed or unusable"
isrecoverable(ex::CompositeException) = all(isrecoverable, ex.exceptions)
isrecoverable(ex::Sockets.DNSError) = (ex.code == Base.UV_EAI_AGAIN)
isrecoverable(::AWSError) = true
isrecoverable(::Exception) = false

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

function _retry_error_type(err)
    if err isa StatusError
        status = err.status
        if status == 429
            return AwsIO.RetryErrorType.THROTTLING
        elseif 500 <= status < 600
            return AwsIO.RetryErrorType.SERVER_ERROR
        elseif 400 <= status < 500
            return AwsIO.RetryErrorType.CLIENT_ERROR
        else
            return AwsIO.RetryErrorType.TRANSIENT
        end
    end
    return AwsIO.RetryErrorType.TRANSIENT
end

function _set_nretries!(x, nretries::Int)
    if x isa Response
        x.metrics.nretries = nretries
    elseif x isa StatusError
        x.response.metrics.nretries = nretries
    elseif x isa RequestError
        _set_nretries!(x.error, nretries)
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
    context=nothing,
)
    retry_token = nothing
    partition = client.settings.retry_partition
    use_retry_strategy = retry_delays === nothing && partition !== nothing && client.retry_strategy !== nothing
    # If max_retries is 0, we don't need to bother with any retrying
    max_retries = client.settings.max_retries
    if max_retries == 0
        start_time = context !== nothing ? time() : 0.0
        try
            return f()
        catch e
            if logerrors
                @error "HTTP request error" exception=(e, catch_backtrace()) method=method url=uri logtag=logtag
            end
            rethrow()
        finally
            context !== nothing && _record_layer!(context, :retrylayer, start_time)
        end
    end
    retry_check_fn = retry_check === nothing ? nothing : retry_check
    delays = _normalize_retry_delays(retry_delays, max_retries)
    delay_state = nothing
    nretries = 0
    while true
        attempt_start = context === nothing ? 0.0 : time()
        try
            ret = f()
            context === nothing || _record_layer!(context, :retrylayer, attempt_start)
            _set_nretries!(ret, nretries)
            if retry_token !== nothing
                AwsIO.retry_token_record_success(retry_token)
                AwsIO.retry_token_release!(retry_token)
                retry_token = nothing
            end
            return ret
        catch e
            context === nothing || _record_layer!(context, :retrylayer, attempt_start)
            stream = nothing
            err = e
            if err isa StreamError
                stream = err.stream
                err = err.error
            end
            if logerrors
                log_err = err isa DontRetry ? err.error : err
                @error "HTTP request error" exception=(log_err, catch_backtrace()) method=method url=uri logtag=logtag
            end
            if err isa DontRetry
                if stream !== nothing && iserror(stream.response.status) && stream.bufferstream !== nothing
                    # for error responses, we need to commit the temporary body buffer
                    stream.response.body = readavailable(stream.bufferstream)
                end
                err = err.error
                _set_nretries!(err, nretries)
                if retry_token !== nothing
                    AwsIO.retry_token_release!(retry_token)
                    retry_token = nothing
                end
                throw(err)
            end
            if nretries >= max_retries
                _set_nretries!(err, nretries)
                if retry_token !== nothing
                    AwsIO.retry_token_release!(retry_token)
                    retry_token = nothing
                end
                throw(err)
            end
            delay = 0.0
            if !use_retry_strategy
                delay_iter = delay_state === nothing ? iterate(delays) : iterate(delays, delay_state)
                delay_iter === nothing && (_set_nretries!(err, nretries); throw(err))
                delay, delay_state = delay_iter
            end
            req = req_ref === nothing ? nothing : req_ref[]
            resp = err isa StatusError ? err.response : nothing
            resp_body = resp === nothing ? nothing : resp.body
            retry = _default_retryable(method, err, retryable_body, retry_non_idempotent)
            if !retry && retry_check_fn !== nothing && retryable_body
                retry = retry_check_fn(delay, err, req, resp, resp_body)
            end
            if !retry
                _set_nretries!(err, nretries)
                if retry_token !== nothing
                    AwsIO.retry_token_release!(retry_token)
                    retry_token = nothing
                end
                throw(err)
            end
            if use_retry_strategy
                try
                    if retry_token === nothing
                        fut = Future{Any}()
                        AwsIO.retry_strategy_acquire_token!(
                            client.retry_strategy,
                            partition,
                            (token, error_code, _) -> begin
                                if error_code != 0
                                    notify(fut, DontRetry(CapturedException(aws_error(error_code), Base.backtrace())))
                                else
                                    notify(fut, token)
                                end
                            end,
                            nothing,
                            UInt64(client.settings.retry_timeout_ms)
                        )
                        retry_token = wait(fut)
                    end
                    fut = Future{Any}()
                    error_type = _retry_error_type(err)
                    AwsIO.retry_token_schedule_retry(
                        retry_token,
                        error_type,
                        (token, error_code, _) -> begin
                            if error_code != 0
                                notify(fut, DontRetry(CapturedException(aws_error(error_code), Base.backtrace())))
                            else
                                notify(fut, token)
                            end
                        end,
                        nothing
                    )
                    retry_token = wait(fut)
                catch
                    if retry_token !== nothing
                        AwsIO.retry_token_release!(retry_token)
                        retry_token = nothing
                    end
                    _set_nretries!(err, nretries)
                    throw(err)
                end
                nretries += 1
                continue
            end
            nretries += 1
            sleep(delay)
        end
    end
end
