struct DontRetry <: Exception
    error::Exception
end

Base.showerror(io::IO, e::DontRetry) = print(io, e.error)

struct StreamError{T} <: Exception
    error::Exception
    stream::T # Stream
end

Base.showerror(io::IO, e::StreamError) = print(io, e.error)

retryable_status(status::Integer) = status in (403, 408, 409, 429, 500, 502, 503, 504, 599)

function isrecoverable(ex::Exception)::Bool
    if ex isa StatusError
        return retryable_status(ex.status)
    elseif ex isa ConnectError
        return isrecoverable(ex.error)
    elseif ex isa TimeoutError
        return true
    elseif ex isa RequestError
        return isrecoverable(ex.error)
    elseif ex isa Base.EOFError || ex isa Base.IOError
        return true
    elseif ex isa ArgumentError
        return ex.msg == "stream is closed or unusable"
    elseif ex isa CompositeException
        for child in ex.exceptions
            child isa Exception || return false
            isrecoverable(child) || return false
        end
        return true
    elseif ex isa AWSError
        return true
    end
    return false
end

@inline function _default_retryable(method, err::Exception, retryable_body::Bool, retry_non_idempotent::Bool)::Bool
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
            return Reseau.Sockets.RetryErrorType.THROTTLING
        elseif 500 <= status < 600
            return Reseau.Sockets.RetryErrorType.SERVER_ERROR
        elseif 400 <= status < 500
            return Reseau.Sockets.RetryErrorType.CLIENT_ERROR
        else
            return Reseau.Sockets.RetryErrorType.TRANSIENT
        end
    end
    return Reseau.Sockets.RetryErrorType.TRANSIENT
end

function with_retry_token(
    f,
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
    start_time = context !== nothing ? time() : 0.0
    try
        return f()
    catch e
        err = e isa StreamError ? (e::StreamError).error : e
        if err isa DontRetry
            if e isa StreamError
                stream = (e::StreamError).stream::Stream
                if iserror(stream.response.status) && stream.bufferstream !== nothing
                    # For error responses, we need to commit the temporary body buffer.
                    stream.response.body = readavailable(stream.bufferstream)
                end
            end
            throw(err.error)
        end
        if logerrors
            @error "HTTP request error" exception=(err, catch_backtrace()) method=method url=uri logtag=logtag
        end
        rethrow()
    finally
        context !== nothing && _record_layer!(context, :retrylayer, start_time)
    end
end
