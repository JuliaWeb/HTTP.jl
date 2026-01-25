module WebSockets

using Base64, Random, LibAwsHTTPFork, LibAwsCommon, LibAwsIO

import ..FieldRef, ..iswss, ..getport, ..makeuri, ..aws_throw_error, ..resource, ..Headers, ..Header, ..str, ..aws_error, ..aws_throw_error, ..Future, ..parseuri, ..with_redirect, ..with_request, ..getclient, ..ClientSettings, ..scheme, ..host, ..getport, ..userinfo, ..Client, ..Request, ..Response, ..Message, ..setinputstream!, ..getresponse, ..CookieJar, ..COOKIEJAR, ..addheaders, ..Stream, ..HTTP, ..getheader, ..hasheader, ..header

export WebSocket, send, receive, ping, pong

@enum OpCode::UInt8 CONTINUATION=0x00 TEXT=0x01 BINARY=0x02 CLOSE=0x08 PING=0x09 PONG=0x0A

const DEFAULT_MAX_FRAG = 1024

struct CloseFrameBody
    code::Int
    reason::String
end

struct WebSocketError <: Exception
    message::CloseFrameBody
end

isok(e::WebSocketError) = e.message.code in (1000, 1001, 1005)
isok(::Any) = false

function isupgrade(r::Message)
    ((r isa Request && r.method == "GET") ||
     (r isa Response && r.status == 101)) &&
    (hasheader(r, "Connection", "upgrade") ||
     hasheader(r, "Connection", "keep-alive, upgrade")) &&
    hasheader(r, "Upgrade", "websocket")
end

isupgrade(s::Stream) = isupgrade(s.request)

Base.@deprecate is_upgrade isupgrade

mutable struct WebSocket
    id::String
    host::String
    path::String
    maxframesize::Int
    maxfragmentation::Int
    connect_fut::Future{Nothing}
    readchannel::Channel{Union{String, Vector{UInt8}, WebSocketError}}
    writebuffer::Vector{UInt8}
    writepos::Int
    writeclosed::Bool
    closelock::ReentrantLock
    sendlock::ReentrantLock
    handshake_request::Union{Nothing, Request}
    websocket_pointer::Ptr{aws_websocket}
    handshake_response::Union{Nothing, Response}
    incoming_opcode::UInt8
    incoming_fin::Bool
    incoming_payload::Vector{UInt8}
    fragment_opcode::Union{Nothing, UInt8}
    fragment_payload::Vector{UInt8}
    closebody::Union{Nothing, CloseFrameBody}

    WebSocket(host::AbstractString, path::AbstractString; maxframesize::Integer=typemax(Int), maxfragmentation::Integer=DEFAULT_MAX_FRAG) = new(
        string(rand(UInt32); base=58),
        String(host),
        String(path),
        Int(maxframesize),
        Int(maxfragmentation),
        Future{Nothing}(),
        Channel{Union{String, Vector{UInt8}, WebSocketError}}(Inf),
        UInt8[],
        0,
        false,
        ReentrantLock(),
        ReentrantLock(),
        nothing,
        C_NULL,
        nothing,
        0x00,
        false,
        UInt8[],
        nothing,
        UInt8[],
        nothing,
    )
end

getresponse(ws::WebSocket) = ws.handshake_response

function _queue_close!(ws::WebSocket, body::CloseFrameBody)
    ws.closebody = body
    if isopen(ws.readchannel)
        try
            put!(ws.readchannel, WebSocketError(body))
        catch
        end
        Base.close(ws.readchannel)
    end
    return
end

function _close_channel!(ws::WebSocket)
    isopen(ws.readchannel) && Base.close(ws.readchannel)
    return
end

function _enqueue_message!(ws::WebSocket, msg)
    if isopen(ws.readchannel)
        try
            put!(ws.readchannel, msg)
        catch
        end
    end
    return
end

function close_payload(body::CloseFrameBody)
    reason_bytes = collect(codeunits(body.reason))
    payload = Vector{UInt8}(undef, 2 + length(reason_bytes))
    payload[1] = UInt8((body.code >> 8) & 0xff)
    payload[2] = UInt8(body.code & 0xff)
    if !isempty(reason_bytes)
        copyto!(payload, 3, reason_bytes, 1, length(reason_bytes))
    end
    return payload
end

mutable struct SendState
    ws::WebSocket
    fut::Future{Nothing}
end

const on_connection_setup = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_connection_setup(connection_setup_data::Ptr{aws_websocket_on_connection_setup_data}, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    data = unsafe_load(connection_setup_data)
    try
        if data.error_code != 0
            notify(ws.connect_fut, CapturedException(aws_error(data.error_code), Base.backtrace()))
        else
            ws.websocket_pointer = data.websocket
            resp = ws.handshake_response
            @assert resp !== nothing
            resp.status = unsafe_load(data.handshake_response_status)
            addheaders(resp.headers, data.handshake_response_header_array, data.num_handshake_response_headers)
            if data.handshake_response_body != C_NULL
                handshake_response_body = unsafe_load(data.handshake_response_body)
                response_body = str(handshake_response_body)
            else
                response_body = nothing
            end
            setinputstream!(resp, response_body)
            notify(ws.connect_fut, nothing)
        end
    catch e
        notify(ws.connect_fut, CapturedException(e, Base.backtrace()))
    end
    return
end

const on_connection_shutdown = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_connection_shutdown(websocket::Ptr{aws_websocket}, error_code::Cint, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    if error_code != 0
        @error "$(ws.id): connection shutdown error" exception=(aws_error(error_code), Base.backtrace())
        if ws.closebody === nothing
            _queue_close!(ws, CloseFrameBody(1006, ""))
        end
    else
        _close_channel!(ws)
    end
    ws.websocket_pointer = C_NULL
    ws.writeclosed = true
    return
end

const on_incoming_frame_begin = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_frame_begin(websocket::Ptr{aws_websocket}, frame::Ptr{aws_websocket_incoming_frame}, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    fr = unsafe_load(frame)
    ws.incoming_opcode = fr.opcode
    ws.incoming_fin = fr.fin
    empty!(ws.incoming_payload)
    fr.payload_length > 0 && sizehint!(ws.incoming_payload, Int(fr.payload_length))
    return true
end

const on_incoming_frame_payload = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_frame_payload(websocket::Ptr{aws_websocket}, frame::Ptr{aws_websocket_incoming_frame}, data::aws_byte_cursor, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    try
        n = Int(data.len)
        n == 0 && return true
        payload = ws.incoming_payload
        start = length(payload) + 1
        resize!(payload, length(payload) + n)
        Base.unsafe_copyto!(pointer(payload, start), data.ptr, n)
    catch e
        @error "$(ws.id): incoming frame payload error" exception=(e, catch_backtrace())
    end
    return true
end

const on_incoming_frame_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_incoming_frame_complete(websocket::Ptr{aws_websocket}, frame::Ptr{aws_websocket_incoming_frame}, error_code::Cint, ws_ptr)
    ws = unsafe_pointer_to_objref(ws_ptr)
    if error_code != 0
        @error "$(ws.id): incoming frame complete error" exception=(aws_error(error_code), Base.backtrace())
        close_body = CloseFrameBody(1006, "")
        _queue_close!(ws, close_body)
        Threads.@spawn close(ws, close_body)
        return true
    end
    fr = unsafe_load(frame)
    opcode = fr.opcode
    fin = fr.fin
    payload = ws.incoming_payload
    if opcode == UInt8(PING)
        payload_copy = copy(payload)
        Threads.@spawn begin
            try
                pong(ws, payload_copy)
            catch e
                @error "$(ws.id): failed to send pong" exception=(e, catch_backtrace())
            end
        end
        return true
    elseif opcode == UInt8(PONG)
        return true
    elseif opcode == UInt8(CLOSE)
        body = payload
        close_body = if length(body) >= 2
            code = (Int(body[1]) << 8) | Int(body[2])
            reason = length(body) > 2 ? String(copy(body[3:end])) : ""
            CloseFrameBody(code, reason)
        else
            CloseFrameBody(1005, "")
        end
        Threads.@spawn begin
            try
                ws.writeclosed || close(ws, close_body)
            catch e
                @error "$(ws.id): failed to close websocket" exception=(e, catch_backtrace())
            end
        end
        _queue_close!(ws, close_body)
        return true
    end
    if opcode == UInt8(CONTINUATION)
        if ws.fragment_opcode === nothing
            close_body = CloseFrameBody(1002, "unexpected continuation")
            _queue_close!(ws, close_body)
            Threads.@spawn close(ws, close_body)
            return true
        end
        append!(ws.fragment_payload, payload)
        if fin
            msg_opcode = ws.fragment_opcode
            data = ws.fragment_payload
            ws.fragment_opcode = nothing
            ws.fragment_payload = UInt8[]
            if msg_opcode == UInt8(TEXT)
                _enqueue_message!(ws, String(copy(data)))
            else
                _enqueue_message!(ws, copy(data))
            end
        end
        return true
    end
    if opcode == UInt8(TEXT) || opcode == UInt8(BINARY)
        if ws.fragment_opcode !== nothing
            close_body = CloseFrameBody(1002, "unexpected new data frame")
            _queue_close!(ws, close_body)
            Threads.@spawn close(ws, close_body)
            return true
        end
        if fin
            if opcode == UInt8(TEXT)
                _enqueue_message!(ws, String(copy(payload)))
            else
                _enqueue_message!(ws, copy(payload))
            end
        else
            ws.fragment_opcode = opcode
            ws.fragment_payload = copy(payload)
        end
    end
    return true
end

function open(f::Function, url;
    suppress_close_error::Bool=false,
    headers=[],
    maxframesize::Integer=typemax(Int),
    maxfragmentation::Integer=DEFAULT_MAX_FRAG,
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
            ws = WebSocket(host, path; maxframesize=maxframesize, maxfragmentation=maxfragmentation)
            ws.handshake_request = req
            ws.handshake_response = Response(0, nothing, nothing, false, allocator)
            options = aws_websocket_client_connection_options(
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
            if aws_websocket_client_connect(Ref(options)) != 0
                aws_throw_error()
            end
            # wait until connected
            wait(ws.connect_fut)
            return ws
        end
    end
    verbose > 0 && @info "$(ws.id): WebSocket opened"
    try
        f(ws)
    catch e
        if !isok(e)
            suppress_close_error || @error "$(ws.id): error" exception=(e, catch_backtrace())
        end
        if !isclosed(ws)
            if e isa WebSocketError && e.message isa CloseFrameBody
                close(ws, e.message)
            else
                close(ws, CloseFrameBody(1008, "Unexpected client websocket error"))
            end
        end
        if !isok(e)
            rethrow()
        end
    finally
        if !isclosed(ws)
            close(ws, CloseFrameBody(1000, ""))
        end
    end
end

function Base.close(ws::WebSocket, body::Union{Nothing, CloseFrameBody}=nothing)
    @lock ws.closelock begin
        if ws.writeclosed
            _close_channel!(ws)
            return
        end
        ws.writeclosed = true
        if ws.websocket_pointer != C_NULL
            if body !== nothing
                payload_bytes = close_payload(body)
                @lock ws.sendlock begin
                    try
                        writeframe(ws, true, CLOSE, payload(ws, payload_bytes))
                    catch
                        # ignore errors while closing
                    end
                end
            end
            aws_websocket_close(ws.websocket_pointer, false)
            ws.websocket_pointer = C_NULL
        end
        _close_channel!(ws)
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
    state = unsafe_pointer_to_objref(ws_ptr)
    ws = state.ws
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
    state = unsafe_pointer_to_objref(ws_ptr)
    if error_code != 0
        notify(state.fut, CapturedException(aws_error(error_code), Base.backtrace()))
    else
        notify(state.fut, nothing)
    end
    return
end

function writeframe(ws::WebSocket, fin::Bool, opcode::OpCode, payload)
    n = sizeof(payload)
    state = SendState(ws, Future{Nothing}())
    opts = aws_websocket_send_frame_options(
        n % UInt64,
        Ptr{Cvoid}(pointer_from_objref(state)), # user_data
        stream_outgoing_payload[],
        on_complete[],
        UInt8(opcode),
        fin
    )
    GC.@preserve state opts begin
        if aws_websocket_send_frame(ws.websocket_pointer, Ref(opts)) != 0
            aws_throw_error()
        end
        # wait until frame sent
        wait(state.fut)
        return n
    end
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
    @lock ws.sendlock begin
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
            return n
        else
            # single binary or text frame for message
@label write_single_frame
            return writeframe(ws, true, opcode(x), payload(ws, x))
        end
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
    @lock ws.sendlock begin
        @assert !ws.writeclosed "WebSocket is closed"
        return writeframe(ws, true, PING, payload(ws, data))
    end
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
    @lock ws.sendlock begin
        @assert !ws.writeclosed "WebSocket is closed"
        return writeframe(ws, true, PONG, payload(ws, data))
    end
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
    if !isopen(ws.readchannel)
        close_body = ws.closebody === nothing ? CloseFrameBody(1006, "") : ws.closebody
        throw(WebSocketError(close_body))
    end
    msg = take!(ws.readchannel)
    if msg isa WebSocketError
        throw(msg)
    end
    return msg
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

@noinline handshakeerror() = throw(WebSocketError(CloseFrameBody(1002, "Websocket handshake failed")))

# given a WebSocket request, return the 101 response
function websocket_upgrade_handler(req::Request)
    if !isupgrade(req)
        return Response(400, ["content-type" => "text/plain"], "websocket upgrade required", false, req.allocator)
    end
    if !hasheader(req, "Sec-WebSocket-Version", "13")
        return Response(400, ["content-type" => "text/plain"], "unsupported websocket version", false, req.allocator)
    end
    key = getheader(req.headers, "sec-websocket-key")
    if key === nothing || isempty(key)
        return Response(400, ["content-type" => "text/plain"], "missing websocket key", false, req.allocator)
    end
    resp_ptr = aws_http_message_new_websocket_handshake_response(req.allocator, aws_byte_cursor_from_c_str(key))
    resp_ptr == C_NULL && aws_throw_error()
    resp = Response()
    resp.allocator = req.allocator
    resp.ptr = resp_ptr
    resp.request = req
    return resp
end

function websocket_upgrade_function(f; suppress_close_error::Bool=false, maxframesize::Integer=typemax(Int), maxfragmentation::Integer=DEFAULT_MAX_FRAG, done=nothing)
    #TODO: return WebSocketUpgradeArgs
    # then schedule a task to do the actual upgrade
    function websocket_upgrade(stream::Stream)
        resp = isdefined(stream, :response) ? stream.response : nothing
        if resp === nothing || resp.status != 101
            done !== nothing && notify(done, CapturedException(ArgumentError("websocket upgrade not accepted"), Base.backtrace()))
            return
        end
        req = stream.request
        ws = WebSocket(header(req, "host", ""), req.path; maxframesize=maxframesize, maxfragmentation=maxfragmentation)
        ws.handshake_request = req
        ws.handshake_response = resp
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
            err = nothing
            try
                f(ws)
            catch e
                if !isok(e)
                    err = e
                    suppress_close_error || @error "$(ws.id): error" exception=(e, catch_backtrace())
                end
                if !isclosed(ws)
                    if e isa WebSocketError && e.message isa CloseFrameBody
                        close(ws, e.message)
                    elseif isok(e)
                        close(ws, CloseFrameBody(1000, ""))
                    else
                        close(ws, CloseFrameBody(1011, "Unexpected server websocket error"))
                    end
                end
                if err !== nothing
                    done !== nothing && notify(done, CapturedException(e, catch_backtrace()))
                end
                if !isok(e)
                    rethrow()
                end
            finally
                if err === nothing
                    if !isclosed(ws)
                        close(ws, CloseFrameBody(1000, ""))
                    end
                    done !== nothing && notify(done, nothing)
                end
                aws_websocket_release(ws_ptr)
            end
        end)
        return
    end
end

function _upgrade(f::Function, stream::Stream; suppress_close_error::Bool=false, maxframesize::Integer=typemax(Int), maxfragmentation::Integer=DEFAULT_MAX_FRAG)
    isupgrade(stream) || handshakeerror()
    hasheader(stream.request, "Sec-WebSocket-Version", "13") || handshakeerror()
    key = getheader(stream.request.headers, "sec-websocket-key")
    (key === nothing || isempty(key)) && handshakeerror()
    stream.response_started && error("response already started")
    done = Future{Nothing}()
    stream.on_complete = websocket_upgrade_function(f; suppress_close_error=suppress_close_error, maxframesize=maxframesize, maxfragmentation=maxfragmentation, done=done)
    stream.response = websocket_upgrade_handler(stream.request)
    HTTP.startwrite(stream)
    HTTP.closewrite(stream)
    wait(done)
    return
end

upgrade(f::Function, stream::Stream; kw...) = _upgrade(f, stream; kw...)
upgrade(stream::Stream, f::Function; kw...) = _upgrade(f, stream; kw...)

serve!(f, host="127.0.0.1", port=8080; suppress_close_error::Bool=false, maxframesize::Integer=typemax(Int), maxfragmentation::Integer=DEFAULT_MAX_FRAG, kw...) =
    HTTP.serve!(websocket_upgrade_handler, host, port; on_stream_complete=websocket_upgrade_function(f; suppress_close_error=suppress_close_error, maxframesize=maxframesize, maxfragmentation=maxfragmentation), kw...)

listen!(f, host="127.0.0.1", port=8080; kw...) = serve!(f, host, port; kw...)

function listen(f, host="127.0.0.1", port=8080; kw...)
    server = listen!(f, host, port; kw...)
    wait(server)
    return server
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
