module DebugRequest

import ..DEBUG_LEVEL
using ..IOExtras
import ..Streams: Stream

include("IODebug.jl")

export debuglayer

"""
    debuglayer(ctx, stream::Stream) -> HTTP.Response

Wrap the `IO` stream in an `IODebug` stream and print Message data.
"""
function debuglayer(handler)
    return function(ctx, stream::Stream; verbose::Int=0, kw...)
        # if debugging, wrap stream.stream in IODebug
        if verbose >= 3 || DEBUG_LEVEL[] >= 3
            stream = Stream(stream.message, IODebug(stream.stream))
        end
        return handler(ctx, stream; verbose=verbose, kw...)
    end
end

end # module DebugRequest
