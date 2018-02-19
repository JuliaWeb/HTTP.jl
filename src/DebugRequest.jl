module DebugRequest

import ..Layer, ..request
using ..IOExtras
import ..ConnectionPool: ByteView, byteview


include("IODebug.jl")


"""
    request(DebugLayer, ::IO, ::Request, body) -> HTTP.Response

Wrap the `IO` stream in an `IODebug` stream and print Message data.
"""
abstract type DebugLayer{Next <:Layer} <: Layer end
export DebugLayer


function request(::Type{DebugLayer{Next}}, io::IO, req, body; kw...) where Next

    iod = IODebug(io)

    try
        return request(Next, iod, req, body; kw...)
    finally
        print(STDOUT, iod)
    end
end


end # module DebugRequest
