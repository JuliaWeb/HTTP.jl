module DebugRequest

import ..Layer, ..Layers
using ..IOExtras

const live_mode = true

include("IODebug.jl")

"""
    Layers.request(DebugLayer, ::IO, ::Request, body) -> HTTP.Response

Wrap the `IO` stream in an `IODebug` stream and print Message data.
"""
abstract type DebugLayer{Next <:Layer} <: Layer{Next} end
export DebugLayer

function Layers.request(::Type{DebugLayer{Next}}, io::IO, req, body; kw...) where Next

    @static if live_mode
        return Layers.request(Next, IODebug(io), req, body; kw...)
    else
        iod = IODebug(io)
        try
            return Layers.request(Next, iod, req, body; kw...)
        finally
            show_log(stdout, iod)
        end
    end
end

end # module DebugRequest
