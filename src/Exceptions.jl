module Exceptions

export @try, HTTPError, ConnectError, TimeoutError, StatusError, RequestError
import ..HTTP # for doc references

@eval begin
"""
    @try expr

Convenience macro for wrapping an expression in a try/catch block
where thrown exceptions are ignored.
"""
macro $(:try)(ex)
    quote
        try $(esc(ex))
        catch
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
