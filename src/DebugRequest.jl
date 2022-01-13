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
end
export DebugLayer
Layers.keywordforlayer(::Val{:verbose}) = DebugLayer
Layers.shouldinclude(::Type{DebugLayer}; verbose=0, kw...) = (verbose >= 3 || DEBUG_LEVEL[] >= 3)
DebugLayer(next; kw...) = DebugLayer(next)

function Layers.request(layer::DebugLayer, io::IO, req, body)

    @static if live_mode
        return Layers.request(layer.next, IODebug(io), req, body)
    else
        iod = IODebug(io)
        try
            return Layers.request(layer.next, iod, req, body)
        finally
            show_log(stdout, iod)
        end
    end
end

end # module DebugRequest
