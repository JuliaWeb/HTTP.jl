module RetryRequest

import ..HTTP
import ..Layer, ..RequestStack.request

abstract type RetryLayer{Next <: Layer} <: Layer end
export RetryLayer


isrecoverable(e::Base.UVError) = true
isrecoverable(e::Base.DNSError) = true
isrecoverable(e::Base.EOFError) = true
isrecoverable(e::HTTP.StatusError) = e.status < 200 || e.status >= 500
isrecoverable(e::Exception) = false


function request(::Type{RetryLayer{Next}}, a...; retries=2, kw...) where Next

    retry(request,
          delays=ExponentialBackOff(n = retries),
          check=(s,ex)->(s,isrecoverable(ex)))(Next, a...; kw...)
end


end # module RetryRequest
