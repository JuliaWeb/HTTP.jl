module TimeoutRequest

using ..ConnectionPool
import ..@debug, ..DEBUG_LEVEL
import ..Streams: Stream

struct ReadTimeoutError <:Exception
    readtimeout::Int
end

function Base.showerror(io::IO, e::ReadTimeoutError)
    print(io, "ReadTimeoutError: Connection closed after $(e.readtimeout) seconds")
end

export timeoutlayer

"""
    timeoutlayer(stream) -> HTTP.Response

Close `IO` if no data has been received for `timeout` seconds.
"""
function timeoutlayer(handler)
    return function(stream::Stream; readtimeout::Int=0, kw...)
        if readtimeout <= 0
            # skip
            return handler(stream; kw...)
        end
        io = stream.stream
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
            return handler(stream; kw...)
        catch e
            if timedout[]
            throw(ReadTimeoutError(readtimeout))
            end
            rethrow(e)
        finally
            wait_for_timeout[] = false
        end
    end
end


end # module TimeoutRequest
