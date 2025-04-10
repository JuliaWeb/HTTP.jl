module HTTP

using CodecZlib, URIs, Mmap, Base64, Dates, Sockets
using LibAwsCommon, LibAwsIO, LibAwsHTTPFork
import LibAwsCommon: Future, FieldRef

export @logfmt_str, common_logfmt, combined_logfmt
export WebSockets

include("utils.jl")
include("access_log.jl")
include("sniff.jl"); using .Sniff
include("forms.jl"); using .Forms
include("requestresponse.jl")
include("cookies.jl"); using .Cookies
include("client/redirects.jl")
include("client/client.jl")
include("client/retry.jl")
include("client/connection.jl")
include("client/request.jl")
include("client/stream.jl")
include("client/makerequest.jl")
include("websockets.jl"); using .WebSockets
include("server.jl")
include("handlers.jl"); using .Handlers
include("statuses.jl")

struct StatusError <: Exception
    request_method::String
    request_uri::aws_uri
    response::Response
end

function Base.showerror(io::IO, e::StatusError)
    println(io, "HTTP.StatusError:")
    println(io, "  Request method: $(e.request_method)")
    println(io, "  Request URI: $(makeuri(e.request_uri))")
    println(io, "  response:")
    print_response(io, e.response)
    return
end

# backwards compatibility
function Base.getproperty(e::StatusError, s::Symbol)
    if s == :status
        return e.response.status
    elseif s == :method
        return e.request_method
    elseif s == :target
        return makeuri(e.request_uri)
    else
        return getfield(e, s)
    end
end

#NOTE: this is global process logging in the aws-crt libraries; not appropriate for request-level
# logging, but more for debugging the library itself
mutable struct AwsLogger
    ptr::Ptr{aws_logger}
    file_ref::Libc.FILE
    options::aws_logger_standard_options
    function AwsLogger(level::Integer, allocator::Ptr{aws_allocator})
        fr = Libc.FILE(Libc.RawFD(1), "w")
        opts = aws_logger_standard_options(aws_log_level(0), C_NULL, Ptr{Libc.FILE}(fr.ptr))
        x = new(Ptr{aws_logger}(aws_mem_acquire(allocator, 64)), fr, opts)
        aws_logger_init_standard(x.ptr, allocator, FieldRef(x, :options)) != 0 && aws_throw_error()
        aws_logger_set(x.ptr)
        return finalizer(x) do x
            aws_logger_clean_up(x.ptr)
            aws_mem_release(allocator, x.ptr)
        end
    end
end

const LOGGER = Ref{AwsLogger}()

function set_log_level!(level::Integer, allocator::Ptr{aws_allocator}=default_aws_allocator())
    @assert 0 <= level <= 7 "log level must be between 0 and 7"
    LOGGER[] = AwsLogger(level, allocator)
    @assert aws_logger_set_log_level(LOGGER[].ptr, aws_log_level(level)) == 0
    return
end

function __init__()
    allocator = default_aws_allocator()
    LibAwsHTTPFork.init(allocator)
    # intialize c functions
    on_acquired[] = @cfunction(c_on_acquired, Cvoid, (Ptr{Cvoid}, Cint, Ptr{aws_retry_token}, Ptr{Cvoid}))
    # on_shutdown[] = @cfunction(c_on_shutdown, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    on_setup[] = @cfunction(c_on_setup, Cvoid, (Ptr{aws_http_connection}, Cint, Ptr{Cvoid}))
    on_stream_write_on_complete[] = @cfunction(c_on_stream_write_on_complete, Cvoid, (Ptr{aws_http_stream}, Cint, Ptr{Cvoid}))
    on_response_headers[] = @cfunction(c_on_response_headers, Cint, (Ptr{Cvoid}, Cint, Ptr{aws_http_header}, Csize_t, Ptr{Cvoid}))
    on_response_header_block_done[] = @cfunction(c_on_response_header_block_done, Cint, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    on_response_body[] = @cfunction(c_on_response_body, Cint, (Ptr{Cvoid}, Ptr{aws_byte_cursor}, Ptr{Cvoid}))
    on_metrics[] = @cfunction(c_on_metrics, Cvoid, (Ptr{Cvoid}, Ptr{aws_http_stream_metrics}, Ptr{Cvoid}))
    on_complete[] = @cfunction(c_on_complete, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    on_destroy[] = @cfunction(c_on_destroy, Cvoid, (Ptr{Cvoid},))
    retry_ready[] = @cfunction(c_retry_ready, Cvoid, (Ptr{aws_retry_token}, Cint, Ptr{Cvoid}))
    on_incoming_connection[] = @cfunction(c_on_incoming_connection, Cvoid, (Ptr{Cvoid}, Ptr{aws_http_connection}, Cint, Ptr{Cvoid}))
    on_connection_shutdown[] = @cfunction(c_on_connection_shutdown, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    on_incoming_request[] = @cfunction(c_on_incoming_request, Ptr{aws_http_stream}, (Ptr{aws_http_connection}, Ptr{Cvoid}))
    on_request_headers[] = @cfunction(c_on_request_headers, Cint, (Ptr{aws_http_stream}, Ptr{aws_http_header_block}, Ptr{aws_http_header}, Csize_t, Ptr{Cvoid}))
    on_request_header_block_done[] = @cfunction(c_on_request_header_block_done, Cint, (Ptr{aws_http_stream}, Ptr{aws_http_header_block}, Ptr{Cvoid}))
    on_request_body[] = @cfunction(c_on_request_body, Cint, (Ptr{aws_http_stream}, Ptr{aws_byte_cursor}, Ptr{Cvoid}))
    on_request_done[] = @cfunction(c_on_request_done, Cint, (Ptr{aws_http_stream}, Ptr{Cvoid}))
    on_server_stream_complete[] = @cfunction(c_on_server_stream_complete, Cint, (Ptr{aws_http_connection}, Cint, Ptr{Cvoid}))
    on_destroy_complete[] = @cfunction(c_on_destroy_complete, Cvoid, (Ptr{Cvoid},))
    return
end

# only run if precompiling
if VERSION >= v"1.9.0-0" && ccall(:jl_generating_output, Cint, ()) == 1
    do_precompile = true
    try
        Sockets.getalladdrinfo("localhost")
    catch ex
        @debug "Skipping precompilation workload because localhost cannot be resolved. Check firewall settings" exception=(ex,catch_backtrace())
        do_precompile = false
    end
    # do_precompile && include("precompile.jl")
end

end
