module TimeoutRequest

import ..Layer, ..request
using ..ConnectionPool
import ..@debug, ..DEBUG_LEVEL

struct ReadTimeoutError <:Exception
    readtimeout::Int
end

function Base.showerror(io::IO, e::ReadTimeoutError)
    print(io, "ReadTimeoutError: Connection closed after $(e.readtimeout) seconds")
end

"""
    request(TimeoutLayer, ::IO, ::Request, body) -> HTTP.Response

Close `IO` if no data has been received for `timeout` seconds.
"""
abstract type TimeoutLayer{Next <: Layer} <: Layer{Next} end
export TimeoutLayer

function request(::Type{TimeoutLayer{Next}}, io::IO, req, body;
                 readtimeout::Int=0, kw...) where Next

    wait_for_timeout = Ref{Bool}(true)
    timedout = Ref{Bool}(false)

    @async while wait_for_timeout[]
        if isreadable(io) && inactiveseconds(io) > readtimeout
            timedout[] = true
            close(io)
            @debug 1 "💥  Read inactive > $(readtimeout)s: $io"
            break
        end
        sleep(readtimeout / 10)
    end

    try
        return request(Next, io, req, body; kw...)
    catch e
        if timedout[]
           throw(ReadTimeoutError(readtimeout))
        end
        rethrow(e)
    finally
        wait_for_timeout[] = false
    end
end


end # module TimeoutRequest
