module ExceptionRequest

export exceptionlayer

using ..IOExtras, ..Messages, ..Exceptions

"""
    exceptionlayer(handler) -> handler

Throw a `StatusError` if the request returns an error response status.
"""
function exceptionlayer(handler)
    return function exceptions(stream; status_exception::Bool=true, logerrors::Bool=false, kw...)
        res = handler(stream; logerrors=logerrors, kw...)
        if status_exception && iserror(res)
            req = res.request
            req.context[:status_errors] = get(req.context, :status_errors, 0) + 1
            e = StatusError(res.status, req.method, req.target, res)
            if logerrors
                @error "HTTP.StatusError" exception=(e, catch_backtrace()) method=req.method url=req.url context=req.context
            end
            throw(e)
        else
            return res
        end
    end
end

end # module ExceptionRequest
