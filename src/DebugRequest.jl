module DebugRequest

import ..Layer, ..request
using HTTP
using ..IOExtras

const live_mode = true

include("IODebug.jl")

"""
    request(DebugLayer, ::IO, ::Request, body) -> HTTP.Response

Wrap the `IO` stream in an `IODebug` stream and print Message data.
"""
abstract type DebugLayer <: Layer end
export DebugLayer

function request(stack::Stack{DebugLayer}, io::IO, req, body; kw...)

    @static if live_mode
        return request(stack.next, IODebug(io), req, body; kw...)
    else
        iod = IODebug(io)
        try
            return request(stack.next, iod, req, body; kw...)
        finally
            show_log(stdout, iod)
        end
    end
end

end # module DebugRequest
