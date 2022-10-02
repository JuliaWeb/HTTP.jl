module DebugRequest

using Logging, LoggingExtras
import ..DEBUG_LEVEL

export debuglayer

"""
    debuglayer(handler) -> handler

If the positive `verbose` keyword arg passed to the `handler`, then enable
debug logging with verbosity `verbose` for the lifetime of the request.
If no `verbose` is specified, it defaults to the *HTTP.jl* global `DEBUG_LEVEL[]`.
"""
function debuglayer(handler)
    return function(request; verbose=DEBUG_LEVEL[], kw...)
        # if debugging, enable by wrapping request in custom logger logic
        if verbose > 0
            LoggingExtras.withlevel(Logging.Debug; verbosity=verbose) do
                handler(request; verbose, kw...)
            end
        else
            return handler(request; verbose, kw...)
        end
    end
end

end # module DebugRequest
