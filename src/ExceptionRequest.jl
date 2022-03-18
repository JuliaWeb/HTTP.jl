module ExceptionRequest

export StatusError

import ..HTTP
using ..Messages: iserror

export exceptionlayer

"""
    exceptionlayer(ctx, stream) -> HTTP.Response

Throw a `StatusError` if the request returns an error response status.
"""
function exceptionlayer(handler)
    return function(stream; status_exception::Bool=true, kw...)
        res = handler(stream; kw...)
        if status_exception && iserror(res)
            throw(StatusError(res.status, res.request.method, res.request.target, res))
        else
            return res
        end
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
