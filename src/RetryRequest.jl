module RetryRequest

using Sockets, LoggingExtras
using ..IOExtras, ..Messages, ..Strings, ..ExceptionRequest

export retrylayer

"""
    retrylayer(handler) -> handler

Retry the request if it throws a recoverable exception.

`Base.retry` and `Base.ExponentialBackOff` implement a randomised exponentially
increasing delay is introduced between attempts to avoid exacerbating network
congestion.

Methods of `isrecoverable(e)` define which exception types lead to a retry.
e.g. `HTTP.IOError`, `Sockets.DNSError`, `Base.EOFError` and `HTTP.StatusError`
(if status is ``5xx`).
"""
function retrylayer(handler)
    return function(req::Request; retry::Bool=true, retries::Int=4, retry_non_idempotent::Bool=false, kw...)
        if !retry || retries == 0
            # no retry
            return handler(req; kw...)
        end
        retry_request = Base.retry(handler,
            delays=ExponentialBackOff(n = retries),
            check=(s, ex)->begin
                retry = isrecoverable(ex, req, retry_non_idempotent, get(req.context, :retrycount, 0))
                if retry
                    @debugv 1 "🔄  Retry $ex: $(sprintcompact(req))"
                    reset!(req.response)
                else
                    @debugv 1 "🚷  No Retry: $(no_retry_reason(ex, req))"
                end
                return s, retry
            end)

        return retry_request(req; kw...)
    end
end

isrecoverable(e) = false
isrecoverable(e::IOError) = true
isrecoverable(e::Sockets.DNSError) = true
isrecoverable(e::StatusError) = e.status == 403 || # Forbidden
                                     e.status == 408 || # Timeout
                                     e.status >= 500    # Server Error

isrecoverable(e, req, retry_non_idempotent, retrycount) =
    isrecoverable(e) &&
    isbytes(req.body) &&
    isbytes(req.response.body) &&
    (retry_non_idempotent || retrycount == 0 || isidempotent(req))
    # "MUST NOT automatically retry a request with a non-idempotent method"
    # https://tools.ietf.org/html/rfc7230#section-6.3.1

function no_retry_reason(ex, req)
    buf = IOBuffer()
    show(IOContext(buf, :compact => true), req)
    print(buf, ", ",
        ex isa StatusError ? "HTTP $(ex.status): " :
        !isrecoverable(ex) ?  "$ex not recoverable, " : "",
        !isbytes(req.body) ? "request streamed, " : "",
        !isbytes(req.response.body) ? "response streamed, " : "",
        !isidempotent(req) ? "$(req.method) non-idempotent" : "")
    return String(take!(buf))
end

end # module RetryRequest
