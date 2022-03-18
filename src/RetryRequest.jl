module RetryRequest

import ..HTTP
using ..Layers
using ..Sockets
using ..IOExtras
using ..MessageRequest
using ..Messages
import ..@debug, ..DEBUG_LEVEL, ..sprintcompact

"""
    Layers.request(RetryLayer, ::URI, ::Request, body) -> HTTP.Response

Retry the request if it throws a recoverable exception.

`Base.retry` and `Base.ExponentialBackOff` implement a randomised exponentially
increasing delay is introduced between attempts to avoid exacerbating network
congestion.

Methods of `isrecoverable(e)` define which exception types lead to a retry.
e.g. `HTTP.IOError`, `Sockets.DNSError`, `Base.EOFError` and `HTTP.StatusError`
(if status is ``5xx`).
"""
struct RetryLayer{Next <: Layer} <: RequestLayer
    next::Next
    retries::Int
    retry_non_idempotent::Bool
end
export RetryLayer
Layers.keywordforlayer(::Val{:retry}) = RetryLayer
RetryLayer(next; retry::Bool=true, retries::int=4, retry_non_idempotent=false, kw...) =
    retry ? RetryLayer(next, retries, retry_non_idempotent) : nothing

function Layers.request(layer::RetryLayer, url, req, body)

    retry_request = Base.retry(Layers.request,
        delays=ExponentialBackOff(n = retries),
        check=(s,ex)->begin
            retry = isrecoverable(ex, req, retry_non_idempotent)
            if retry
                @debug 1 "🔄  Retry $ex: $(sprintcompact(req))"
                reset!(req.response)
            else
                @debug 1 "🚷  No Retry: $(no_retry_reason(ex, req))"
            end
            return s, retry
        end)

    retry_request(layer.next, url, req, body)
end

isrecoverable(e) = false
isrecoverable(e::IOError) = true
isrecoverable(e::Sockets.DNSError) = true
isrecoverable(e::HTTP.StatusError) = e.status == 403 || # Forbidden
                                     e.status == 408 || # Timeout
                                     e.status >= 500    # Server Error

isrecoverable(e, req, retry_non_idempotent) =
    isrecoverable(e) &&
    !(req.body === body_was_streamed) &&
    !(req.response.body === body_was_streamed) &&
    (retry_non_idempotent || req.txcount == 0 || isidempotent(req))
    # "MUST NOT automatically retry a request with a non-idempotent method"
    # https://tools.ietf.org/html/rfc7230#section-6.3.1


function no_retry_reason(ex, req)
    buf = IOBuffer()
    show(IOContext(buf, :compact => true), req)
    print(buf, ", ",
        ex isa HTTP.StatusError ? "HTTP $(ex.status): " :
        !isrecoverable(ex) ?  "$ex not recoverable, " : "",
        (req.body === body_was_streamed) ? "request streamed, " : "",
        (req.response.body === body_was_streamed) ? "response streamed, " : "",
        !isidempotent(req) ? "$(req.method) non-idempotent" : "")
    return String(take!(buf))
end

end # module RetryRequest
