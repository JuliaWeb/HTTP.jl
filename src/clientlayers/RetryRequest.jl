module RetryRequest

using Sockets, LoggingExtras, MbedTLS, OpenSSL
using ..IOExtras, ..Messages, ..Strings, ..ExceptionRequest, ..Exceptions

export retrylayer, retry_check, isrecoverable

"""
    retrylayer(handler) -> handler

Retry the request if it throws a recoverable exception.

`Base.retry` and `Base.ExponentialBackOff` implement a randomised exponentially
increasing delay is introduced between attempts to avoid exacerbating network
congestion.

Methods of `isrecoverable(e)` define which exception types lead to a retry.
e.g. `Sockets.DNSError`, `Base.EOFError` and `HTTP.StatusError`
(if status is `5xx`).
"""
function retrylayer(handler)
    return function(req::Request; retries::Int=4, retry::Bool=retries>0, 
        retry_delays=ExponentialBackOff(n=retries, factor=3.0), retry_check=retry_check,
        retry_non_idempotent::Bool=false, kw...
    )
        retry || return handler(req; kw...) # no retry
        retries = length(retry_delays)
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
        retry_request = Base.retry(handler, delays=retry_delays,
            check = (s, ex) -> begin
                req.context[:retrylimitreached] = (req.context[:retryattempt] += 1) > retries
                retry = retryable(req) && _retry_check(s, ex, req, retry_check)
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

function _retry_check(s, ex, req, check)
    resp = req.response
    resp_body = get(req.context, :response_body, nothing)
    return check(s, ex, req, resp_body !== nothing ? resp : nothing, resp_body)
end
retry_check(s, ex, x...) = isrecoverable(ex)
isrecoverable(e) = false
isrecoverable(e::Union{Base.EOFError, Base.IOError, MbedTLS.MbedException, OpenSSL.OpenSSLError}) = true
isrecoverable(e::ArgumentError) = e.msg == "stream is closed or unusable"
isrecoverable(e::Sockets.DNSError) = true
isrecoverable(e::ConnectError) = true
isrecoverable(e::RequestError) = isrecoverable(e.error)
isrecoverable(e::StatusError) = retryable(e.status)

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
