module Exceptions

export @try, HTTPError, ConnectError, TimeoutError, StatusError, RequestError, current_exceptions_to_string
using LoggingExtras, ExceptionUnwrapping
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

ExceptionUnwrapping.unwrap_exception(e::ConnectError) = e.error

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

ExceptionUnwrapping.unwrap_exception(e::RequestError) = e.error

function current_exceptions_to_string(curr_exc)
    buf = IOBuffer()
    println(buf)
    println(buf, "\n===========================\nHTTP Error message:\n")
    Base.showerror(buf, curr_exc)
    return String(take!(buf))
end

end # module Exceptions