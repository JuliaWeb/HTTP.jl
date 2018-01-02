module RetryRequest

import ..HTTP
import ..Layer, ..request
using ..MessageRequest
using ..Messages
import ..@debug, ..DEBUG_LEVEL

abstract type RetryLayer{Next <: Layer} <: Layer end
export RetryLayer


isrecoverable(e::Base.UVError) = true
isrecoverable(e::Base.DNSError) = true
isrecoverable(e::Base.EOFError) = true
isrecoverable(e::Base.ArgumentError) = e.msg == "stream is closed or unusable"
isrecoverable(e::HTTP.StatusError) = e.status >= 500

isrecoverable(e::Exception) = false

isrecoverable(e, req, retry_non_idempotent) =
    isrecoverable(e) &&
    !(req.body === body_was_streamed) &&
    !(req.response.body === body_was_streamed) &&
    (retry_non_idempotent || !isidempotent(req))
    # MUST NOT automatically retry a request with a non-idempotent method
    # https://tools.ietf.org/html/rfc7230#section-6.3.1

function request(::Type{RetryLayer{Next}}, uri, req, body;
                 retries=4, retry_non_idempotent=false, kw...) where Next

    retry_request = retry(request,
        delays=ExponentialBackOff(n = retries),
        check=(s,ex)->begin
            retry = isrecoverable(ex, req, retry_non_idempotent)
            if retry
                @debug 0 "🔄  Retry $e: $(sprint(showcompact, req))"
                reset!(req.response)
            end
            return s, retry
        end)

    retry_request(Next, uri, req, body; kw...)
end


end # module RetryRequest
