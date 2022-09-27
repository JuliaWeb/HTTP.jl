module Exceptions

export @try, try_with_timeout, HTTPError, ConnectError, TimeoutError, StatusError, RequestError
using LoggingExtras
import ..HTTP # for doc references

@eval begin
"""
    @try Permitted Error Types expr

Convenience macro for wrapping an expression in a try/catch block
where thrown exceptions are ignored.
"""
macro $(:try)(exes...)
    errs = Any[exes...]
    ex = pop!(errs)
    isempty(errs) && error("no permitted errors")
    quote
        try $(esc(ex))
        catch e
            e isa InterruptException && rethrow(e)
            |($([:(e isa $(esc(err))) for err in errs]...)) || rethrow(e)
        end
    end
end
end # @eval

function try_with_timeout(f, shouldtimeout, delay, iftimeout=() -> nothing)
    @assert delay > 0
    cond = Condition()
    # execute f async
    t = @async try
        notify(cond, f())
    catch e
        @warnv 1 "error executing f in try_with_timeout"
        notify(cond, e)
    end
    # start a timer
    timer = Timer(delay; interval=delay / 10) do tm
        if shouldtimeout()
            @warnv 1 "❗️  Timeout: $delay"
            notify(cond, TimeoutError(delay))
            iftimeout()
            close(tm)
        end
    end
    res = wait(cond)
    @warnv 1 "try_with_timeout finished with: $res"
    if res isa TimeoutError
        # timedout
        throw(res)
    end
    # didn't timeout
    close(timer)
    if res isa Exception
        throw(res)
    end
    return res
end

abstract type HTTPError <: Exception end

"""
    HTTP.ConnectError

Raised when an error occurs while trying to establish a request connection to
the remote server. To see the underlying error, see the `error` field.
"""
struct ConnectError <: HTTPError
    url::String # the URL of the request
    error::Any # underlying error
end

"""
    HTTP.TimeoutError

Raised when a request times out according to `readtimeout` keyword argument provided.
"""
struct TimeoutError <: HTTPError
    readtimeout::Int
end

Base.showerror(io::IO, e::TimeoutError) =
    print(io, "TimeoutError: Connection closed after $(e.readtimeout) seconds")

"""
    HTTP.StatusError

Raised when an `HTTP.Response` has a `4xx`, `5xx` or unrecognised status code.

Fields:
 - `status::Int16`, the response status code.
 - `method::String`, the request method.
 - `target::String`, the request target.
 - `response`, the [`HTTP.Response`](@ref)
"""
struct StatusError <: HTTPError
    status::Int16
    method::String
    target::String
    response::Any
end

"""
    HTTP.RequestError

Raised when an error occurs while physically sending a request to the remote server
or reading the response back. To see the underlying error, see the `error` field.
"""
struct RequestError <: HTTPError
    request::Any
    error::Any
end

end # module Exceptions