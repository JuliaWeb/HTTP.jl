module RetryRequest

import ..HTTP
import ..Layer, ..RequestStack.request
using ..Messages

abstract type RetryLayer{Next <: Layer} <: Layer end
export RetryLayer


isrecoverable(e::Base.UVError) = true
isrecoverable(e::Base.DNSError) = true
isrecoverable(e::Base.EOFError) = true
isrecoverable(e::HTTP.StatusError) = e.status < 200 || e.status >= 500
isrecoverable(e::Base.ArgumentError) = e.msg == "stream is closed or unusable"

isrecoverable(e::Exception) = false

isrecoverable(e, request_body, response_body) = isrecoverable(e) &&
                                                isstreamfresh(request_body) &&
                                                isstreamfresh(response_body)

function request(::Type{RetryLayer{Next}},
                 method::String, uri, headers, body::Body, response_body::Body;
                 retries=3, kw...) where Next

    retry_request = retry(request,
          delays=ExponentialBackOff(n = retries),
          check=(s,ex)->(s,isrecoverable(ex, body, response_body)))

    retry_request(Next, method, uri, headers, body, response_body; kw...)
end


end # module RetryRequest
