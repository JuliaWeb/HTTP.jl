module TimeoutRequest

import ..Layer, ..request, ..lockedby
using ..ConnectionPool
import ..@debug, ..DEBUG_LEVEL


"""
    request(TimeoutLayer, ::IO, ::Request, body) -> HTTP.Response

Close `IO` if no data has been received for `timeout` seconds.
"""

abstract type TimeoutLayer{Next <: Layer} <: Layer end
export TimeoutLayer

function request(::Type{TimeoutLayer{Next}}, io::IO, req, body;
                 readtimeout::Int=60, kw...) where Next

    wait_for_timeout = Ref{Bool}(true)

    @async while wait_for_timeout[]
        if isreadable(io) && inactiveseconds(io) > readtimeout
            close(io)
            @debug 1 "💥  Read inactive > $(readtimeout)s: $io"
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
