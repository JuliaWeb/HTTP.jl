module DebugRequest

import ..Layer, ..request
using ..IOExtras

const live_mode = true

include("IODebug.jl")

"""
    request(DebugLayer, ::IO, ::Request, body) -> HTTP.Response

Wrap the `IO` stream in an `IODebug` stream and print Message data.
"""
abstract type DebugLayer{Next <:Layer} <: Layer end
export DebugLayer

function request(::Type{DebugLayer{Next}}, io::IO, req, body; kw...) where Next

    @static if live_mode
        return request(Next, IODebug(io), req, body; kw...)
    else
        iod = IODebug(io)
        try
            return request(Next, iod, req, body; kw...)
        finally
            show_log(stdout, iod)
        end
    end
end

end # module DebugRequest
