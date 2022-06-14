module ExceptionRequest

export exceptionlayer

using ..Messages, ..Exceptions

"""
    exceptionlayer(handler) -> handler

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

end # module ExceptionRequest
