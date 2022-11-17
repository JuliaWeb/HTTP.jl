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
        @debugv 1 "error executing f in try_with_timeout"
        isopen(timer) && notify(cond, e, error = true)
    end
    # start a timer
    timer = Timer(delay; interval=delay / 10) do tm
        try
            if shouldtimeout()
                @debugv 1 "❗️  Timeout: $delay"
                close(tm)
                iftimeout()
                notify(cond, TimeoutError(delay), error = true)
            end
        catch e
            @debugv 1 "callback error in try_with_timeout"
            close(tm)
            notify(cond, e, error = true)
        end
    end
    try
        res = wait(cond)
        @debugv 1 "try_with_timeout finished with: $res"
        res
    catch e
        @debugv 1 "try_with_timeout failed with: $e"
        rethrow()
    finally
        close(timer)
    end
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

"""
    HTTP.RequestWritingError

Raised when an error occurs while physically sending a request to the remote server.
To see the underlying error, see the `error` field.
Used 
"""
struct RequestWritingError <: HTTPError
    error::Any # underlying error
end

end # module Exceptions