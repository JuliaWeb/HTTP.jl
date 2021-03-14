module ExceptionRequest

export StatusError

import ..Layer, ..Layers
import ..HTTP
using ..Messages: iserror

"""
    Layers.request(ExceptionLayer, ::URI, ::Request, body) -> HTTP.Response

Throw a `StatusError` if the request returns an error response status.
"""
abstract type ExceptionLayer{Next <: Layer} <: Layer{Next} end
export ExceptionLayer

function Layers.request(::Type{ExceptionLayer{Next}}, a...; kw...) where Next

    res = Layers.request(Next, a...; kw...)

    if iserror(res)
        throw(StatusError(res.status, res.request.method, res.request.target, res))
    end

    return res
end

"""
    StatusError <: Exception

The `Response` has a `4xx`, `5xx` or unrecognised status code.

Fields:
 - `status::Int16`, the response status code.
 - `response` the [`HTTP.Response`](@ref)
"""
struct StatusError <: Exception
    status::Int16
    method::String
    target::String
    response::HTTP.Response
end

# for backwards compatibility
StatusError(status, response::HTTP.Response) = StatusError(status, response.request.method, response.request.target, response)

end # module ExceptionRequest
