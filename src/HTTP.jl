module HTTP

using CodecZlib, URIs, Mmap, Base64
using LibAwsCommon, LibAwsIO, LibAwsHTTP

export WebSockets

include("utils.jl")
include("types.jl")

Base.@kwdef struct ClientSettings
    scheme::String
    host::String
    port::UInt32
    allocator::Ptr{aws_allocator} = default_aws_allocator()
    bootstrap::Ptr{aws_client_bootstrap} = default_aws_client_bootstrap()
    event_loop_group::Ptr{aws_event_loop_group} = default_aws_event_loop_group()
    socket_domain::Symbol = :ipv4
    connect_timeout_ms::Int = 3000
    keep_alive_interval_sec::Int = 0
    keep_alive_timeout_sec::Int = 0
    keep_alive_max_failed_probes::Int = 0
    keepalive::Bool = false
    ssl_cert::Union{Nothing, String} = nothing
    ssl_key::Union{Nothing, String} = nothing
    ssl_capath::Union{Nothing, String} = nothing
    ssl_cacert::Union{Nothing, String} = nothing
    ssl_insecure::Bool = false
    ssl_alpn_list::String = "h2;http/1.1"
    proxy_allow_env_var::Bool = true
    proxy_connection_type::Union{Nothing, Symbol} = nothing
    proxy_host::Union{Nothing, String} = nothing
    proxy_port::Union{Nothing, UInt32} = nothing
    proxy_ssl_cert::Union{Nothing, String} = nothing
    proxy_ssl_key::Union{Nothing, String} = nothing
    proxy_ssl_capath::Union{Nothing, String} = nothing
    proxy_ssl_cacert::Union{Nothing, String} = nothing
    proxy_ssl_insecure::Bool = false
    proxy_ssl_alpn_list::String = "h2;http/1.1"
    retry_partition::Union{Nothing, String} = nothing
    max_retries::Int = 10
    backoff_scale_factor_ms::Int = 25
    max_backoff_secs::Int = 20
    jitter_mode::aws_exponential_backoff_jitter_mode = AWS_EXPONENTIAL_BACKOFF_JITTER_DEFAULT
    retry_timeout_ms::Int = 60000
    initial_bucket_capacity::Int = 500
    max_connections::Int = 512
    max_connection_idle_in_milliseconds::Int = 60000
    enable_read_back_pressure::Bool = false
    http2_prior_knowledge::Bool = false
end

ClientSettings(scheme::AbstractString, host::AbstractString, port::UInt32; kw...) = ClientSettings(scheme=String(scheme), host=String(host), port=port, kw...)

# make a new ClientSettings object from an existing one w/ just different url values
@generated function ClientSettings(cs::ClientSettings, scheme::AbstractString, host::AbstractString, port::Integer)
    ex = :(ClientSettings(String(scheme), String(host), port % UInt32))
    for i = 4:fieldcount(ClientSettings)
        push!(ex.args, :(getfield(cs, $(Meta.quot(fieldname(ClientSettings, i))))))
    end
    return ex
end

mutable struct Client
    settings::ClientSettings
    socket_options::aws_socket_options
    tls_options::Union{Nothing, aws_tls_connection_options}
    # only 1 of proxy_options or proxy_env_settings is set
    proxy_options::Union{Nothing, aws_http_proxy_options}
    proxy_env_settings::Union{Nothing, proxy_env_var_settings}
    retry_options::aws_standard_retry_options
    retry_strategy::Ptr{aws_retry_strategy}
    conn_manager_opts::aws_http_connection_manager_options
    connection_manager::Ptr{aws_http_connection_manager}

    Client() = new()
end

Client(scheme::AbstractString, host::AbstractString, port::UInt32; kw...) = Client(ClientSettings(scheme, host, port; kw...))

function Client(cs::ClientSettings)
    client = Client()
    client.settings = cs
    # socket options
    client.socket_options = aws_socket_options(
        AWS_SOCKET_STREAM, # socket type
        cs.socket_domain == :ipv4 ? AWS_SOCKET_IPV4 : AWS_SOCKET_IPV6, # socket domain
        cs.connect_timeout_ms,
        cs.keep_alive_interval_sec,
        cs.keep_alive_timeout_sec,
        cs.keep_alive_max_failed_probes,
        cs.keepalive,
        ntuple(x -> Cchar(0), 16) # network_interface_name
    )
    # tls options
    if cs.scheme == "https" || cs.scheme == "wss"
        client.tls_options = LibAwsIO.tlsoptions(cs.host;
            cs.ssl_cert,
            cs.ssl_key,
            cs.ssl_capath,
            cs.ssl_cacert,
            cs.ssl_insecure,
            cs.ssl_alpn_list
        )
    else
        client.tls_options = nothing
    end
    # proxy options
    if cs.proxy_host !== nothing && cs.proxy_port !== nothing
        client.proxy_options = aws_http_proxy_options(
            cs.proxy_connection_type == :forward ? AWS_HPCT_HTTP_FORWARD : AWS_HPCT_HTTP_TUNNEL,
            aws_byte_cursor_from_c_str(cs.proxy_host),
            cs.proxy_port % UInt32,
            cs.proxy_ssl_cert === nothing ? C_NULL : LibAwsIO.tlsoptions(cs.proxy_host;
                cs.proxy_ssl_cert,
                cs.proxy_ssl_key,
                cs.proxy_ssl_capath,
                cs.proxy_ssl_cacert,
                cs.proxy_ssl_insecure,
                cs.proxy_ssl_alpn_list
            ),
            #TODO: support proxy_strategy
            C_NULL, # proxy_strategy::Ptr{aws_http_proxy_strategy}
            0, # auth_type::aws_http_proxy_authentication_type
            aws_byte_cursor_from_c_str(""), # auth_username::aws_byte_cursor
            aws_byte_cursor_from_c_str(""), # auth_password::aws_byte_cursor
        )
    elseif cs.proxy_allow_env_var
        client.proxy_env_settings = proxy_env_var_settings(
            AWS_HPEV_ENABLE,
            cs.proxy_connection_type == :forward ? AWS_HPCT_HTTP_FORWARD : AWS_HPCT_HTTP_TUNNEL,
            cs.proxy_ssl_cert === nothing ? C_NULL : LibAwsIO.tlsoptions(cs.proxy_host;
                cs.proxy_ssl_cert,
                cs.proxy_ssl_key,
                cs.proxy_ssl_capath,
                cs.proxy_ssl_cacert,
                cs.proxy_ssl_insecure,
                cs.proxy_ssl_alpn_list
            )
        )
    else
        client.proxy_options = nothing
    end
    # retry strategy
    exp_back_opts = aws_exponential_backoff_retry_options(
        cs.event_loop_group,
        cs.max_retries,
        cs.backoff_scale_factor_ms,
        cs.max_backoff_secs,
        cs.jitter_mode,
        C_NULL, # generate_random
        C_NULL, # generate_random_impl
        C_NULL, # generate_random_user_data
        C_NULL, # shutdown_options::Ptr{aws_shutdown_callback_options}
    )
    client.retry_options = aws_standard_retry_options(
        exp_back_opts,
        cs.initial_bucket_capacity
    )
    client.retry_strategy = aws_retry_strategy_new_standard(cs.allocator, FieldRef(client, :retry_options))
    client.retry_strategy == C_NULL && aws_throw_error()
    client.conn_manager_opts = aws_http_connection_manager_options(
        cs.bootstrap,
        typemax(Csize_t), # initial_window_size::Csize_t
        pointer(FieldRef(client, :socket_options)),
        (cs.scheme == "https" || cs.scheme == "wss") ? pointer(FieldRef(client, :tls_options)) : C_NULL,
        cs.http2_prior_knowledge,
        C_NULL, # monitoring_options::Ptr{aws_http_connection_monitoring_options}
        aws_byte_cursor_from_c_str(cs.host),
        cs.port % UInt32,
        C_NULL, # initial_settings_array::Ptr{aws_http2_setting}
        0, # num_initial_settings::Csize_t
        0, # max_closed_streams::Csize_t
        false, # http2_conn_manual_window_management::Bool
        client.proxy_options === nothing ? C_NULL : pointer(FieldRef(client, :proxy_options)), # proxy_options::Ptr{aws_http_proxy_options}
        client.proxy_env_settings === nothing ? C_NULL : pointer(FieldRef(client, :proxy_env_settings)), # proxy_env_settings::Ptr{proxy_env_var_settings}
        cs.max_connections, # max_connections::Csize_t, 512
        C_NULL, # shutdown_complete_user_data::Ptr{Cvoid}
        C_NULL, # shutdown_complete_callback::Ptr{aws_http_connection_manager_shutdown_complete_fn}
        cs.enable_read_back_pressure, # enable_read_back_pressure::Bool
        cs.max_connection_idle_in_milliseconds,
        C_NULL, # network_interface_names_array
        0, # num_network_interface_names
    )
    client.connection_manager = aws_http_connection_manager_new(cs.allocator, FieldRef(client, :conn_manager_opts))
    client.connection_manager == C_NULL && aws_throw_error()

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

#TODO: this should probably be a LRU cache to not grow indefinitely
struct Clients
    lock::ReentrantLock
    clients::Dict{ClientSettings, Client}
end

Clients() = Clients(ReentrantLock(), Dict{ClientSettings, Client}())

const CLIENTS = Clients()

function getclient(key::ClientSettings)
    Base.@lock CLIENTS.lock begin
        if haskey(CLIENTS.clients, key)
            return CLIENTS.clients[key]
        else
            client = Client(key)
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
include("retry.jl")
include("connection.jl")
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
    on_acquired[] = @cfunction(c_on_acquired, Cvoid, (Ptr{Cvoid}, Cint, Ptr{aws_retry_token}, Ptr{Cvoid}))
    # on_shutdown[] = @cfunction(c_on_shutdown, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    on_setup[] = @cfunction(c_on_setup, Cvoid, (Ptr{aws_http_connection}, Cint, Ptr{Cvoid}))
    # on_response_headers[] = @cfunction(c_on_response_headers, Cint, (Ptr{Cvoid}, Cint, Ptr{aws_http_header}, Csize_t, Ptr{Cvoid}))
    # on_response_header_block_done[] = @cfunction(c_on_response_header_block_done, Cint, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    # on_response_body[] = @cfunction(c_on_response_body, Cint, (Ptr{Cvoid}, Ptr{aws_byte_cursor}, Ptr{Cvoid}))
    # on_metrics[] = @cfunction(c_on_metrics, Cvoid, (Ptr{Cvoid}, Ptr{StreamMetrics}, Ptr{Cvoid}))
    # on_complete[] = @cfunction(c_on_complete, Cvoid, (Ptr{Cvoid}, Cint, Ptr{Cvoid}))
    # on_destroy[] = @cfunction(c_on_destroy, Cvoid, (Ptr{Cvoid},))
    retry_ready[] = @cfunction(c_retry_ready, Cvoid, (Ptr{aws_retry_token}, Cint, Ptr{Cvoid}))
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
