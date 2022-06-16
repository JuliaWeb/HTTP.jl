module TimeoutRequest

using ..ConnectionPool, ..Streams, ..Exceptions
using LoggingExtras

export timeoutlayer

"""
    timeoutlayer(handler) -> handler

Close the `HTTP.Stream` if no data has been received for `readtimeout` seconds.
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
                @debugv 1 "💥  Read inactive > $(readtimeout)s: $io"
                break
            end
            sleep(readtimeout / 10)
        end

        try
            return handler(stream; kw...)
        catch e
            if timedout[]
                throw(TimeoutError(readtimeout))
            end
            rethrow(e)
        finally
            wait_for_timeout[] = false
        end
    end
end

end # module TimeoutRequest
