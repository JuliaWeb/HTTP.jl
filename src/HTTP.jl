module HTTP

using CodecZlib, URIs, Mmap, Base64, Dates
using Reseau
include("awshttp/AwsHTTP.jl")

export HTTPVersion
export startwrite, startread, closewrite, closeread
export @logfmt_str, common_logfmt, combined_logfmt
export WebSockets
export Pool, default_connection_limit, set_default_connection_limit!, closeall

const nobody = UInt8[]

Base.@deprecate escape escapeuri

include("utils.jl")
include("statistics.jl")
include("access_log.jl")
include("sniff.jl"); using .Sniff
include("forms.jl"); using .Forms
include("requestresponse.jl")
include("exceptions.jl"); using .Exceptions
struct StatusError <: HTTPError
    request_method::String
    request_uri::URI
    response::Response
end

# backwards compatibility
function Base.getproperty(e::StatusError, s::Symbol)
    if s == :status
        return e.response.status
    elseif s == :method
        return e.request_method
    elseif s == :target
        return e.request_uri
    else
        return getfield(e, s)
    end
end

function Base.showerror(io::IO, e::StatusError)
    println(io, "HTTP.StatusError:")
    println(io, "  Request method: $(e.request_method)")
    println(io, "  Request URI: $(e.request_uri)")
    println(io, "  response:")
    print_response(io, e.response)
    return
end

include("cookies.jl"); using .Cookies
include("client/redirects.jl")
include("client/client.jl")
include("client/retry.jl")
include("client/connection.jl")
include("client/request.jl")
include("client/stream.jl")
include("client/makerequest.jl")
include("client/open.jl")
include("download.jl")
include("websockets.jl"); using .WebSockets
include("server.jl")
include("handlers.jl"); using .Handlers
include("statuses.jl")

#NOTE: this is process-level logging; not appropriate for request-level
# logging, but more for debugging the library itself
function set_log_level!(level::Integer)
    @assert 0 <= level <= 7 "log level must be between 0 and 7"
    Reseau.set_log_level!(Reseau.logger_get(), Reseau.LogLevel.T(level))
    return
end

function __init__()
    AwsHTTP.http_library_init()
    return
end

# only run if precompiling
if VERSION >= v"1.9.0-0" && ccall(:jl_generating_output, Cint, ()) == 1
    do_precompile = true
    try
        isempty(Reseau.getalladdrinfo("localhost")) && error("localhost cannot be resolved")
    catch ex
        @debug "Skipping precompilation workload because localhost cannot be resolved. Check firewall settings" exception=(ex,catch_backtrace())
        do_precompile = false
    end
    # do_precompile && include("precompile.jl")
end

end
