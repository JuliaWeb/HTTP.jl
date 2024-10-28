module WebSockets

using Base64, Random, LibAwsHTTP, LibAwsCommon, LibAwsIO

import ..FieldRef, ..iswss, ..getport, ..makeuri, ..aws_throw_error, ..resource, ..Headers, ..Header

export WebSocket, send, receive, ping, pong

mutable struct WebSocket
    id::String
    host::String
    path::String
    connected::Threads.Event
    error::Union{Nothing, Exception}
    readbuf::Base.BufferStream
    socket_options::aws_socket_options
    tls_options::Union{Nothing, aws_tls_connection_options}
    proxy_options::Union{Nothing, aws_http_proxy_options}
    handshake_request::Ptr{aws_http_message}
    options::aws_websocket_client_connection_options
    websocket_pointer::Ptr{aws_websocket}
    handshake_response_status::Int
    handshake_response_headers::Headers
    handshake_response_body::String

    WebSocket(host::AbstractString, path::AbstractString) = new(string(rand(UInt32); base=58), String(host), String(path), Threads.Event(), nothing, Base.BufferStream())
end

const on_connection_setup = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_connection_setup(connection_setup_data::Ptr{aws_websocket_on_connection_setup_data}, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    data = unsafe_load(connection_setup_data)
    if data.error_code != 0
        ws.error = CapturedException(aws_error(data.error_code), Base.backtrace())
    else
        ws.websocket_pointer = data.websocket
        ws.handshake_response_status = unsafe_load(data.handshake_response_status)
        headers = Vector{Header}(undef, data.num_handshake_response_headers)
        for i in 1:length(headers)
            header = unsafe_load(data.handshake_response_header_array, i)
            name = unsafe_string(header.name.ptr, header.name.len)
            value = unsafe_string(header.value.ptr, header.value.len)
            headers[i] = name => value
        end
        ws.handshake_response_headers = headers
        ws.handshake_response_body = unsafe_string(data.handshake_response_body.ptr, data.handshake_response_body.len)
    end
    notify(ws.connected)
    return
end

const on_connection_shutdown = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_connection_shutdown(websocket::Ptr{aws_websocket}, error_code::Cint, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    @info "$(ws.id): connection shutdown: error_code=$(error_code)"
    if error_code != 0
        ws.error = CapturedException(aws_error(error_code), Base.backtrace())
    end
    return
end

const on_incoming_frame_begin = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_frame_begin(websocket::Ptr{aws_websocket}, frame::Ptr{aws_websocket_incoming_frame}, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    fr = unsafe_load(frame)
    @info "$(ws.id): incoming frame: opcode=$(fr.opcode), payload_len=$(fr.payload_len), is_fin=$(fr.fin)"
    return true
end

const on_incoming_frame_payload = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_frame_payload(websocket::Ptr{aws_websocket}, frame::Ptr{aws_websocket_incoming_frame}, data::aws_byte_cursor, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    fr = unsafe_load(frame)
    @info "$(ws.id): incoming frame payload: opcode=$(fr.opcode), payload_len=$(fr.payload_len), is_fin=$(fr.fin)"
    unsafe_write(ws.readbuf, data.buffer, data.len)
    return true
end

const on_incoming_frame_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_frame_complete(websocket::Ptr{aws_websocket}, frame::Ptr{aws_websocket_incoming_frame}, error_code::Cint, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    fr = unsafe_load(frame)
    @info "$(ws.id): incoming frame complete: opcode=$(fr.opcode), payload_len=$(fr.payload_len), is_fin=$(fr.fin)"
    if error_code != 0
        ws.error = CapturedException(aws_error(error_code), Base.backtrace())
    end
    return true
end

function open(f::Function, url;
    verbose=false,
    headers=[],
    allocator::Ptr{aws_allocator}=default_aws_allocator(),
    bootstrap::Ptr{aws_client_bootstrap}=default_aws_client_bootstrap(),
    # socket options
    socket_domain=:ipv4,
    connect_timeout_ms::Integer=3000,
    keep_alive_interval_sec::Integer=0,
    keep_alive_timeout_sec::Integer=0,
    keep_alive_max_failed_probes::Integer=0,
    keepalive::Bool=false,
    # tls options
    require_ssl_verification::Bool=true,
    ssl_cert=nothing,
    ssl_key=nothing,
    ssl_capath=nothing,
    ssl_cacert=nothing,
    ssl_insecure=!require_ssl_verification,
    ssl_alpn_list="h2;http/1.1",
    )
    key = base64encode(rand(Random.RandomDevice(), UInt8, 16))
    uri_ref = Ref{aws_uri}()
    if url isa AbstractString
        url_str = String(url)
    elseif url isa URI
        url_str = string(url)
    else
        throw(ArgumentError("url must be an AbstractString or URI"))
    end
    GC.@preserve url_str begin
        url_ref = Ref(aws_byte_cursor(sizeof(url_str), pointer(url_str)))
        aws_uri_init_parse(uri_ref, allocator, url_ref)
    end
    _uri = uri_ref[]
    uri = makeuri(_uri)
    ws = WebSocket(uri.host, resource(uri))
    # http request
    request = aws_http_message_new_websocket_handshake_request(allocator, aws_byte_cursor_from_c_str(ws.path), aws_byte_cursor_from_c_str(ws.host))
    request == C_NULL && aws_throw_error()
    # add headers to request
    for (k, v) in headers
        header = aws_http_header(aws_byte_cursor_from_c_str(k), aws_byte_cursor_from_c_str(v), AWS_HTTP_HEADER_COMPRESSION_USE_CACHE)
        aws_http_message_add_header(request, header) != 0 && aws_throw_error()
    end
    ws.handshake_request = request
    # socket options
    ws.socket_options = aws_socket_options(
        AWS_SOCKET_STREAM, # socket type
        socket_domain == :ipv4 ? AWS_SOCKET_IPV4 : AWS_SOCKET_IPV6, # socket domain
        connect_timeout_ms,
        keep_alive_interval_sec,
        keep_alive_timeout_sec,
        keep_alive_max_failed_probes,
        keepalive,
        ntuple(x -> Cchar(0), 16) # network_interface_name
    )
    # tls options
    if uri.scheme == "wss"
        ws.tls_options = LibAwsIO.tlsoptions(host_str;
            ssl_cert,
            ssl_key,
            ssl_capath,
            ssl_cacert,
            ssl_insecure,
            ssl_alpn_list
        )
    else
        ws.tls_options = nothing
    end
    ws.proxy_options = nothing
    @show ws.host
    ws.options = aws_websocket_client_connection_options(
        allocator,
        bootstrap,
        pointer(FieldRef(ws, :socket_options)),
        ws.tls_options === nothing ? C_NULL : pointer(FieldRef(ws, :tls_options)),
        ws.proxy_options === nothing ? C_NULL : pointer(FieldRef(ws, :proxy_options)),
        aws_byte_cursor_from_c_str(ws.host),
        getport(_uri),
        pointer(FieldRef(ws, :handshake_request)),
        0, # initial_window_size
        Ptr{Cvoid}(pointer_from_objref(ws)), # user_data
        on_connection_setup[],
        on_connection_shutdown[],
        on_incoming_frame_begin[],
        on_incoming_frame_payload[],
        on_incoming_frame_complete[],
        false, # manual_window_management
        C_NULL, # requested_event_loop
        C_NULL, # host_resolution_config
    )
    if aws_websocket_client_connect(FieldRef(ws, :options)) != 0
        aws_throw_error()
    end
    # wait until connected
    wait(ws.connected)
    @info "$(ws.id): WebSocket opened"
    try
        f(ws)
    catch e
        # if !isok(e)
        #     suppress_close_error || @error "$(ws.id): error" (e, catch_backtrace())
        # end
        # if !isclosed(ws)
        #     if e isa WebSocketError && e.message isa CloseFrameBody
        #         close(ws, e.message)
        #     else
        #         close(ws, CloseFrameBody(1008, "Unexpected client websocket error"))
        #     end
        # end
        # if !isok(e)
            rethrow()
        # end
    finally
        # if !isclosed(ws)
        #     close(ws, CloseFrameBody(1000, ""))
        # end
    end
end

function Base.close(ws::WebSocket)
    if ws.websocket_pointer != C_NULL
        aws_websocket_close(ws.websocket_pointer, false)
        ws.websocket_pointer = C_NULL
    end
    return
end

function __init__()
    on_connection_setup[] = @cfunction(c_on_connection_setup, Cvoid, (Ptr{aws_websocket_on_connection_setup_data}, Ptr{Cvoid}))
    on_connection_shutdown[] = @cfunction(c_on_connection_shutdown, Cvoid, (Ptr{aws_websocket}, Cint, Ptr{Cvoid}))
    on_incoming_frame_begin[] = @cfunction(c_on_incoming_frame_begin, Bool, (Ptr{aws_websocket}, Ptr{aws_websocket_incoming_frame}, Ptr{Cvoid}))
    on_incoming_frame_payload[] = @cfunction(c_on_incoming_frame_payload, Bool, (Ptr{aws_websocket}, Ptr{aws_websocket_incoming_frame}, aws_byte_cursor, Ptr{Cvoid}))
    on_incoming_frame_complete[] = @cfunction(c_on_incoming_frame_complete, Bool, (Ptr{aws_websocket}, Ptr{aws_websocket_incoming_frame}, Cint, Ptr{Cvoid}))
    return
end

end # module