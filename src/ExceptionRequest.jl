module ExceptionRequest

struct ExceptionLayer{T} end
export ExceptionLayer
export StatusError

import ..HTTP.RequestStack.request

using ..Messages


struct StatusError <: Exception
    status::Int16
    response::Messages.Response
end


function request(::Type{ExceptionLayer{Next}}, a...; kw...) where Next

    res = request(Next, a...; kw...)

    if iserror(res) && !isredirect(res)
        throw(StatusError(res.status, res))
    end

    return res
end


end # module ExceptionRequest
