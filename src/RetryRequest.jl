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
isrecoverable(e::HTTP.StatusError) = e.status < 200 || e.status >= 500
isrecoverable(e::Base.ArgumentError) = e.msg == "stream is closed or unusable"

isrecoverable(e::Exception) = false

isrecoverable(e, req) = isrecoverable(e) &&
                        !(req.body === body_was_streamed) &&
                        !(req.response.body === body_was_streamed) &&
                        (@debug 1 "Retring on $e: $(sprint(showcompact, req))";
                         true)


function request(::Type{RetryLayer{Next}}, uri, req, body;
                 retries=4, kw...) where Next

    retry_request = retry(request, delays=ExponentialBackOff(n = retries),
                                   check=(s,ex)->(s,isrecoverable(ex, req) &&
                                                  (reset!(req.response); true)))

    retry_request(Next, uri, req, body; kw...)
end


end # module RetryRequest
