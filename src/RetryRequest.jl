module RetryRequest

using Retry

import ..HTTP

export request

import ..SendRequest, ..@debug, ..getkv


isrecoverable(e::Base.UVError) = true
isrecoverable(e::Base.DNSError) = true
isrecoverable(e::Base.EOFError) = true
isrecoverable(e::HTTP.StatusError) = e.status < 200 || e.status >= 500
isrecoverable(e::Exception) = false


function request(a...; kw...)

    n = getkv(kw, :maxretries, 2) + 1

    @repeat n try
        return SendRequest.request(a...; kw...)
    catch e
        @delay_retry if isrecoverable(e)
            @debug 1 "Retrying after $e"
        end
    end

    @assert false "Unreachable"
end

end # module RetryRequest
