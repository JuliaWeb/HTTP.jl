module TimeoutRequest

import ..Layer, ..request, ..lockedby
using ..ConnectionPool
import ..@debug, ..DEBUG_LEVEL


abstract type TimeoutLayer{Next <: Layer} <: Layer end
export TimeoutLayer


"""
    request(TimeoutLayer{Connection, Next}, ::IO, ::Request, body)

Get a `Connection` for a `URI`, send a `Request` and fill in a `Response`.
"""

function request(::Type{TimeoutLayer{Next}}, io::IO, req, body;
                 timeout::Int=60, kw...) where Next

    wait_for_timeout = Ref{Bool}(true)
    request_task = current_task()

    @async while wait_for_timeout[]
        if islocked(io.readlock) &&
           lockedby(io.readlock) == request_task &&
           inactiveseconds(io) > timeout
            close(io)
            @debug 0 "💥  Read inactive > $(timeout)s: $io"
            break
        end
        sleep(10)
    end

    try
        return request(Next, io, req, body; kw...)
    finally 
        wait_for_timeout[] = false
    end
end


end # module TimeoutRequest
