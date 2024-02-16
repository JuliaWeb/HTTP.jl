module TimeoutRequest

using ..Connections, ..Streams, ..Exceptions, ..Messages
using LoggingExtras, ConcurrentUtilities
using ..Exceptions: current_exceptions_to_string

export timeoutlayer

"""
    timeoutlayer(handler) -> handler

Close the `HTTP.Stream` if no data has been received for `readtimeout` seconds.
"""
function timeoutlayer(handler)
    return function timeouts(stream::Stream; readtimeout::Int=0, logerrors::Bool=false, logtag=nothing, kw...)
        if readtimeout <= 0
            # skip
            return handler(stream; logerrors=logerrors, kw...)
        end
        return try
            try_with_timeout(readtimeout, Response) do timedout
                handler(stream; logerrors=logerrors, logtag=logtag, timedout=timedout, kw...)
            end
        catch e
            if e isa ConcurrentUtilities.TimeoutException
                req = stream.message.request
                req.context[:timeout_errors] = get(req.context, :timeout_errors, 0) + 1
                if logerrors
                    @error current_exceptions_to_string() type=Symbol("HTTP.TimeoutError") method=req.method url=req.url context=req.context timeout=readtimeout logtag=logtag
                end
                e = Exceptions.TimeoutError(readtimeout)
            end
            rethrow(e)
        end
    end
end

end # module TimeoutRequest
