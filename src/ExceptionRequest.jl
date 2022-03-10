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
    status_exception::Bool
end
export ExceptionLayer
ExceptionLayer(next; status_exception::Bool=true) = ExceptionLayer(next, status_exception)

function Layers.request(layer::ExceptionLayer, ctx, resp)
    res = Layers.request(layer.next, ctx, resp)
    if layer.status_exception && iserror(res)
        throw(StatusError(res.status, res.request.method, res.request.target, res))
    else
        return res
    end
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
