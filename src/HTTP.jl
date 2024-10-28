module HTTP

using CodecZlib, URIs, Mmap, Base64
using LibAwsCommon, LibAwsIO, LibAwsHTTP

export WebSockets

include("utils.jl")
include("types.jl")

# we use finalizers only because Clients are meant to be global consts and never
# short-lived, temporary objects that should clean themselves up efficiently
mutable struct Client
    scheme::SubString{String}
    host::SubString{String}
    port::UInt32
    allocator::Ptr{aws_allocator}
    socket_options::Base.RefValue{aws_socket_options}
    tls_options::Base.RefValue{aws_tls_connection_options}
    retry_options::Base.RefValue{aws_standard_retry_options}
    retry_strategy::Ptr{Cvoid}
    retry_timeout_ms::Int
    conn_manager_opts::Base.RefValue{aws_http_connection_manager_options}
    connection_manager::Ptr{Cvoid}

    function Client(scheme::SubString{String}, host::SubString{String}, port::UInt32, require_ssl_verification::Bool;
        allocator=default_aws_allocator(),
        bootstrap=default_aws_client_bootstrap(),
        event_loop_group=default_aws_event_loop_group(),
        # retry options
        max_retries::Integer=10,
        backoff_scale_factor_ms::Integer=25,
        max_backoff_secs::Integer=20,
        jitter_mode::aws_exponential_backoff_jitter_mode=AWS_EXPONENTIAL_BACKOFF_JITTER_DEFAULT,
        retry_timeout_ms::Integer=60000,
        initial_bucket_capacity::Integer=500,
        # socket options
        socket_domain=:ipv4,
        connect_timeout_ms::Integer=3000,
        keep_alive_interval_sec::Integer=0,
        keep_alive_timeout_sec::Integer=0,
        keep_alive_max_failed_probes::Integer=0,
        keepalive::Bool=false,
        # tls options
        ssl_cert=nothing,
        ssl_key=nothing,
        ssl_capath=nothing,
        ssl_cacert=nothing,
        ssl_insecure=!require_ssl_verification,
        ssl_alpn_list="h2;http/1.1",
        # connection manager options
        max_connections::Integer=512,
        max_connection_idle_in_milliseconds::Integer=60000,
        enable_read_back_pressure::Bool=false,
        # other options
        http2_prior_knowledge::Bool=false
    )
        # retry strategy
        exp_back_opts = aws_exponential_backoff_retry_options(
            event_loop_group,
            max_retries,
            backoff_scale_factor_ms,
            max_backoff_secs,
            jitter_mode,
            C_NULL, # generate_random
            C_NULL, # generate_random_impl
            C_NULL, # generate_random_user_data
            C_NULL, # shutdown_options::Ptr{aws_shutdown_callback_options}
        )
        retry_opts = Ref(aws_standard_retry_options(
            exp_back_opts,
            initial_bucket_capacity
        ))
        retry_strategy = aws_retry_strategy_new_standard(allocator, retry_opts)
        retry_strategy == C_NULL && aws_throw_error()
        # socket options
        socket_options = Ref(aws_socket_options(
            AWS_SOCKET_STREAM, # socket type
            socket_domain == :ipv4 ? AWS_SOCKET_IPV4 : AWS_SOCKET_IPV6, # socket domain
            connect_timeout_ms,
            keep_alive_interval_sec,
            keep_alive_timeout_sec,
            keep_alive_max_failed_probes,
            keepalive,
            ntuple(x -> Cchar(0), 16) # network_interface_name
        ))
        # tls options
        host_str = String(host)
        if scheme == "https" || scheme == "wss"
            tls_options = Ref(LibAwsIO.tlsoptions(host_str;
                ssl_cert,
                ssl_key,
                ssl_capath,
                ssl_cacert,
                ssl_insecure,
                ssl_alpn_list
            ))
        else
            tls_options = Ref{aws_tls_connection_options}()
        end
        conn_manager_opts = Ref(aws_http_connection_manager_options(
            bootstrap,
            typemax(Csize_t), # initial_window_size::Csize_t
            Base.unsafe_convert(Ptr{aws_socket_options}, socket_options),
            scheme == "https" || scheme == "wss" ? Base.unsafe_convert(Ptr{aws_tls_connection_options}, tls_options) : C_NULL,
            http2_prior_knowledge,
            C_NULL, # monitoring_options::Ptr{aws_http_connection_monitoring_options}
            aws_byte_cursor_from_c_str(host_str),
            port % UInt32,
            C_NULL, # initial_settings_array::Ptr{aws_http2_setting}
            0, # num_initial_settings::Csize_t
            0, # max_closed_streams::Csize_t
            false, # http2_conn_manual_window_management::Bool
            C_NULL, # proxy_options::Ptr{aws_http_proxy_options}
            C_NULL, # proxy_ev_settings::Ptr{proxy_env_var_settings}
            max_connections, # max_connections::Csize_t, 512
            C_NULL, # shutdown_complete_user_data::Ptr{Cvoid}
            C_NULL, # shutdown_complete_callback::Ptr{aws_http_connection_manager_shutdown_complete_fn}
            enable_read_back_pressure, # enable_read_back_pressure::Bool
            max_connection_idle_in_milliseconds,
            C_NULL, # network_interface_names_array
            0, # num_network_interface_names
        ))
        connection_manager = aws_http_connection_manager_new(allocator, conn_manager_opts)
        connection_manager == C_NULL && aws_throw_error()
        client = new(scheme, host, port, allocator, socket_options, tls_options, retry_opts, retry_strategy, retry_timeout_ms, conn_manager_opts, connection_manager)
        finalizer(client) do x
            if x.connection_manager != C_NULL
                aws_http_connection_manager_release(x.connection_manager)
                x.connection_manager = C_NULL
            end
            if x.retry_strategy != C_NULL
                aws_retry_strategy_release(x.retry_strategy)
                x.retry_strategy = C_NULL
            end
        end
        return client
    end
end

struct Clients
    lock::ReentrantLock
    clients::Dict{Tuple{SubString{String}, SubString{String}, UInt32, Bool}, Client}
end

Clients() = Clients(ReentrantLock(), Dict{Tuple{SubString{String}, SubString{String}, UInt32, Bool}, Client}())

const CLIENTS = Clients()

function getclient(key::Tuple{SubString{String}, SubString{String}, UInt32, Bool})
    Base.@lock CLIENTS.lock begin
        if haskey(CLIENTS.clients, key)
            return CLIENTS.clients[key]
        else
            client = Client(key...)
            CLIENTS.clients[key] = client
            return client
        end
    end
end

mutable struct RequestContext
    client::Client
    retry_token::Ptr{aws_retry_token}
    should_retry::Bool
    completed::Threads.Event
    error::Union{Nothing, Exception}
    request::Request
    request_body::Any
    body_byte_cursor::aws_byte_cursor
    response::Response
    temp_response_body::Any
    gzip_decompressing::Bool
    error_response_body::Union{Nothing, Vector{UInt8}}
    request_options::Base.RefValue{aws_http_make_request_options}
    connection::Ptr{Cvoid}
    stream::Ptr{Cvoid}
    decompress::Union{Nothing, Bool}
    status_exception::Bool
    retry_non_idempotent::Bool
    modifier::Any # f(::Request) -> Nothing
    readtimeout::Int # milliseconds
    verbose::Int
end

function RequestContext(client, request, response, args...)
    return RequestContext(client, C_NULL, false, Threads.Event(), nothing, request, nothing, aws_byte_cursor(0, C_NULL), response, nothing, false, nothing, Ref{aws_http_make_request_options}(), C_NULL, C_NULL, args...)
end

struct StatusError <: Exception
    request::Request
    response::Response
end

function Base.showerror(io::IO, e::StatusError)
    println(io, "HTTP.StatusError:")
    println(io, "  request:")
    print_request(io, e.request)
    println(io, "  response:")
    print_response(io, e.response)
    return
end

# backwards compatibility
function Base.getproperty(e::StatusError, s::Symbol)
    if s == :status
        return e.response.status
    elseif s == :method
        return e.request.method
    elseif s == :target
        return e.request.target
    else
        return getfield(e, s)
    end
end

const USER_AGENT = Ref{Union{String, Nothing}}("HTTP.jl/$VERSION")

"""
    setuseragent!(x::Union{String, Nothing})

Set the default User-Agent string to be used in each HTTP request.
Can be manually overridden by passing an explicit `User-Agent` header.
Setting `nothing` will prevent the default `User-Agent` header from being passed.
"""
function setuseragent!(x::Union{String, Nothing})
    USER_AGENT[] = x
    return
end

include("forms.jl"); using .Forms
include("redirects.jl"); 
include("client.jl")
include("websockets.jl"); using .WebSockets
include("server.jl")
include("handlers.jl")
include("statuses.jl")

const LOGGER_FILE_REF = Ref{Libc.FILE}()
const LOGGER_OPTIONS = Ref{aws_logger_standard_options}()
const LOGGER = Ref{Ptr{Cvoid}}(C_NULL)

#NOTE: this is global process logging in the aws-crt libraries; not appropriate for request-level
# logging, but more for debugging the library itself
function set_log_level!(level::Integer)
    @assert 0 <= level <= 7 "log level must be between 0 and 7"
    @assert aws_logger_set_log_level(LOGGER[], aws_log_level(level)) == 0
    return
end

function __init__()
    allocator = default_aws_allocator()
    LibAwsHTTP.init(allocator)
    # initialize logger
    LOGGER[] = aws_mem_acquire(allocator, 64)
    LOGGER_FILE_REF[] = Libc.FILE(Libc.RawFD(1), "w")
    LOGGER_OPTIONS[] = aws_logger_standard_options(aws_log_level(3), C_NULL, Ptr{Libc.FILE}(LOGGER_FILE_REF[].ptr))
    @assert aws_logger_init_standard(LOGGER[], allocator, LOGGER_OPTIONS) == 0
    aws_logger_set(LOGGER[])
    # intialize c functions
    on_acquired[] = @cfunction(c_on_acquired, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}, Ptr{Cvoid}))
    on_shutdown[] = @cfunction(c_on_shutdown, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    on_setup[] = @cfunction(c_on_setup, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    on_response_headers[] = @cfunction(c_on_response_headers, Cint, (Ptr{Cvoid}, Cint, Ptr{aws_http_header}, Csize_t, Ptr{Cvoid}))
    on_response_header_block_done[] = @cfunction(c_on_response_header_block_done, Cint, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    on_response_body[] = @cfunction(c_on_response_body, Cint, (Ptr{Cvoid}, Ptr{aws_byte_cursor}, Ptr{Cvoid}))
    on_metrics[] = @cfunction(c_on_metrics, Cvoid, (Ptr{Cvoid}, Ptr{StreamMetrics}, Ptr{Cvoid}))
    on_complete[] = @cfunction(c_on_complete, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    on_destroy[] = @cfunction(c_on_destroy, Cvoid, (Ptr{Cvoid},))
    retry_ready[] = @cfunction(c_retry_ready, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    on_incoming_connection[] = @cfunction(c_on_incoming_connection, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    on_connection_shutdown[] = @cfunction(c_on_connection_shutdown, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    on_incoming_request[] = @cfunction(c_on_incoming_request, Ptr{aws_http_stream}, (Ptr{aws_http_connection}, Ptr{Cvoid}))
    on_request_headers[] = @cfunction(c_on_request_headers, Cint, (Ptr{aws_http_stream}, Ptr{aws_http_header_block}, Ptr{Ptr{aws_http_header}}, Csize_t, Ptr{Cvoid}))
    on_request_header_block_done[] = @cfunction(c_on_request_header_block_done, Cint, (Ptr{aws_http_stream}, Ptr{aws_http_header_block}, Ptr{Cvoid}))
    on_request_body[] = @cfunction(c_on_request_body, Cint, (Ptr{aws_http_stream}, Ptr{aws_byte_cursor}, Ptr{Cvoid}))
    on_request_done[] = @cfunction(c_on_request_done, Cint, (Ptr{aws_http_stream}, Ptr{Cvoid}))
    on_server_complete[] = @cfunction(c_on_server_complete, Cint, (Ptr{aws_http_connection}, Cint, Ptr{Cvoid}))
    on_destroy_complete[] = @cfunction(c_on_destroy_complete, Cvoid, (Ptr{Cvoid},))
    return
end

end
