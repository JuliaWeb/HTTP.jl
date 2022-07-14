module RetryRequest

using Sockets, LoggingExtras, MbedTLS
using ..IOExtras, ..Messages, ..Strings, ..ExceptionRequest, ..Exceptions

export retrylayer

FALSE(args...) = false

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
    return function(req::Request; retry::Bool=true, retries::Int=4, retry_non_idempotent::Bool=false, retry_delays=ExponentialBackOff(n = retries), retry_check=FALSE, kw...)
        if !retry || retries == 0
            # no retry
            return handler(req; kw...)
        end
        req.context[:allow_retries] = true
        if retry_non_idempotent
            req.context[:retry_non_idempotent] = true
        end
        req_body_is_marked = false
        if req.body isa IO && supportsmark(req.body)
            @debugv 2 "Marking request body stream"
            req_body_is_marked = true
            mark(req.body)
        end
        retryattempt = Ref(0)
        retry_request = Base.retry(handler,
            delays=retry_delays,
            check=(s, ex) -> begin
                retryattempt[] += 1
                retry = (isrecoverable(ex) && retryable(req)) || (Messages.retryable_requestbody(req) && retry_check(req, req.response, get_maybe_ephemeral_response_body(req), ex))
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
            end)

        return retry_request(req; kw...)
    end
end

get_maybe_ephemeral_response_body(req::Request) = isbytes(req.response.body) ? req.response.body : get(() -> UInt8[], req.context, :ephemeral_response_body)

supportsmark(x) = false
supportsmark(x::T) where {T <: IO} = length(Base.methods(mark, Tuple{T}, parentmodule(T))) > 0 || hasfield(T, :mark)

isrecoverable(e) = false
isrecoverable(e::Union{Base.EOFError, Base.IOError, MbedTLS.MbedException}) = true
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
        !isrecoverable(ex) ?  "$ex not recoverable, " : "",
        !isbytes(req.body) ? "request streamed, " : "",
        !isbytes(req.response.body) ? "response streamed, " : "",
        !isidempotent(req) ? "$(req.method) non-idempotent" : "")
    return String(take!(buf))
end

end # module RetryRequest
