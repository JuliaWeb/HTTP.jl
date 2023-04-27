module TimeoutRequest

using ..Connections, ..Streams, ..Exceptions
using LoggingExtras

export timeoutlayer

"""
    timeoutlayer(handler) -> handler

Close the `HTTP.Stream` if no data has been received for `readtimeout` seconds.
"""
function timeoutlayer(handler)
    return function timeouts(stream::Stream; readtimeout::Int=0, logerrors::Bool=false, kw...)
        if readtimeout <= 0
            # skip
            return handler(stream; logerrors=logerrors, kw...)
        end
        return try
            try_with_timeout(readtimeout) do
                handler(stream; logerrors=logerrors, kw...)
            end
        catch e
            if e isa TimeoutError
                req = stream.message.request
                if logerrors
                    @error "HTTP.TimeoutError" exception=(e, catch_backtrace()) method=req.method url=req.url context=req.context
                end
                req.context[:timeout_errors] = get(req.context, :timeout_errors, 0) + 1
            end
            rethrow()
        end
    end
end

end # module TimeoutRequest
