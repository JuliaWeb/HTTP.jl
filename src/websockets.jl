module WebSockets

using Base64, Random, LibAwsHTTP, LibAwsCommon, LibAwsIO

import ..FieldRef, ..iswss, ..getport, ..makeuri, ..aws_throw_error, ..resource, ..Headers, ..Header, ..str, ..aws_error, ..aws_throw_error

export WebSocket, send, receive, ping, pong

@enum OpCode::UInt8 CONTINUATION=0x00 TEXT=0x01 BINARY=0x02 CLOSE=0x08 PING=0x09 PONG=0x0A

mutable struct WebSocket
    id::String
    host::String
    path::String
    ch::Channel{Symbol}
    error::Union{Nothing, Exception}
    readchannel::Channel{Union{String, Vector{UInt8}}}
    writebuffer::Vector{UInt8}
    writepos::Int
    writeclosed::Bool
    closelock::ReentrantLock
    socket_options::aws_socket_options
    tls_options::Union{Nothing, aws_tls_connection_options}
    proxy_options::Union{Nothing, aws_http_proxy_options}
    handshake_request::Ptr{aws_http_message}
    options::aws_websocket_client_connection_options
    websocket_pointer::Ptr{aws_websocket}
    handshake_response_status::Int
    handshake_response_headers::Headers
    handshake_response_body::String
    websocket_send_frame_options::aws_websocket_send_frame_options

    WebSocket(host::AbstractString, path::AbstractString) = new(string(rand(UInt32); base=58), String(host), String(path), Channel{Symbol}(0), nothing, Channel{Union{String, Vector{UInt8}}}(Inf), UInt8[], 0, false, ReentrantLock())
end

const on_connection_setup = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_connection_setup(connection_setup_data::Ptr{aws_websocket_on_connection_setup_data}, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    data = unsafe_load(connection_setup_data)
    try
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
            if data.handshake_response_body != C_NULL
                handshake_response_body = unsafe_load(data.handshake_response_body)
                ws.handshake_response_body = str(handshake_response_body)
            else
                ws.handshake_response_body = ""
            end
        end
        put!(ws.ch, :connected)
    catch e
        @error "$(ws.id): error" (e, catch_backtrace())
    end
    return
end

const on_connection_shutdown = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_connection_shutdown(websocket::Ptr{aws_websocket}, error_code::Cint, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    if error_code != 0
        ws.error = CapturedException(aws_error(error_code), Base.backtrace())
    end
    @info "$(ws.id): WebSocket closed: $error_code"
    close(ws)
    return
end

const on_incoming_frame_begin = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_frame_begin(websocket::Ptr{aws_websocket}, frame::Ptr{aws_websocket_incoming_frame}, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    fr = unsafe_load(frame)
    return true
end

const on_incoming_frame_payload = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_frame_payload(websocket::Ptr{aws_websocket}, frame::Ptr{aws_websocket_incoming_frame}, data::aws_byte_cursor, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    fr = unsafe_load(frame)
    try
        if fr.opcode == UInt8(TEXT)
            put!(ws.readchannel, unsafe_string(data.ptr, data.len))
        else
            rec = Vector{UInt8}(undef, data.len)
            Base.unsafe_copyto!(pointer(rec), data.ptr, data.len)
            put!(ws.readchannel, rec)
        end
    catch e
        @error "$(ws.id): error" (e, catch_backtrace())
    end
    return true
end

const on_incoming_frame_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_frame_complete(websocket::Ptr{aws_websocket}, frame::Ptr{aws_websocket_incoming_frame}, error_code::Cint, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    fr = unsafe_load(frame)
    try
        if error_code != 0
            ws.error = CapturedException(aws_error(error_code), Base.backtrace())
        end
        @info "$(ws.id): Incoming frame complete: $error_code, $(fr.opcode), $(fr.fin)"
    catch e
        @error "$(ws.id): error" (e, catch_backtrace())
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
    ws.options = aws_websocket_client_connection_options(
        allocator,
        bootstrap,
        pointer(FieldRef(ws, :socket_options)),
        ws.tls_options === nothing ? C_NULL : pointer(FieldRef(ws, :tls_options)),
        ws.proxy_options === nothing ? C_NULL : pointer(FieldRef(ws, :proxy_options)),
        aws_byte_cursor_from_c_str(ws.host),
        getport(_uri),
        ws.handshake_request,
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
    @assert take!(ws.ch) == :connected
    verbose > 0 && @info "$(ws.id): WebSocket opened"
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
            close(ws)
        # end
    end
end

function Base.close(ws::WebSocket)
    @lock ws.closelock begin
        if ws.websocket_pointer != C_NULL
            aws_websocket_close(ws.websocket_pointer, false)
            ws.websocket_pointer = C_NULL
            ws.writeclosed = true
        end
    end
    return
end

"""
    WebSockets.isclosed(ws) -> Bool

Check whether a `WebSocket` has sent and received CLOSE frames
"""
isclosed(ws::WebSocket) = !isopen(ws.readchannel) && ws.writeclosed

isbinary(x) = x isa AbstractVector{UInt8}
istext(x) = x isa AbstractString
opcode(x) = isbinary(x) ? BINARY : TEXT

function payload(ws, x)
    pload = isbinary(x) ? x : codeunits(string(x))
    len = length(pload)
    resize!(ws.writebuffer, len)
    copyto!(ws.writebuffer, pload)
    ws.writepos = 1
    return ws.writebuffer
end

const stream_outgoing_payload = Ref{Ptr{Cvoid}}(C_NULL)

function c_stream_outgoing_payload(websocket::Ptr{aws_websocket}, out_buf::Ptr{aws_byte_buf}, ws_ptr::Ptr{Cvoid})
    ws = unsafe_pointer_to_objref(ws_ptr)
    out = unsafe_load(out_buf)
    try
        space_available = out.capacity - out.len
        amount_to_send = min(space_available, sizeof(ws.writebuffer) - ws.writepos + 1)
        cursor = aws_byte_cursor(amount_to_send, pointer(ws.writebuffer, ws.writepos))
        @assert aws_byte_buf_write_from_whole_cursor(out_buf, cursor)
        ws.writepos += amount_to_send
    catch e
        @error "$(ws.id): error" (e, catch_backtrace())
    end
    return true
end

const on_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_complete(websocket::Ptr{aws_websocket}, error_code::Cint, ws_ptr::Ptr{Cvoid})
    ws = unsafe_pointer_to_objref(ws_ptr)
    if error_code != 0
        ws.error = CapturedException(aws_error(error_code), Base.backtrace())
    end
    try
        put!(ws.ch, :frame_sent)
    catch e
        @error "$(ws.id): error" (e, catch_backtrace())
    end
    return
end

function writeframe(ws::WebSocket, fin::Bool, opcode::OpCode, payload)
    n = sizeof(payload)
    ws.websocket_send_frame_options = aws_websocket_send_frame_options(
        n % UInt64,
        Ptr{Cvoid}(pointer_from_objref(ws)), # user_data
        stream_outgoing_payload[],
        on_complete[],
        UInt8(opcode),
        fin
    )
    opts = pointer(FieldRef(ws, :websocket_send_frame_options))
    if aws_websocket_send_frame(ws.websocket_pointer, opts) != 0
        aws_throw_error()
    end
    # wait until frame sent
    @assert take!(ws.ch) == :frame_sent
    return n
end

"""
    send(ws::WebSocket, msg)

Send a message on a websocket connection. If `msg` is an `AbstractString`,
a TEXT websocket message will be sent; if `msg` is an `AbstractVector{UInt8}`,
a BINARY websocket message will be sent. Otherwise, `msg` should be an iterable
of either `AbstractString` or `AbstractVector{UInt8}`, and a fragmented message
will be sent, one frame for each iterated element.

Control frames can be sent by calling `ping(ws[, data])`, `pong(ws[, data])`,
or `close(ws[, body::WebSockets.CloseFrameBody])`. Calling `close` will initiate
the close sequence and close the underlying connection.
"""
function send(ws::WebSocket, x)
    @assert !ws.writeclosed "WebSocket is closed"
    if !isbinary(x) && !istext(x)
        # if x is not single binary or text, then assume it's an iterable of binary or text
        # and we'll send fragmented message
        first = true
        n = 0
        state = iterate(x)
        if state === nothing
            # x was not binary or text, but is an empty iterable, send single empty frame
            x = ""
            @goto write_single_frame
        end
        @debug "$(ws.id): Writing fragmented message"
        item, st = state
        # we prefetch next state so we know if we're on the last item or not
        # so we can appropriately set the FIN bit for the last fragmented frame
        nextstate = iterate(x, st)
        while true
            n += writeframe(ws, nextstate === nothing, first ? opcode(item) : CONTINUATION, payload(ws, item))
            first = false
            nextstate === nothing && break
            item, st = nextstate
            nextstate = iterate(x, st)
        end
    else
        # single binary or text frame for message
@label write_single_frame
        return writeframe(ws, true, opcode(x), payload(ws, x))
    end
end

# control frames
"""
    ping(ws, data=[])

Send a PING control frame on a websocket connection. `data` is an optional
body to send with the message. PONG messages are automatically responded
to when a PING message is received by a websocket connection.
"""
function ping(ws::WebSocket, data=UInt8[])
    @assert !ws.writeclosed "WebSocket is closed"
    return writeframe(ws.io, true, PING, payload(ws, data))
end

"""
    pong(ws, data=[])

Send a PONG control frame on a websocket connection. `data` is an optional
body to send with the message. Note that PING messages are automatically
responded to internally by the websocket connection with a corresponding
PONG message, but in certain cases, a unidirectional PONG message can be
used as a one-way heartbeat.
"""
function pong(ws::WebSocket, data=UInt8[])
    @assert !ws.writeclosed "WebSocket is closed"
    return writeframe(ws.io, true, PONG, payload(ws, data))
end

"""
    receive(ws::WebSocket) -> Union{String, Vector{UInt8}}

Receive a message from a websocket connection. Returns a `String` if
the message was TEXT, or a `Vector{UInt8}` if the message was BINARY.
If control frames (ping or pong) are received, they are handled
automatically and a non-control message is waited for. If a CLOSE
message is received, it is responded to and a `WebSocketError` is thrown
with the `WebSockets.CloseFrameBody` as the error value. This error can
be checked with `WebSockets.isok(err)` to see if the closing was "normal"
or if an actual error occurred. For fragmented messages, the incoming
frames will continue to be read until the final fragment is received.
The bodies of each fragment are concatenated into the final message
returned by `receive`. Note that `WebSocket` objects can be iterated,
where each iteration yields a message until the connection is closed.
"""
function receive(ws::WebSocket)
    @assert isopen(ws.readchannel) "WebSocket is closed"
    return take!(ws.readchannel)
end

"""
    iterate(ws)

Continuously call `receive(ws)` on a `WebSocket` connection, with
each iteration yielding a message until the connection is closed.
E.g.
```julia
for msg in ws
    # do something with msg
end
```
"""
function Base.iterate(ws::WebSocket, st=nothing)
    isclosed(ws) && return nothing
    try
        return receive(ws), nothing
    catch e
        isok(e) && return nothing
        rethrow(e)
    end
end

function __init__()
    on_connection_setup[] = @cfunction(c_on_connection_setup, Cvoid, (Ptr{aws_websocket_on_connection_setup_data}, Ptr{Cvoid}))
    on_connection_shutdown[] = @cfunction(c_on_connection_shutdown, Cvoid, (Ptr{aws_websocket}, Cint, Ptr{Cvoid}))
    on_incoming_frame_begin[] = @cfunction(c_on_incoming_frame_begin, Bool, (Ptr{aws_websocket}, Ptr{aws_websocket_incoming_frame}, Ptr{Cvoid}))
    on_incoming_frame_payload[] = @cfunction(c_on_incoming_frame_payload, Bool, (Ptr{aws_websocket}, Ptr{aws_websocket_incoming_frame}, aws_byte_cursor, Ptr{Cvoid}))
    on_incoming_frame_complete[] = @cfunction(c_on_incoming_frame_complete, Bool, (Ptr{aws_websocket}, Ptr{aws_websocket_incoming_frame}, Cint, Ptr{Cvoid}))
    stream_outgoing_payload[] = @cfunction(c_stream_outgoing_payload, Bool, (Ptr{aws_websocket}, Ptr{aws_byte_buf}, Ptr{Cvoid}))
    on_complete[] = @cfunction(c_on_complete, Cvoid, (Ptr{aws_websocket}, Cint, Ptr{Cvoid}))
    return
end

end # module