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
        if isreadable(io) && inactiveseconds(io) > timeout
            close(io)
            @debug 1 "💥  Read inactive > $(timeout)s: $io"
            break
        end
        sleep(8 + rand() * 4)
    end

    try
        return request(Next, io, req, body; kw...)
    finally 
        wait_for_timeout[] = false
    end
end


end # module TimeoutRequest
