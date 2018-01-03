module ExceptionRequest

export StatusError

import ..Layer, ..request
using ..Messages


"""
    request(ExceptionLayer, ::URI, ::Request, body) -> HTTP.Response

Throw a `StatusError` if the request returns an error response status.
"""

abstract type ExceptionLayer{Next <: Layer} <: Layer end
export ExceptionLayer

function request(::Type{ExceptionLayer{Next}}, a...; kw...) where Next

    res = request(Next, a...; kw...)

    if iserror(res)
        throw(StatusError(res.status, res))
    end

    return res
end


struct StatusError <: Exception
    status::Int16
    response::Messages.Response
end


end # module ExceptionRequest
