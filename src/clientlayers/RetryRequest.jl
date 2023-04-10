module RetryRequest

using Sockets, LoggingExtras, MbedTLS, OpenSSL
using ..IOExtras, ..Messages, ..Strings, ..ExceptionRequest, ..Exceptions

export retrylayer

FALSE(x...) = false

"""
    retrylayer(handler) -> handler

Retry the request if it throws a recoverable exception.

`Base.retry` and `Base.ExponentialBackOff` implement a randomised exponentially
increasing delay is introduced between attempts to avoid exacerbating network
congestion.

By default, requests that have a retryable body, where the request wasn't written
or is idempotent will be retries. If the request is made and a response is received
with a status code of 403, 408, 409, 429, or 5xx, the request will be retried.

`retries` controls the # of total retries that will be attempted.

`retry_check` allows passing a custom retry check in the case where the default
retry check _wouldn't_ retry, if `retry_check` returns true, then the request
will be retried anyway.
"""
function retrylayer(handler)
    return function manageretries(req::Request; retry::Bool=true, retries::Int=4,
        retry_delays=ExponentialBackOff(n = retries, factor=3.0), retry_check=FALSE,
        retry_non_idempotent::Bool=false, kw...)
        if !retry || retries == 0
            # no retry
            return handler(req; kw...)
        end
        req.context[:allow_retries] = true
        req.context[:retryattempt] = 0
        if retry_non_idempotent
            req.context[:retry_non_idempotent] = true
        end
        req_body_is_marked = false
        if req.body isa IO && Messages.supportsmark(req.body)
            @debugv 2 "Marking request body stream"
            req_body_is_marked = true
            mark(req.body)
        end
        retryattempt = Ref(0)
        retry_request = Base.retry(handler,
            delays=retry_delays,
            check=(s, ex) -> begin
                retryattempt[] += 1
                req.context[:retryattempt] = retryattempt[]
                retry = (
                    (isrecoverable(ex) && retryable(req)) ||
                    (retryablebody(req) && !retrylimitreached(req) && _retry_check(s, ex, req, retry_check))
                )
                if retryattempt[] == retries
                    req.context[:retrylimitreached] = true
                end
                if retry
                    @debugv 1 "🔄  Retry $ex: $(sprintcompact(req))"
                    reset!(req.response)
                    if req_body_is_marked
                        @debugv 2 "Resetting request body stream"
                        reset(req.body)
                        mark(req.body)
                    end
                else
                    @debugv 1 "🚷  No Retry: $(no_retry_reason(ex, req))"
                end
                return s, retry
            end
        )
        return retry_request(req; kw...)
    end
end

const EAI_AGAIN = 2
isrecoverable(ex) = true
isrecoverable(ex::ConnectError) = ex.error isa Sockets.DNSError && ex.error.code == EAI_AGAIN ? false : true
isrecoverable(ex::StatusError) = retryable(ex.status)

function _retry_check(s, ex, req, check)
    resp = req.response
    resp_body = get(req.context, :response_body, nothing)
    return check(s, ex, req, resp_body !== nothing ? resp : nothing, resp_body)
end

function no_retry_reason(ex, req)
    buf = IOBuffer()
    show(IOContext(buf, :compact => true), req)
    print(buf, ", ",
        ex isa StatusError ? "HTTP $(ex.status): " :
        !isbytes(req.body) ? "request streamed, " : "",
        !isbytes(req.response.body) ? "response streamed, " : "",
        !isidempotent(req) ? "$(req.method) non-idempotent" : "")
    return String(take!(buf))
end

end # module RetryRequest
