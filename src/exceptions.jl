module Exceptions

export @try, HTTPError, ConnectError, TimeoutError, RequestError, current_exceptions_to_string

@eval begin
"""
    @try PermittedErrorTypes expr

Convenience macro for wrapping an expression in a try/catch block where thrown
exceptions are ignored if they match one of the permitted types.
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
end

abstract type HTTPError <: Exception end

"""
    HTTP.ConnectError

Raised when an error occurs while trying to establish a request connection to
the remote server. The underlying error is stored in `error`.
"""
struct ConnectError <: HTTPError
    url::String
    error::Any
end

function Base.showerror(io::IO, e::ConnectError)
    print(io, "HTTP.ConnectError for url = `$(e.url)`: ")
    Base.showerror(io, e.error)
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
    HTTP.RequestError

Raised when an error occurs while physically sending a request to the remote server
or reading the response back. The underlying error is stored in `error`.
"""
struct RequestError <: HTTPError
    request::Any
    error::Any
end

function Base.showerror(io::IO, e::RequestError)
    println(io, "HTTP.RequestError:")
    println(io, "HTTP.Request:")
    Base.show(io, e.request)
    println(io, "Underlying error:")
    Base.showerror(io, e.error)
end

function current_exceptions_to_string()
    buf = IOBuffer()
    println(buf)
    println(buf, "\n===========================\nHTTP Error message:\n")
    exc = @static if VERSION >= v"1.8.0-"
        Base.current_exceptions()
    else
        Base.catch_stack()
    end
    Base.display_error(buf, exc)
    return String(take!(buf))
end

end # module Exceptions
