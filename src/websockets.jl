module WebSockets

using Base64, Random, LibAwsHTTPFork, LibAwsCommon, LibAwsIO

import ..FieldRef, ..iswss, ..getport, ..makeuri, ..aws_throw_error, ..resource, ..Headers, ..Header, ..str, ..aws_error, ..aws_throw_error, ..Future, ..parseuri, ..with_redirect, ..with_request, ..getclient, ..ClientSettings, ..scheme, ..host, ..getport, ..userinfo, ..Client, ..Request, ..Response, ..setinputstream!, ..getresponse, ..CookieJar, ..COOKIEJAR, ..addheaders, ..Stream, ..HTTP, ..getheader

export WebSocket, send, receive, ping, pong

@enum OpCode::UInt8 CONTINUATION=0x00 TEXT=0x01 BINARY=0x02 CLOSE=0x08 PING=0x09 PONG=0x0A

mutable struct WebSocket
    id::String
    host::String
    path::String
    not::Future{Nothing}
    readchannel::Channel{Union{String, Vector{UInt8}}}
    writebuffer::Vector{UInt8}
    writepos::Int
    writeclosed::Bool
    closelock::ReentrantLock
    handshake_request::Request
    options::aws_websocket_client_connection_options
    websocket_pointer::Ptr{aws_websocket}
    handshake_response::Response
    websocket_send_frame_options::aws_websocket_send_frame_options

    WebSocket(host::AbstractString, path::AbstractString) = new(string(rand(UInt32); base=58), String(host), String(path), Future{Nothing}(), Channel{Union{String, Vector{UInt8}}}(Inf), UInt8[], 0, false, ReentrantLock())
end

getresponse(ws::WebSocket) = ws.handshake_response

const on_connection_setup = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_connection_setup(connection_setup_data::Ptr{aws_websocket_on_connection_setup_data}, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    data = unsafe_load(connection_setup_data)
    try
        if data.error_code != 0
            notify(ws.not, CapturedException(aws_error(data.error_code), Base.backtrace()))
        else
            ws.websocket_pointer = data.websocket
            ws.handshake_response.status = unsafe_load(data.handshake_response_status)
            addheaders(ws.handshake_response.headers, data.handshake_response_header_array, data.num_handshake_response_headers)
            if data.handshake_response_body != C_NULL
                handshake_response_body = unsafe_load(data.handshake_response_body)
                response_body = str(handshake_response_body)
            else
                response_body = nothing
            end
            setinputstream!(ws.handshake_response, response_body)
            notify(ws.not, nothing)
        end
    catch e
        notify(ws.not, CapturedException(e, Base.backtrace()))
    end
    return
end

const on_connection_shutdown = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_connection_shutdown(websocket::Ptr{aws_websocket}, error_code::Cint, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    if error_code != 0
        @error "$(ws.id): connection shutdown error" exception=(aws_error(error_code), Base.backtrace())
    end
    close(ws)
    return
end

const on_incoming_frame_begin = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_frame_begin(websocket::Ptr{aws_websocket}, frame::Ptr{aws_websocket_incoming_frame}, ws_ptr)
    # ws = unsafe_pointer_to_objref(ws_ptr)
    # fr = unsafe_load(frame)
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
        @error "$(ws.id): incoming frame payload error" exception=(e, catch_backtrace())
    end
    return true
end

const on_incoming_frame_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_frame_complete(websocket::Ptr{aws_websocket}, frame::Ptr{aws_websocket_incoming_frame}, error_code::Cint, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    fr = unsafe_load(frame)
    if error_code != 0
        @error "$(ws.id): incoming frame complete error" exception=(aws_error(error_code), Base.backtrace())
    end
    return true
end

function open(f::Function, url;
    headers=[],
    allocator::Ptr{aws_allocator}=default_aws_allocator(),
    username=nothing,
    password=nothing,
    bearer=nothing,
    query=nothing,
    client::Union{Nothing, Client}=nothing,
    # redirect options
    redirect=true,
    redirect_limit=3,
    redirect_method=nothing,
    forwardheaders=true,
    # cookie options
    cookies=true,
    cookiejar::CookieJar=COOKIEJAR,
    modifier=nothing,
    verbose=0,
    # client keywords
    kw...
    )
    key = base64encode(rand(Random.RandomDevice(), UInt8, 16))
    uri = parseuri(url, query, allocator)
    # add required websocket headers
    append!(headers, [
        "upgrade" => "websocket",
        "connection" => "upgrade",
        "sec-websocket-key" => key,
        "sec-websocket-version" => "13"
    ])
    ws = with_redirect(allocator, "GET", uri, headers, nothing, redirect, redirect_limit, redirect_method, forwardheaders) do method, uri, headers, body
        reqclient = @something(client, getclient(ClientSettings(scheme(uri), host(uri), getport(uri); allocator=allocator, ssl_alpn_list="http/1.1", kw...)))::Client
        path = resource(uri)
        with_request(reqclient, method, path, headers, body, nothing, false, (username !== nothing && password !== nothing) ? "$username:$password" : userinfo(uri), bearer, modifier, false, cookies, cookiejar, verbose) do req
            host = str(uri.host_name)
            ws = WebSocket(host, path)
            ws.handshake_request = req
            ws.handshake_response = Response(0, nothing, nothing, false, allocator)
            ws.options = aws_websocket_client_connection_options(
                allocator,
                reqclient.settings.bootstrap,
                pointer(FieldRef(reqclient, :socket_options)),
                reqclient.tls_options === nothing ? C_NULL : pointer(FieldRef(reqclient, :tls_options)),
                reqclient.proxy_options === nothing ? C_NULL : pointer(FieldRef(reqclient, :proxy_options)),
                uri.host_name,
                uri.port,
                ws.handshake_request.ptr,
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
            wait(ws.not)
            return ws
        end
    end
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
        return false
    end
    return true
end

const on_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_complete(websocket::Ptr{aws_websocket}, error_code::Cint, ws_ptr::Ptr{Cvoid})
    ws = unsafe_pointer_to_objref(ws_ptr)
    if error_code != 0
        notify(ws.not, CapturedException(aws_error(error_code), Base.backtrace()))
    end
    notify(ws.not, nothing)
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
    wait(ws.not)
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

# given a WebSocket request, return the 101 response
function websocket_upgrade_handler(req::Request)
    key = getheader(req.headers, "sec-websocket-key")
    resp_ptr = aws_http_message_new_websocket_handshake_response(req.allocator, aws_byte_cursor_from_c_str(key))
    resp_ptr == C_NULL && aws_throw_error()
    resp = Response()
    resp.allocator = req.allocator
    resp.ptr = resp_ptr
    resp.request = req
    return resp
end

function websocket_upgrade_function(f)
    #TODO: return WebSocketUpgradeArgs
    # then schedule a task to do the actual upgrade
    function websocket_upgrade(stream::Stream)
        #TODO: get host/path from stream?
        ws = WebSocket("", "")
        stream.websocket_options = aws_websocket_server_upgrade_options(
            0,
            Ptr{Cvoid}(pointer_from_objref(ws)),
            on_incoming_frame_begin[],
            on_incoming_frame_payload[],
            on_incoming_frame_complete[],
            false # manual_window_management
        )
        ws_ptr = aws_websocket_upgrade(stream.allocator, stream.ptr, FieldRef(stream, :websocket_options))
        ws_ptr == C_NULL && aws_throw_error()
        ws.websocket_pointer = ws_ptr
        errormonitor(Threads.@spawn begin
            try
                f(ws)
            finally
                aws_websocket_release(ws_ptr)
            end
        end)
        return
    end
end

serve!(f, host="127.0.0.1", port=8080; kw...) =
    HTTP.serve!(websocket_upgrade_handler, host, port; on_stream_complete=websocket_upgrade_function(f), kw...)

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