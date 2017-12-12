module RetryRequest

struct RetryLayer{T} end
export RetryLayer

import ..HTTP.RequestStack.request
import ..HTTP


isrecoverable(e::Base.UVError) = true
isrecoverable(e::Base.DNSError) = true
isrecoverable(e::Base.EOFError) = true
isrecoverable(e::HTTP.StatusError) = e.status < 200 || e.status >= 500
isrecoverable(e::Exception) = false


function request(::Type{RetryLayer{Next}}, a...; maxretries=2, kw...) where Next

    retry(request,
          delays=ExponentialBackOff(n = maxretries),
          check=(s,ex)->(s,isrecoverable(ex)))(Next, a...; kw...)
end


end # module RetryRequest
