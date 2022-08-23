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
        return try_with_timeout(() -> shouldtimeout(io, readtimeout), readtimeout) do
            handler(stream; kw...)
        end
    end
end

end # module TimeoutRequest
