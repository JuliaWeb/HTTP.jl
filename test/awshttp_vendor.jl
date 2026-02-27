using Test
using HTTP
using Reseau
using Base64

const _VENDORED_AWSHTTP_TESTS = joinpath(@__DIR__, "awshttp_vendor", "http_tests.jl")

function _install_vendored_compat!()::Nothing
    AwsHTTP = HTTP.AwsHTTP
    @eval AwsHTTP begin
        if !isdefined(@__MODULE__, :_VENDORED_COMPAT_INSTALLED)
            const _VENDORED_COMPAT_INSTALLED = Ref(false)
        end
        if !_VENDORED_COMPAT_INSTALLED[]
            @inline function _legacy_invoke(cb, ud, args...)
                cb === nothing && return nothing
                if applicable(cb, args..., ud)
                    return cb(args..., ud)
                end
                return cb(args...)
            end
            @inline _legacy_stream_headers_cb(cb, ud) = cb === nothing ? nothing : ((s, b, h) -> Int(_legacy_invoke(cb, ud, s, b, h)))
            @inline _legacy_stream_header_block_done_cb(cb, ud) = cb === nothing ? nothing : ((s, b) -> Int(_legacy_invoke(cb, ud, s, b)))
            @inline _legacy_stream_body_cb(cb, ud) = cb === nothing ? nothing : ((s, d) -> Int(_legacy_invoke(cb, ud, s, d)))
            @inline _legacy_stream_metrics_cb(cb, ud) = cb === nothing ? nothing : ((s, m) -> begin _legacy_invoke(cb, ud, s, m); nothing end)
            @inline _legacy_stream_complete_cb(cb, ud) = cb === nothing ? nothing : ((s, ec) -> begin _legacy_invoke(cb, ud, s, ec); nothing end)
            @inline _legacy_stream_destroy_cb(cb, ud) = cb === nothing ? nothing : (s -> begin _legacy_invoke(cb, ud, s); nothing end)
            @inline _legacy_request_done_cb(cb, ud) = cb === nothing ? nothing : (s -> begin _legacy_invoke(cb, ud, s); nothing end)
            function _legacy_h2c_upgrade_result_cb(cb, ud)
                cb === nothing && return nothing
                return (h1_conn, h2_conn, h2_stream, error_code) -> begin
                    if applicable(cb, h2_stream, error_code, ud)
                        cb(h2_stream, error_code, ud)
                    elseif applicable(cb, h1_conn, h2_conn, h2_stream, error_code, ud)
                        cb(h1_conn, h2_conn, h2_stream, error_code, ud)
                    elseif applicable(cb, h1_conn, h2_conn, h2_stream, error_code)
                        cb(h1_conn, h2_conn, h2_stream, error_code)
                    elseif applicable(cb, h2_stream, error_code)
                        cb(h2_stream, error_code)
                    else
                        cb(h1_conn, h2_conn, h2_stream, error_code)
                    end
                    return nothing
                end
            end
            @inline _legacy_incoming_request_cb(cb, ud) = cb === nothing ? nothing : (conn -> _legacy_invoke(cb, ud, conn))
            @inline _legacy_connection_shutdown_cb(cb, ud) = cb === nothing ? nothing : ((conn, ec) -> begin _legacy_invoke(cb, ud, conn, ec); nothing end)
            function _legacy_h2c_upgrade_probe_cb(cb, ud)
                cb === nothing && return nothing
                return (conn, request_message) -> Bool(_legacy_invoke(cb, ud, conn, request_message))
            end

            if !isdefined(@__MODULE__, :HttpMakeRequestOptions)
                Base.@kwdef struct HttpMakeRequestOptions
                    request::HttpMessage
                    user_data::Any = nothing
                    on_response_headers::Any = nothing
                    on_response_header_block_done::Any = nothing
                    on_response_body::Any = nothing
                    on_metrics::Any = nothing
                    on_complete::Any = nothing
                    on_destroy::Any = nothing
                    response_first_byte_timeout_ms::UInt64 = UInt64(0)
                    http2_use_manual_data_writes::Bool = false
                    http2_priority::Any = nothing
                    http2_headers_pad_length::UInt32 = UInt32(0)
                    h2c_upgrade::Bool = false
                    on_h2c_upgrade::Any = nothing
                end
            end

            if !isdefined(@__MODULE__, :HttpRequestHandlerOptions)
                struct HttpRequestHandlerOptions
                    server_connection::Any
                    user_data::Any
                    on_request_headers::Any
                    on_request_header_block_done::Any
                    on_request_body::Any
                    on_request_done::Any
                    on_complete::Any
                    on_destroy::Any
                end
                function HttpRequestHandlerOptions(;
                    server_connection=nothing,
                    user_data=nothing,
                    on_request_headers=nothing,
                    on_request_header_block_done=nothing,
                    on_request_body=nothing,
                    on_request_done=nothing,
                    on_complete=nothing,
                    on_destroy=nothing,
                )
                    return HttpRequestHandlerOptions(
                        server_connection,
                        user_data,
                        on_request_headers,
                        on_request_header_block_done,
                        on_request_body,
                        on_request_done,
                        on_complete,
                        on_destroy,
                    )
                end
            end

            if !isdefined(@__MODULE__, :HttpServerConnectionOptions)
                Base.@kwdef struct HttpServerConnectionOptions
                    connection_user_data::Any = nothing
                    on_incoming_request::Any = nothing
                    on_h2c_upgrade::Any = nothing
                    on_shutdown::Any = nothing
                end
            end

            if !isdefined(@__MODULE__, :HttpServerOptions)
                Base.@kwdef struct HttpServerOptions
                    endpoint_host::String = "0.0.0.0"
                    endpoint_port::UInt32 = UInt32(0)
                    prior_knowledge_http2::Bool = false
                    initial_window_size::Csize_t = typemax(Csize_t)
                    manual_window_management::Bool = false
                    event_loop_group::Union{EventLoops.EventLoopGroup, Nothing} = nothing
                    socket_options::Sockets.SocketOptions = Sockets.SocketOptions()
                    tls_connection_options::Union{Sockets.TlsConnectionOptions, Nothing} = nothing
                    read_buffer_capacity::Csize_t = Csize_t(0)
                    server_user_data::Any = nothing
                    on_incoming_connection::Any = nothing
                    on_destroy_complete::Any = nothing
                end
            end

            if !isdefined(@__MODULE__, :HttpProxyStrategyBasicAuthOptions)
                struct HttpProxyStrategyBasicAuthOptions
                    proxy_connection_type::HttpProxyConnectionType.T
                    user_name::String
                    password::String
                end
            end

            function http_connection_make_request(conn::HttpConnection, opts::HttpMakeRequestOptions)
                return http_connection_make_request(
                    conn;
                    request=opts.request,
                    on_response_headers=_legacy_stream_headers_cb(opts.on_response_headers, opts.user_data),
                    on_response_header_block_done=_legacy_stream_header_block_done_cb(opts.on_response_header_block_done, opts.user_data),
                    on_response_body=_legacy_stream_body_cb(opts.on_response_body, opts.user_data),
                    on_metrics=_legacy_stream_metrics_cb(opts.on_metrics, opts.user_data),
                    on_complete=_legacy_stream_complete_cb(opts.on_complete, opts.user_data),
                    on_destroy=_legacy_stream_destroy_cb(opts.on_destroy, opts.user_data),
                    response_first_byte_timeout_ms=opts.response_first_byte_timeout_ms,
                    http2_use_manual_data_writes=opts.http2_use_manual_data_writes,
                    http2_priority=opts.http2_priority,
                    http2_headers_pad_length=opts.http2_headers_pad_length,
                    h2c_upgrade=opts.h2c_upgrade,
                    on_h2c_upgrade=_legacy_h2c_upgrade_result_cb(opts.on_h2c_upgrade, opts.user_data),
                )
            end

            function h2_stream_new_request(conn::H2Connection, opts::HttpMakeRequestOptions)
                return h2_stream_new_request(
                    conn;
                    request=opts.request,
                    on_response_headers=_legacy_stream_headers_cb(opts.on_response_headers, opts.user_data),
                    on_response_header_block_done=_legacy_stream_header_block_done_cb(opts.on_response_header_block_done, opts.user_data),
                    on_response_body=_legacy_stream_body_cb(opts.on_response_body, opts.user_data),
                    on_metrics=_legacy_stream_metrics_cb(opts.on_metrics, opts.user_data),
                    on_complete=_legacy_stream_complete_cb(opts.on_complete, opts.user_data),
                    on_destroy=_legacy_stream_destroy_cb(opts.on_destroy, opts.user_data),
                    http2_use_manual_data_writes=opts.http2_use_manual_data_writes,
                    http2_priority=opts.http2_priority,
                    http2_headers_pad_length=opts.http2_headers_pad_length,
                )
            end

            function http_connection_new_request_handler(conn::HttpConnection, opts::HttpRequestHandlerOptions)
                return http_connection_new_request_handler(
                    conn;
                    on_request_headers=_legacy_stream_headers_cb(opts.on_request_headers, opts.user_data),
                    on_request_header_block_done=_legacy_stream_header_block_done_cb(opts.on_request_header_block_done, opts.user_data),
                    on_request_body=_legacy_stream_body_cb(opts.on_request_body, opts.user_data),
                    on_request_done=_legacy_request_done_cb(opts.on_request_done, opts.user_data),
                    on_complete=_legacy_stream_complete_cb(opts.on_complete, opts.user_data),
                    on_destroy=_legacy_stream_destroy_cb(opts.on_destroy, opts.user_data),
                )
            end

            function h1_stream_new_request_handler(opts::HttpRequestHandlerOptions)
                conn = opts.server_connection
                return h1_stream_new_request_handler(
                    conn;
                    on_request_headers=_legacy_stream_headers_cb(opts.on_request_headers, opts.user_data),
                    on_request_header_block_done=_legacy_stream_header_block_done_cb(opts.on_request_header_block_done, opts.user_data),
                    on_request_body=_legacy_stream_body_cb(opts.on_request_body, opts.user_data),
                    on_request_done=_legacy_request_done_cb(opts.on_request_done, opts.user_data),
                    on_complete=_legacy_stream_complete_cb(opts.on_complete, opts.user_data),
                    on_destroy=_legacy_stream_destroy_cb(opts.on_destroy, opts.user_data),
                )
            end

            function h2_stream_new_request_handler(conn::H2Connection, opts::HttpRequestHandlerOptions)
                return h2_stream_new_request_handler(
                    conn;
                    on_request_headers=_legacy_stream_headers_cb(opts.on_request_headers, opts.user_data),
                    on_request_header_block_done=_legacy_stream_header_block_done_cb(opts.on_request_header_block_done, opts.user_data),
                    on_request_body=_legacy_stream_body_cb(opts.on_request_body, opts.user_data),
                    on_request_done=_legacy_request_done_cb(opts.on_request_done, opts.user_data),
                    on_complete=_legacy_stream_complete_cb(opts.on_complete, opts.user_data),
                    on_destroy=_legacy_stream_destroy_cb(opts.on_destroy, opts.user_data),
                )
            end

            function http_connection_configure_server(conn::HttpConnection, opts::HttpServerConnectionOptions)::Int
                return http_connection_configure_server(
                    conn;
                    on_incoming_request=_legacy_incoming_request_cb(opts.on_incoming_request, opts.connection_user_data),
                    on_h2c_upgrade=_legacy_h2c_upgrade_probe_cb(opts.on_h2c_upgrade, opts.connection_user_data),
                    on_shutdown=_legacy_connection_shutdown_cb(opts.on_shutdown, opts.connection_user_data),
                )
            end

            function http_server_new(opts::HttpServerOptions)
                return http_server_new(
                    endpoint_host=opts.endpoint_host,
                    endpoint_port=opts.endpoint_port,
                    prior_knowledge_http2=opts.prior_knowledge_http2,
                    initial_window_size=opts.initial_window_size,
                    manual_window_management=opts.manual_window_management,
                    event_loop_group=opts.event_loop_group,
                    socket_options=opts.socket_options,
                    tls_connection_options=opts.tls_connection_options,
                    read_buffer_capacity=opts.read_buffer_capacity,
                    on_incoming_connection=(srv, conn, err) -> begin
                        opts.on_incoming_connection === nothing && return nothing
                        if applicable(opts.on_incoming_connection, srv, conn, err, opts.server_user_data)
                            return opts.on_incoming_connection(srv, conn, err, opts.server_user_data)
                        end
                        return opts.on_incoming_connection(srv, conn, err)
                    end,
                    on_destroy_complete=opts.on_destroy_complete === nothing ? nothing : () -> begin
                        if applicable(opts.on_destroy_complete, opts.server_user_data)
                            opts.on_destroy_complete(opts.server_user_data)
                        else
                            opts.on_destroy_complete()
                        end
                    end,
                )
            end

            function http_proxy_strategy_new_basic_auth(opts::HttpProxyStrategyBasicAuthOptions)
                return http_proxy_strategy_new_basic_auth(opts.proxy_connection_type, opts.user_name, opts.password)
            end

            function ws_new(; kwargs...)::WebSocket
                return WebSocket(; kwargs...)
            end

            function Base.setproperty!(conn::H2Connection, name::Symbol, value)
                if name === :on_goaway_received
                    Core.setfield!(conn, :on_goaway_received, _connection_goaway_callback(value))
                    return value
                elseif name === :on_remote_settings_change
                    Core.setfield!(conn, :on_remote_settings_change, _connection_remote_settings_callback(value))
                    return value
                elseif name === :on_shutdown
                    Core.setfield!(conn, :on_shutdown, _connection_shutdown_callback(value))
                    return value
                end
                Core.setfield!(conn, name, value)
                return value
            end

            _VENDORED_COMPAT_INSTALLED[] = true
        end
    end
    return nothing
end

function _load_vendored_awshttp_tests()::String
    src = read(_VENDORED_AWSHTTP_TESTS, String)
    src = replace(src, "using AwsHTTP: HttpHeader" => "")
    src = replace(src, "using AwsHTTP" => "const AwsHTTP = HTTP.AwsHTTP")
    src = replace(src, "const AwsHTTP = HTTP.AwsHTTP" => "const AwsHTTP = HTTP.AwsHTTP\nconst HttpHeader = AwsHTTP.HttpHeader")
    return src
end

@testset "AwsHTTP vendored low-level suite" begin
    _install_vendored_compat!()
    src = _load_vendored_awshttp_tests()
    include_string(@__MODULE__, src, _VENDORED_AWSHTTP_TESTS)
end
