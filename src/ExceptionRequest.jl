module ExceptionRequest

import ..Layer, ..RequestStack.request
using ..Messages

abstract type ExceptionLayer{Next <: Layer} <: Layer end
export ExceptionLayer
export StatusError


struct StatusError <: Exception
    status::Int16
    response::Messages.Response
end


function request(::Type{ExceptionLayer{Next}}, a...; kw...) where Next

    res = request(Next, a...; kw...)

    if iserror(res)
        throw(StatusError(res.status, res))
    end

    return res
end


end # module ExceptionRequest
