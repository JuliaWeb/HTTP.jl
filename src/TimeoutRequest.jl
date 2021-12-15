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
struct TimeoutLayer{Next <: Layer} <: ConnectionLayer
    next::Next
    readtimeout::Int
end
export TimeoutLayer
Layers.keywordforlayer(::Val{:readtimeout}) = TimeoutLayer

TimeoutLayer(next; readtimeout::Int=0, kw...) = TimeoutLayer(next, readtimeout)

function request(layer::TimeoutLayer, io::IO, req, body; kw...)
    readtimeout = layer.readtimeout
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
        return request(layer.next, io, req, body; kw...)
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
