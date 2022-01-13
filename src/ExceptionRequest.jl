module ExceptionRequest

export StatusError

using ..Layers
import ..HTTP
using ..Messages: iserror

"""
    Layers.request(ExceptionLayer, ::Response) -> HTTP.Response

Throw a `StatusError` if the request returns an error response status.
"""
struct ExceptionLayer{Next <: Layer} <: ResponseLayer
    next::Next
end
export ExceptionLayer
Layers.keywordforlayer(::Val{:status_exception}) = ExceptionLayer
Layers.shouldinclude(::Type{<:ExceptionLayer}; status_exception::Bool=true) =
    status_exception
ExceptionLayer(next; kw...) = ExceptionLayer(next)

function Layers.request(layer::ExceptionLayer, resp)

    res = Layers.request(layer.next, resp)

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
