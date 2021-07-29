module ExceptionRequest

export StatusError

import ..Layer, ..request
import ..HTTP
using ..Messages: iserror

"""
    request(ExceptionLayer, ::URI, ::Request, body) -> HTTP.Response

Throw a `StatusError` if the request returns an error response status.
"""
abstract type ExceptionLayer{Next <: Layer} <: Layer{Next} end
export ExceptionLayer

function request(::Type{ExceptionLayer}, stack::Vector{Type}, a...; kw...)

    next, stack... = stack
    res = request(next, stack, a...; kw...)

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
