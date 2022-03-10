module DebugRequest

using ..Layers
import ..DEBUG_LEVEL
using ..IOExtras

const live_mode = true

include("IODebug.jl")

"""
    Layers.request(DebugLayer, ::IO, ::Request, body) -> HTTP.Response

Wrap the `IO` stream in an `IODebug` stream and print Message data.
"""
struct DebugLayer{Next <:Layer} <: ConnectionLayer
    next::Next
    verbose::Int
end
export DebugLayer
DebugLayer(next; verbose=0, kw...) = DebugLayer(next, verbose)

function Layers.request(layer::DebugLayer, ctx, io::IO, req, body)
    # if not debugging, just call to next layer
    if !(layer.verbose >= 3 || DEBUG_LEVEL[] >= 3)
        return Layers.request(layer.next, ctx, io, req, body)
    end
    @static if live_mode
        return Layers.request(layer.next, ctx, IODebug(io), req, body)
    else
        iod = IODebug(io)
        try
            return Layers.request(layer.next, ctx, iod, req, body)
        finally
            show_log(stdout, iod)
        end
    end
end

end # module DebugRequest
