struct DontRetry{T} <: Exception
    error::T
end

Base.showerror(io::IO, e::DontRetry) = print(io, e.error)

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

function with_retry_token(f::Function, client::Client)
    # If max_retries is 0, we don't need to bother with any retrying
    client.settings.max_retries == 0 && return f()
    retry_partition = client.settings.retry_partition === nothing ? C_NULL : aws_byte_cursor_from_c_str(client.settings.retry_partition)
    tokenAcquired = Future{Ptr{aws_retry_token}}()
    GC.@preserve tokenAcquired begin
        if aws_retry_strategy_acquire_retry_token(client.retry_strategy, retry_partition, on_acquired[], pointer_from_objref(tokenAcquired), client.settings.retry_timeout_ms) != 0
            aws_throw_error()
        end
        token = wait(tokenAcquired)
    end
    try
        while true
            try
                ret = f()
                aws_retry_token_record_success(token)
                return ret
            catch e
                e isa DontRetry && throw(e.error)
                retryReady = Future{Ptr{aws_retry_token}}()
                GC.@preserve retryReady begin
                    if aws_retry_strategy_schedule_retry(
                        token,
                        #TODO: use different error types?
                        AWS_RETRY_ERROR_TYPE_TRANSIENT,
                        retry_ready[],
                        pointer_from_objref(retryReady)
                    ) != 0
                        aws_throw_error()
                    end
                    token = wait(retryReady)
                end
            end
        end
    finally
        aws_retry_token_release(token)
    end
end