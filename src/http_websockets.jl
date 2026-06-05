"""
    HTTP.WebSockets

WebSocket client and server helpers layered on top of the HTTP request/response
stack and `Reseau` transports.

Use [`open`](@ref) for client connections and [`listen!`](@ref),
[`listen`](@ref), or [`serve!`](@ref) for servers. Most applications will work
with [`WebSocket`](@ref) values directly rather than the lower-level
[`Conn`](@ref) codec state.
"""
module WebSockets

import Base: close, iterate, isready

import ..Headers
import ..HTTPError
import ..HostResolvers
import ..Request
import ..Response
import ..TCP
import ..TLS
import ..IOPoll
import ..Conn as TransportConn
import ..BytesBody
import ..EmptyBody
import ..ProtocolError
import ..TooManyRedirectsError
import ..Client
import ..CookieJar
import ..COOKIEJAR
import .._ConnReader
import .._USE_TRANSPORT_PROXY
import .._close_conn!
import .._client_for_request
import .._conn_reader_available
import .._conn_stream
import .._copy_request
import .._copy_request_for_send
import .._cookie_header
import .._effective_cookiejar
import .._host_for_sni
import .._host_path_from_request
import .._normalize_cookies_input
import .._normalize_headers_input
import .._parse_http_url
import .._prepare_request_for_redirect
import .._proxy_config_for_request
import .._proxy_plan
import .._ProxyPlanMode
import .._ProxyTarget
import .._read_incoming_response
import .._redirect_policy
import .._redirect_referer
import .._request_deadline_ns
import .._request_connect_host_resolver
import .._request_connect_phase_deadline_ns
import .._request_connect_phase_timeout_ns
import .._request_response_header_deadline_ns
import .._request_write_deadline_ns
import .._resolve_request_timeout_settings
import .._apply_request_timeout_settings!
import ..get_request_context
import .._request_url
import .._resolve_redirect_target
import .._should_copy_sensitive_headers_on_redirect
import .._store_set_cookies!
import .._strip_sensitive_redirect_headers!
import .._streaming_response
import .._apply_conn_deadline!
import .._clear_conn_deadline!
import .._new_conn!
import .._set_conn_read_deadline!
import .._set_conn_write_deadline!
import .._is_redirect_status
import .._base64encode
import ..@try_ignore
import ..header
import ..headers
import ..hasheader
import ..setheader
import ..removeheader
import ..body_close!
import ..read_request
import ..write_response!
import ..write_request!
import .._is_transport_timeout
import .._wrap_transport_timeout
import ..Stream
import .._clear_deadlines!

include("http_websocket_codec.jl")

const DEFAULT_MAX_FRAG = 1024
const DEFAULT_READ_BUFFER_BYTES = 16 * 1024

"""
    Conn

Low-level WebSocket codec connection state.

This is primarily useful for advanced integrations that need direct access to
frame-level state. Most client and server code should work with
[`WebSocket`](@ref) instead.
"""
const Conn = WSConn

"""
    CloseFrameBody(code, reason="")

Structured close payload carrying the WebSocket close status code and optional
UTF-8 reason text.
"""
struct CloseFrameBody
    code::Int
    reason::String
end

"""
    WebSocketError

Exception raised when a WebSocket closes or encounters a protocol/payload
error.

Inspect `err.message.code` and `err.message.reason` to distinguish normal
closures from errors.
"""
struct WebSocketError <: HTTPError
    message::CloseFrameBody
end

isok(err::WebSocketError) = return err.message.code in (1000, 1001, 1005)
isok(_) = return false

function Base.showerror(io::IO, err::WebSocketError)
    print(io, "websocket closed with status ", err.message.code)
    isempty(err.message.reason) || print(io, ": ", err.message.reason)
    return nothing
end

"""
    WebSocket

Stateful WebSocket endpoint returned by [`open`](@ref) and passed to server
handlers created by [`listen!`](@ref) or [`serve!`](@ref).

Use [`send`](@ref), [`receive`](@ref), [`ping`](@ref), `close(ws)`, or iterate
over the socket directly.
"""
mutable struct WebSocket{S,C}
    subprotocol::Union{Nothing,String}
    stream::S
    close_transport!::C
    codec::WSConn
    maxframesize::Int
    maxfragmentation::Int
    readchannel::Channel{Union{String,Vector{UInt8}}}
    readtask::Union{Nothing,Task}
    readclosed::Bool
    writeclosed::Bool
    closelock::ReentrantLock
    sendlock::ReentrantLock
    handshake_request::Union{Nothing,Request}
    handshake_response::Union{Nothing,Response}
    fragment_opcode::Union{Nothing,UInt8}
    fragment_payload::Vector{UInt8}
    fragment_count::Int
    closebody::Union{Nothing,CloseFrameBody}
    read_idle_timeout_ns::Int64
end

function WebSocket(
    stream::S,
    close_transport!::C;
    subprotocol::Union{Nothing,AbstractString}=nothing,
    maxframesize::Integer=typemax(Int),
    maxfragmentation::Integer=DEFAULT_MAX_FRAG,
    read_idle_timeout_ns::Integer=0,
    is_client::Bool=true,
) where {S,C}
    maxframesize > 0 || throw(ArgumentError("maxframesize must be > 0"))
    maxfragmentation > 0 || throw(ArgumentError("maxfragmentation must be > 0"))
    channel = Channel{Union{String,Vector{UInt8}}}(Inf)
    codec = WSConn(is_client=is_client)
    ws = WebSocket(
        subprotocol === nothing ? nothing : String(subprotocol),
        stream,
        close_transport!,
        codec,
        Int(maxframesize),
        Int(maxfragmentation),
        channel,
        nothing,
        false,
        false,
        ReentrantLock(),
        ReentrantLock(),
        nothing,
        nothing,
        nothing,
        UInt8[],
        0,
        nothing,
        Int64(read_idle_timeout_ns),
    )
    return ws
end

struct _ClientHandshake
    conn::Union{Nothing,TransportConn}
    response::Response
    buffered::Vector{UInt8}
    request::Request
end

isbinary(x) = x isa AbstractVector{UInt8}
istext(x) = x isa AbstractString
opcode(x) = isbinary(x) ? WsOpcode.BINARY : WsOpcode.TEXT
_to_bytes(x::AbstractVector{UInt8}) = x
_to_bytes(x::AbstractString) = codeunits(String(x))
_to_bytes(x) = codeunits(string(x))

function isclosed(ws::WebSocket)::Bool
    return ws.readclosed && ws.writeclosed
end

"""
    isupgrade(message) -> Bool

Return `true` when `message` is a WebSocket upgrade. For a request this checks
for a valid client upgrade handshake — use it to guard [`upgrade`](@ref) inside
an `HTTP.listen!` stream handler. For a response it checks for a `101 Switching
Protocols` handshake response.
"""
function isupgrade(message::Request)::Bool
    return ws_is_websocket_request(message)
end

function isupgrade(message::Response)::Bool
    message.status == 101 || return false
    _response_has_token(message.headers, "Upgrade", "websocket") || return false
    _response_has_token(message.headers, "Connection", "upgrade") || return false
    return true
end

function _response_has_token(hdrs::Headers, name::AbstractString, token::AbstractString)::Bool
    values = headers(hdrs, name)
    isempty(values) && return false
    lower_token = lowercase(token)
    for value in values
        for part in eachsplit(value, ',')
            lowercase(strip(part)) == lower_token && return true
        end
    end
    return false
end

function _queue_close!(ws::WebSocket, body::CloseFrameBody)::Nothing
    ws.closebody = body
    ws.readclosed = true
    if isopen(ws.readchannel)
        close(ws.readchannel, WebSocketError(body))
    end
    return nothing
end

function _close_channel!(ws::WebSocket)::Nothing
    isopen(ws.readchannel) && close(ws.readchannel)
    return nothing
end

function _enqueue_message!(ws::WebSocket, msg)::Nothing
    if isopen(ws.readchannel)
        @try_ignore begin
            put!(ws.readchannel, msg)
        end
    end
    return nothing
end

function _valid_close_status(code::Int)::Bool
    code < 0 && return false
    code > typemax(UInt16) && return false
    return ws_is_valid_close_status(UInt16(code))
end

function _take_conn_reader_buffer!(reader::_ConnReader)::Vector{UInt8}
    available = _conn_reader_available(reader)
    available == 0 && return UInt8[]
    buffered = Vector{UInt8}(undef, available)
    copyto!(buffered, 1, reader.buf, reader.next, available)
    reader.next = reader.stop + 1
    return buffered
end

function _flush_ws_output_locked!(ws::WebSocket)::Nothing
    outgoing = ws_get_outgoing_data!(ws.codec)
    isempty(outgoing) && return nothing
    write(ws.stream, outgoing)
    return nothing
end

function _flush_ws_output!(ws::WebSocket)::Nothing
    @lock ws.sendlock begin
        _flush_ws_output_locked!(ws)
    end
    return nothing
end

function _process_incoming_frame!(ws::WebSocket, frame::WsFrame)::Nothing
    frame.payload_length <= ws.maxframesize || begin
        close_body = CloseFrameBody(1009, "frame too large")
        _queue_close!(ws, close_body)
        return nothing
    end
    op = frame.opcode
    fin = frame.fin
    # `frame.payload` is already a fresh owned Vector (the decoder builds each
    # frame with `copy(dec.payload_buf)`) and the frame is discarded right after
    # this call, so we can take it directly instead of copying a second time.
    frame_payload = frame.payload
    if op == UInt8(WsOpcode.PING) || op == UInt8(WsOpcode.PONG)
        return nothing
    end
    if op == UInt8(WsOpcode.CLOSE)
        close_body = if length(frame_payload) >= 2
            code, reason = ws_decode_close_payload(frame_payload)
            _valid_close_status(Int(code)) || begin
                _queue_close!(ws, CloseFrameBody(1002, "invalid close status code"))
                return nothing
            end
            CloseFrameBody(Int(code), isempty(reason) ? "" : String(reason))
        else
            CloseFrameBody(1005, "")
        end
        ws.writeclosed = true
        _queue_close!(ws, close_body)
        return nothing
    end
    if op == UInt8(WsOpcode.CONTINUATION)
        if ws.fragment_opcode === nothing
            _queue_close!(ws, CloseFrameBody(1002, "unexpected continuation"))
            return nothing
        end
        ws.fragment_count += 1
        if ws.fragment_count > ws.maxfragmentation
            _queue_close!(ws, CloseFrameBody(1009, "message too large"))
            return nothing
        end
        append!(ws.fragment_payload, frame_payload)
        if fin
            msg_opcode = ws.fragment_opcode::UInt8
            data = copy(ws.fragment_payload)
            ws.fragment_opcode = nothing
            empty!(ws.fragment_payload)
            ws.fragment_count = 0
            if msg_opcode == UInt8(WsOpcode.TEXT)
                _enqueue_message!(ws, String(data))
            else
                _enqueue_message!(ws, data)
            end
        end
        return nothing
    end
    if op == UInt8(WsOpcode.TEXT) || op == UInt8(WsOpcode.BINARY)
        ws.fragment_opcode === nothing || begin
            _queue_close!(ws, CloseFrameBody(1002, "unexpected new data frame"))
            return nothing
        end
        if fin
            if op == UInt8(WsOpcode.TEXT)
                _enqueue_message!(ws, String(frame_payload))
            else
                _enqueue_message!(ws, frame_payload)
            end
            ws.fragment_count = 0
        else
            ws.fragment_opcode = op
            ws.fragment_payload = frame_payload
            ws.fragment_count = 1
            if ws.fragment_count > ws.maxfragmentation
                _queue_close!(ws, CloseFrameBody(1009, "message too large"))
            end
        end
    end
    return nothing
end

# Set the read deadline directly on the underlying Reseau stream so an opt-in
# WebSocket read idle timeout can be re-armed before each read.
_ws_arm_read_deadline!(stream, deadline_ns::Int64) = TLS.set_read_deadline!(stream, deadline_ns)

function _ws_read_loop!(ws::WebSocket, buffer_bytes::Int=DEFAULT_READ_BUFFER_BYTES)::Nothing
    buffer_bytes > 0 || throw(ArgumentError("buffer_bytes must be > 0"))
    buf = Vector{UInt8}(undef, buffer_bytes)
    try
        while true
            # Opt-in read idle timeout: re-arm before each read so it fires only
            # after `read_idle_timeout` seconds with no data, resetting whenever a
            # frame arrives (#1062).
            ws.read_idle_timeout_ns > 0 &&
                _ws_arm_read_deadline!(ws.stream, Int64(time_ns()) + ws.read_idle_timeout_ns)
            # Read directly into the reusable `buf`. `readavailable` would
            # allocate a fresh Base.SZ_UNBUFFERED_IO (64KB) buffer on every
            # frame read (16× the bytes/RTT vs HTTP 1.x), driving GC pressure;
            # `readbytes!(...; all=false)` does one socket read into `buf`.
            n = readbytes!(ws.stream, buf, length(buf); all=false)
            n == 0 && break
            ws_on_incoming_data!(frame -> _process_incoming_frame!(ws, frame), ws.codec, @view buf[1:n])
            _flush_ws_output!(ws)
            ws.readclosed && break
        end
        if !ws.readclosed
            _queue_close!(ws, CloseFrameBody(1006, ""))
        end
    catch err
        # A read idle timeout surfaces as IOPoll.DeadlineExceededError over TCP, or
        # wrapped in a TLS.TLSError (`.cause`) over TLS.
        read_timed_out = err isa IOPoll.DeadlineExceededError ||
            (err isa TLS.TLSError && (err::TLS.TLSError).cause isa IOPoll.DeadlineExceededError)
        close_body = if read_timed_out
            CloseFrameBody(1006, "websocket read idle timeout")
        elseif err isa WebSocketInvalidPayloadError
            CloseFrameBody(1007, "invalid websocket payload")
        elseif err isa WebSocketProtocolError
            CloseFrameBody(1002, "websocket protocol error")
        else
            CloseFrameBody(1006, "")
        end
        if !ws.readclosed
            _queue_close!(ws, close_body)
        end
        if !ws.writeclosed && close_body.code != 1006
            @try_ignore begin
                close(ws, close_body)
            end
        end
    finally
        if ws.readclosed && ws.writeclosed
            @try_ignore begin
                ws.close_transport!()
            end
        end
    end
    return nothing
end

function _start_read_task!(ws::WebSocket, buffer_bytes::Int=DEFAULT_READ_BUFFER_BYTES)::Nothing
    ws.readtask !== nothing && return nothing
    # Sticky (`@async`, not `Threads.@spawn`): pin the reader to a home thread.
    # The poller wakes it via `schedule(task)`; a migratable reader would be
    # woken into the global pool, forcing a cold parked-worker wake whose cost
    # scales with nthreads (catastrophic at -t 32). Requires Reseau's `pollwait!`
    # to preserve task stickiness (it must not reset `task.sticky = false`).
    ws.readtask = @async _ws_read_loop!(ws, buffer_bytes)
    return nothing
end

"""
    send(ws, message) -> Int

Send one text or binary message on `ws`.

`message` may be an `AbstractString`, an `AbstractVector{UInt8}`, or an
iterable of chunks. Iterable inputs are sent as one fragmented message and the
returned value is the total payload bytes sent.
"""
function send(ws::WebSocket, x)
    @lock ws.sendlock begin
        ws.writeclosed && throw(WebSocketError(CloseFrameBody(1006, "websocket is closed")))
        if !isbinary(x) && !istext(x)
            first = true
            total = 0
            state = iterate(x)
            if state === nothing
                ws_send_frame!(ws.codec, UInt8(WsOpcode.TEXT), UInt8[]; fin=true)
                _flush_ws_output_locked!(ws)
                return 0
            end
            item, st = state
            next_state = iterate(x, st)
            while true
                total += length(_to_bytes(item))
                ws_send_frame!(ws.codec, UInt8(first ? opcode(item) : WsOpcode.CONTINUATION), _to_bytes(item); fin=next_state === nothing)
                first = false
                next_state === nothing && break
                item, st = next_state
                next_state = iterate(x, st)
            end
            _flush_ws_output_locked!(ws)
            return total
        end
        bytes = _to_bytes(x)
        ws_send_frame!(ws.codec, UInt8(opcode(x)), bytes; fin=true)
        _flush_ws_output_locked!(ws)
        return length(bytes)
    end
end

"""
    ping(ws, data=UInt8[]) -> nothing

Send a WebSocket ping control frame with optional payload bytes.
"""
function ping(ws::WebSocket, data=UInt8[])
    @lock ws.sendlock begin
        ws.writeclosed && throw(WebSocketError(CloseFrameBody(1006, "websocket is closed")))
        ws_send_ping!(ws.codec, _to_bytes(data))
        _flush_ws_output_locked!(ws)
    end
    return nothing
end

"""
    pong(ws, data=UInt8[]) -> nothing

Send a WebSocket pong control frame with optional payload bytes.
"""
function pong(ws::WebSocket, data=UInt8[])
    @lock ws.sendlock begin
        ws.writeclosed && throw(WebSocketError(CloseFrameBody(1006, "websocket is closed")))
        ws_send_pong!(ws.codec, _to_bytes(data))
        _flush_ws_output_locked!(ws)
    end
    return nothing
end

"""
    receive(ws) -> Union{String, Vector{UInt8}}

Receive the next complete message from `ws`.

Text messages are returned as `String`; binary messages are returned as
`Vector{UInt8}`. Throws `WebSocketError` once the connection has closed.
"""
function receive(ws::WebSocket)
    if ws.readclosed || !isopen(ws.readchannel)
        if isready(ws.readchannel)
            return take!(ws.readchannel)
        end
        throw(WebSocketError(ws.closebody === nothing ? CloseFrameBody(1006, "") : ws.closebody::CloseFrameBody))
    end
    return take!(ws.readchannel)
end

"""
    isready(ws) -> Bool

Return `true` when at least one complete message is buffered and can be read with
[`receive`](@ref) without blocking, and `false` otherwise. Useful for polling a
WebSocket for incoming messages without committing to a blocking `receive`.

A `false` result does not imply the connection is closed — more messages may
still arrive. Conversely, messages buffered before the connection closed remain
`isready` and are returned by `receive` before it throws.
"""
isready(ws::WebSocket)::Bool = isready(ws.readchannel)

function Base.iterate(ws::WebSocket, st=nothing)
    # Note: do not early-return on isclosed(ws) here: messages may still be
    # buffered in ws.readchannel after the read task has set readclosed=true
    # and the close path has set writeclosed=true. receive() already handles
    # the buffered-take fast-path when the channel is closed but non-empty.
    if isclosed(ws) && !isready(ws.readchannel)
        return nothing
    end
    try
        return receive(ws), nothing
    catch err
        isok(err) && return nothing
        rethrow(err)
    end
end

function close(ws::WebSocket, body::Union{Nothing,CloseFrameBody}=nothing)
    @lock ws.closelock begin
        if !ws.writeclosed
            ws.writeclosed = true
            if body !== nothing
                if !_valid_close_status(body.code)
                    body = CloseFrameBody(1002, "invalid close status code")
                end
                @try_ignore begin
                    @lock ws.sendlock begin
                        ws_close!(ws.codec; status_code=UInt16(body.code), reason=codeunits(body.reason))
                        _flush_ws_output_locked!(ws)
                    end
                end
            else
                @try_ignore begin
                    @lock ws.sendlock begin
                        ws_close!(ws.codec; status_code=UInt16(1000), reason=UInt8[])
                        _flush_ws_output_locked!(ws)
                    end
                end
            end
        end
    end
    if !ws.readclosed
        deadline = time() + 5.0
        while time() < deadline
            ws.readclosed && break
            IOPoll.sleep(0.05)
        end
        ws.readclosed = true
    end
    @try_ignore begin
        ws.close_transport!()
    end
    _close_channel!(ws)
    return nothing
end

function _apply_websocket_request_headers!(
    headers::Headers,
    key::String,
    subprotocols::AbstractVector{<:AbstractString}=String[],
)::Nothing
    setheader(headers, "Upgrade", "websocket")
    setheader(headers, "Connection", "Upgrade")
    setheader(headers, "Sec-WebSocket-Key", key)
    setheader(headers, "Sec-WebSocket-Version", "13")
    if isempty(subprotocols)
        removeheader(headers, "Sec-WebSocket-Protocol")
    else
        setheader(headers, "Sec-WebSocket-Protocol", join(String.(subprotocols), ", "))
    end
    return nothing
end

function _parse_websocket_url(url::AbstractString, query=nothing)
    text = String(url)
    lower = lowercase(text)
    if startswith(lower, "ws://")
        return _parse_http_url("http://" * text[6:end], query)
    elseif startswith(lower, "wss://")
        return _parse_http_url("https://" * text[7:end], query)
    elseif startswith(lower, "http://") || startswith(lower, "https://")
        return _parse_http_url(text, query)
    end
    throw(ArgumentError("websocket URL must use ws://, wss://, http://, or https://"))
end

function _normalize_websocket_redirect_location(location::AbstractString)::String
    text = String(location)
    lower = lowercase(text)
    if startswith(lower, "ws://")
        return "http://" * text[6:end]
    elseif startswith(lower, "wss://")
        return "https://" * text[7:end]
    end
    return text
end

function _validate_websocket_upgrade!(
    response::Response,
    expected_accept::String,
    requested_subprotocols::AbstractVector{<:AbstractString},
)::Union{Nothing,String}
    isupgrade(response) || throw(WebSocketError(CloseFrameBody(1002, "websocket handshake failed")))
    accept = header(response.headers, "Sec-WebSocket-Accept")
    accept == expected_accept || throw(WebSocketError(CloseFrameBody(1002, "websocket handshake accept mismatch")))
    subprotocol = header(response.headers, "Sec-WebSocket-Protocol", nothing)
    subprotocol === nothing && return nothing
    normalized = strip(subprotocol)
    isempty(normalized) && return nothing
    if isempty(requested_subprotocols)
        throw(WebSocketError(CloseFrameBody(1002, "unexpected websocket subprotocol in response")))
    end
    normalized in String.(requested_subprotocols) || throw(WebSocketError(CloseFrameBody(1002, "unrequested websocket subprotocol in response")))
    return normalized
end

function _websocket_roundtrip!(
    client::Client,
    address::String,
    request::Request,
    secure::Bool,
    server_name::String,
    proxy_config,
)::_ClientHandshake
    deadline_ns = _request_deadline_ns(request)
    connect_host_resolver = _request_connect_host_resolver(client.transport.host_resolver, request)
    connect_deadline_ns = _request_connect_phase_deadline_ns(client.transport.host_resolver, request)
    tls_handshake_timeout_ns = _request_connect_phase_timeout_ns(client.transport.host_resolver, request)
    plan = _proxy_plan(proxy_config, secure, address)
    conn = _new_conn!(
        client.transport,
        plan,
        address,
        secure,
        server_name,
        connect_host_resolver,
        connect_deadline_ns,
        tls_handshake_timeout_ns,
    )
    try
        _apply_conn_deadline!(conn, deadline_ns)
        request_io = conn.request_buf
        truncate(request_io, 0)
        seekstart(request_io)
        wire_target = plan.mode == _ProxyPlanMode.HTTP_FORWARD ? _request_url(secure, address, request.target) : nothing
        proxy_auth = plan.mode == _ProxyPlanMode.HTTP_FORWARD && plan.proxy !== nothing ? (plan.proxy::_ProxyTarget).authorization : nothing
        write_request!(request_io, request; wire_target=wire_target, proxy_authorization=proxy_auth)
        stream = _conn_stream(conn)
        nbytes = request_io.size
        _set_conn_write_deadline!(conn, _request_write_deadline_ns(request))
        wrote = write(stream, request_io.data, nbytes)
        wrote == nbytes || throw(ProtocolError("transport short write"))
        _set_conn_read_deadline!(conn, _request_response_header_deadline_ns(request))
        response = _read_incoming_response(conn.reader, request)
        @try_ignore begin
            body_close!(response.rawbody)
        end
        buffered = response.head.status == 101 ? _take_conn_reader_buffer!(conn.reader) : UInt8[]
        public_response = _streaming_response(response)
        if response.head.status != 101
            _close_conn!(conn)
            return _ClientHandshake(nothing, public_response, UInt8[], request)
        end
        _clear_conn_deadline!(conn)
        return _ClientHandshake(conn, public_response, buffered, request)
    catch
        _close_conn!(conn)
        rethrow()
    end
end

function _open_client_websocket(
    url::AbstractString;
    headers=Pair{String,String}[],
    maxframesize::Integer=typemax(Int),
    maxfragmentation::Integer=DEFAULT_MAX_FRAG,
    subprotocols::AbstractVector{<:AbstractString}=String[],
    query=nothing,
    client::Union{Nothing,Client}=nothing,
    redirect::Bool=true,
    redirect_limit::Union{Nothing,Integer}=nothing,
    redirect_method=nothing,
    forwardheaders::Bool=true,
    cookies=true,
    cookiejar::Union{Nothing,CookieJar}=nothing,
    proxy=_USE_TRANSPORT_PROXY,
    connect_timeout::Real=30,
    request_timeout::Real=0,
    response_header_timeout::Real=0,
    read_idle_timeout::Real=0,
    write_idle_timeout::Real=0,
    require_ssl_verification::Bool=true
)::WebSocket
    parsed = _parse_websocket_url(url, query)
    req_headers = _normalize_headers_input(headers)
    normalized_cookies = _normalize_cookies_input(cookies)
    if parsed.authorization !== nothing && !hasheader(req_headers, "Authorization")
        setheader(req_headers, "Authorization", parsed.authorization::String)
    end
    key = ws_random_handshake_key()
    _apply_websocket_request_headers!(req_headers, key, subprotocols)
    request = Request("GET", parsed.target; headers=req_headers, host=parsed.address, body=EmptyBody(), content_length=0)
    request_timeout_ns, timeout_config = _resolve_request_timeout_settings(
        request_timeout,
        connect_timeout,
        response_header_timeout,
        read_idle_timeout,
        write_idle_timeout,
    )
    _apply_request_timeout_settings!(get_request_context(request), request_timeout_ns, timeout_config)
    req_client, owns_client = _client_for_request(client, connect_timeout, require_ssl_verification)
    client === nothing || proxy === _USE_TRANSPORT_PROXY || throw(ArgumentError("proxy override is not supported when passing an explicit Client"))
    proxy_config = _proxy_config_for_request(req_client, proxy)
    effective_cookiejar = _effective_cookiejar(client, cookiejar)
    redirect_policy = _redirect_policy(req_client, redirect ? redirect_limit : 0, redirect_method, forwardheaders)
    current_address = parsed.address
    current_secure = parsed.secure
    current_server_name = parsed.server_name
    current_request = request
    initial_address = current_address
    for redirect_count in 0:redirect_policy.max_redirects
        send_request = _copy_request(current_request)
        host, path = _host_path_from_request(current_address, current_request)
        cookie_value = _cookie_header(effective_cookiejar, normalized_cookies, current_secure, host, path)
        cookie_value === nothing || setheader(send_request.headers, "Cookie", cookie_value)
        expected_accept = ws_compute_accept_key(header(send_request.headers, "Sec-WebSocket-Key")::String)
        attempt = _websocket_roundtrip!(req_client, current_address, send_request, current_secure, current_server_name, proxy_config)
        _store_set_cookies!(effective_cookiejar, normalized_cookies, current_secure, host, path, attempt.response.headers)
        response = attempt.response
        if response.status == 101
            negotiated = try
                _validate_websocket_upgrade!(response, expected_accept, subprotocols)
            catch
                attempt.conn === nothing || _close_conn!(attempt.conn::TransportConn)
                owns_client && close(req_client)
                rethrow()
            end
            conn = attempt.conn
            if conn === nothing
                owns_client && close(req_client)
                throw(ProtocolError("websocket upgrade succeeded without an active connection"))
            end
            close_transport! = let conn = conn::TransportConn, owned_client = owns_client, local_client = req_client
                () -> begin
                    _close_conn!(conn)
                    owned_client && close(local_client)
                    return nothing
                end
            end
            ws = WebSocket(
                _conn_stream(conn),
                close_transport!,
                subprotocol=negotiated,
                maxframesize=maxframesize,
                maxfragmentation=maxfragmentation,
                read_idle_timeout_ns=read_idle_timeout > 0 ? round(Int64, read_idle_timeout * 1.0e9) : Int64(0),
                is_client=true,
            )
            ws.handshake_request = send_request
            ws.handshake_response = response
            if !isempty(attempt.buffered)
                ws_on_incoming_data!(frame -> _process_incoming_frame!(ws, frame), ws.codec, attempt.buffered)
                _flush_ws_output!(ws)
            end
            _start_read_task!(ws)
            return ws
        end
        if !_is_redirect_status(response.status) || redirect_policy.max_redirects == 0
            owns_client && close(req_client)
            throw(WebSocketError(CloseFrameBody(1002, "websocket handshake failed: status $(response.status)")))
        end
        location = header(response.headers, "Location", nothing)
        if location === nothing || isempty(location::String)
            owns_client && close(req_client)
            throw(WebSocketError(CloseFrameBody(1002, "websocket handshake failed: status $(response.status)")))
        end
        if redirect_count == redirect_policy.max_redirects
            owns_client && close(req_client)
            throw(TooManyRedirectsError(redirect_policy.max_redirects, response))
        end
        previous_secure = current_secure
        previous_address = current_address
        previous_target = current_request.target
        current_address, current_secure, next_target = _resolve_redirect_target(
            current_address,
            current_secure,
            _normalize_websocket_redirect_location(location::String),
            current_request.target,
        )
        current_server_name = _host_for_sni(current_address)
        current_request = _prepare_request_for_redirect(current_request, response.status, next_target, redirect_policy)
        key = ws_random_handshake_key()
        _apply_websocket_request_headers!(current_request.headers, key, subprotocols)
        current_request.host = current_address
        next_ref = _redirect_referer(previous_secure, previous_address, previous_target, current_secure, header(current_request.headers, "Referer", nothing))
        if next_ref === nothing
            removeheader(current_request.headers, "Referer")
        else
            setheader(current_request.headers, "Referer", next_ref::String)
        end
        if !_should_copy_sensitive_headers_on_redirect(initial_address, current_address)
            _strip_sensitive_redirect_headers!(current_request.headers)
            _apply_websocket_request_headers!(current_request.headers, key, subprotocols)
        end
    end
    owns_client && close(req_client)
    throw(ProtocolError("unexpected websocket redirect loop termination"))
end

"""
    open(url; kwargs...) -> WebSocket
    open(f, url; kwargs...) -> Any

Open a client WebSocket connection to `url`.

Keyword arguments cover handshake headers, redirect behavior, cookies, proxy
selection, TLS verification, handshake timeout controls, and frame limits.
`request_timeout` applies an overall handshake deadline, while
`response_header_timeout`, `read_idle_timeout`, and `write_idle_timeout`
configure the underlying HTTP handshake phases. When called with a function,
the socket is closed automatically with status code `1000` when `f` returns.
"""
function open(
    url::AbstractString;
    suppress_close_error::Bool=false,
    headers=Pair{String,String}[],
    maxframesize::Integer=typemax(Int),
    maxfragmentation::Integer=DEFAULT_MAX_FRAG,
    subprotocols::AbstractVector{<:AbstractString}=String[],
    query=nothing,
    client::Union{Nothing,Client}=nothing,
    redirect::Bool=true,
    redirect_limit::Union{Nothing,Integer}=nothing,
    redirect_method=nothing,
    forwardheaders::Bool=true,
    cookies=true,
    cookiejar::Union{Nothing,CookieJar}=nothing,
    proxy=_USE_TRANSPORT_PROXY,
    connect_timeout::Real=30,
    request_timeout::Real=0,
    response_header_timeout::Real=0,
    read_idle_timeout::Real=0,
    write_idle_timeout::Real=0,
    require_ssl_verification::Bool=true,
    kwargs...,
)
    ws = try
        _open_client_websocket(
            url;
            headers=headers,
            maxframesize=maxframesize,
            maxfragmentation=maxfragmentation,
            subprotocols=subprotocols,
            query=query,
            client=client,
            redirect=redirect,
            redirect_limit=redirect_limit,
            redirect_method=redirect_method,
            forwardheaders=forwardheaders,
            cookies=cookies,
            cookiejar=cookiejar,
            proxy=proxy,
            connect_timeout=connect_timeout,
            request_timeout=request_timeout,
            response_header_timeout=response_header_timeout,
            read_idle_timeout=read_idle_timeout,
            write_idle_timeout=write_idle_timeout,
            require_ssl_verification=require_ssl_verification,
            kwargs...,
        )
    catch err
        _is_transport_timeout(err) && throw(_wrap_transport_timeout(err, "websocket handshake"))
        rethrow()
    end
    return ws
end

function open(
    f::Function,
    url::AbstractString;
    suppress_close_error::Bool=false,
    kwargs...,
)
    ws = open(url; suppress_close_error=suppress_close_error, kwargs...)
    try
        return f(ws)
    catch err
        if err isa WebSocketError && isok(err)
            return nothing
        end
        rethrow(err)
    finally
        if !isclosed(ws)
            try
                close(ws, CloseFrameBody(1000, ""))
            catch err
                if !(suppress_close_error && err isa WebSocketError)
                    rethrow(err)
                end
            end
        end
    end
end

"""
    Server(; network="tcp", address="127.0.0.1:0", handler, tls_config=nothing, ...)

WebSocket server handle returned by [`listen!`](@ref) and [`serve!`](@ref).

Hold onto the returned value so you can inspect its bound address with
[`server_addr`](@ref), wait on it with `wait(server)`, or stop it with
[`forceclose`](@ref).
"""
mutable struct Server{F}
    network::String
    address::String
    handler::F
    tls_config::Union{Nothing,TLS.Config}
    subprotocols::Vector{String}
    check_origin::Union{Nothing,Function}
    maxframesize::Int
    maxfragmentation::Int
    read_buffer_bytes::Int
    lock::ReentrantLock
    listener::Union{Nothing,TCP.Listener,TLS.Listener}
    serve_task::Union{Nothing,Task}
    active_tcp_conns::Set{TCP.Conn}
    active_tls_conns::Set{TLS.Conn}
    active_tasks::Set{Task}
    active_sessions::IdDict{Any,Nothing}
    bound_address::Union{Nothing,String}
    @atomic shutting_down::Bool
end

function Server(;
    network::AbstractString="tcp",
    address::AbstractString="127.0.0.1:0",
    handler::F,
    tls_config::Union{Nothing,TLS.Config}=nothing,
    subprotocols::AbstractVector{<:AbstractString}=String[],
    check_origin::Union{Nothing,Function}=nothing,
    maxframesize::Integer=typemax(Int),
    maxfragmentation::Integer=DEFAULT_MAX_FRAG,
    read_buffer_bytes::Integer=DEFAULT_READ_BUFFER_BYTES,
) where {F}
    maxframesize > 0 || throw(ArgumentError("maxframesize must be > 0"))
    maxfragmentation > 0 || throw(ArgumentError("maxfragmentation must be > 0"))
    read_buffer_bytes > 0 || throw(ArgumentError("read_buffer_bytes must be > 0"))
    return Server(
        String(network),
        String(address),
        handler,
        tls_config,
        String.(subprotocols),
        check_origin,
        Int(maxframesize),
        Int(maxfragmentation),
        Int(read_buffer_bytes),
        ReentrantLock(),
        nothing,
        nothing,
        Set{TCP.Conn}(),
        Set{TLS.Conn}(),
        Set{Task}(),
        IdDict{Any,Nothing}(),
        nothing,
        false,
    )
end

@inline function _server_shutting_down(server::Server)::Bool
    return @atomic :acquire server.shutting_down
end

"""
    server_addr(server) -> String

Return the host:port address currently bound by `server`.
"""
function server_addr(server::Server)::String
    lock(server.lock)
    try
        server.bound_address === nothing && throw(ProtocolError("websocket server is not listening"))
        return server.bound_address::String
    finally
        unlock(server.lock)
    end
end

function _listener_bound_address(listener)::String
    if listener isa TLS.Listener
        laddr = TLS.addr(listener::TLS.Listener)
    else
        laddr = TCP.addr(listener::TCP.Listener)
    end
    if laddr isa TCP.SocketAddrV4
        return HostResolvers.join_host_port("127.0.0.1", Int((laddr::TCP.SocketAddrV4).port))
    end
    return HostResolvers.join_host_port("::1", Int((laddr::TCP.SocketAddrV6).port))
end

function _track_conn!(server::Server, conn, task::Task)::Nothing
    lock(server.lock)
    try
        if conn isa TCP.Conn
            push!(server.active_tcp_conns, conn::TCP.Conn)
        else
            push!(server.active_tls_conns, conn::TLS.Conn)
        end
        push!(server.active_tasks, task)
    finally
        unlock(server.lock)
    end
    return nothing
end

function _untrack_conn!(server::Server, conn, task::Task)::Nothing
    lock(server.lock)
    try
        if conn isa TCP.Conn
            delete!(server.active_tcp_conns, conn::TCP.Conn)
        else
            delete!(server.active_tls_conns, conn::TLS.Conn)
        end
        delete!(server.active_tasks, task)
    finally
        unlock(server.lock)
    end
    return nothing
end

function _track_session!(server::Server, ws::WebSocket)::Nothing
    lock(server.lock)
    try
        server.active_sessions[ws] = nothing
    finally
        unlock(server.lock)
    end
    return nothing
end

function _untrack_session!(server::Server, ws::WebSocket)::Nothing
    lock(server.lock)
    try
        delete!(server.active_sessions, ws)
    finally
        unlock(server.lock)
    end
    return nothing
end

function _active_sessions(server::Server)::Vector{Any}
    sessions = []
    lock(server.lock)
    try
        append!(sessions, keys(server.active_sessions))
    finally
        unlock(server.lock)
    end
    return sessions
end

function _active_ws_tasks(server::Server)::Vector{Task}
    tasks = Task[]
    lock(server.lock)
    try
        append!(tasks, server.active_tasks)
    finally
        unlock(server.lock)
    end
    return tasks
end

function _close_ws_server_conn!(conn)::Nothing
    @try_ignore begin
        if conn isa TLS.Conn
            TLS.close(conn::TLS.Conn)
        else
            TCP.close(conn::TCP.Conn)
        end
    end
    return nothing
end

function _write_ws_response!(conn, response::Response)::Nothing
    io = IOBuffer()
    write_response!(io, response)
    bytes = take!(io)
    write(conn, bytes)
    return nothing
end

function _origin_allowed_default(request::Request)::Bool
    origin = header(request.headers, "Origin", nothing)
    origin === nothing && return true
    parsed = try
        _parse_http_url(origin::String)
    catch
        return false
    end
    request_host = request.host === nothing ? header(request.headers, "Host", nothing) : request.host
    request_host === nothing && return false
    origin_host, origin_port = HostResolvers.split_host_port(parsed.address)
    if occursin(':', request_host::String)
        req_host, req_port = HostResolvers.split_host_port(request_host::String)
        return lowercase(origin_host) == lowercase(req_host) && origin_port == req_port
    end
    return lowercase(origin_host) == lowercase(request_host::String)
end

function _run_origin_check(checker, request::Request)::Bool
    origin = header(request.headers, "Origin", nothing)
    if applicable(checker, request, origin)
        result = checker(request, origin)
    elseif applicable(checker, request)
        result = checker(request)
    else
        throw(ArgumentError("check_origin callback must accept (request) or (request, origin)"))
    end
    result isa Bool || throw(ArgumentError("check_origin callback must return Bool"))
    return result
end

function _origin_allowed(server::Server, request::Request)::Bool
    checker = server.check_origin
    checker === nothing && return _origin_allowed_default(request)
    return _run_origin_check(checker, request)
end

function _upgrade_response(
    request::Request;
    subprotocols::AbstractVector{<:AbstractString}=String[],
    check_origin::Union{Nothing,Function}=nothing,
)::Response
    uppercase(request.method) == "GET" || return Response(400, BytesBody(Vector{UInt8}("websocket upgrade required")); content_length=26, headers=Headers())
    _ws_headers_have_token(request.headers, "Upgrade", "websocket", false) || return Response(400, BytesBody(Vector{UInt8}("websocket upgrade required")); content_length=26, headers=Headers())
    _ws_headers_have_token(request.headers, "Connection", "upgrade", false) || return Response(400, BytesBody(Vector{UInt8}("websocket upgrade required")); content_length=26, headers=Headers())
    version = header(request.headers, "Sec-WebSocket-Version", nothing)
    version === nothing && return Response(400, BytesBody(Vector{UInt8}("websocket upgrade required")); content_length=26, headers=Headers())
    strip(version) == "13" || return Response(400, BytesBody(Vector{UInt8}("websocket upgrade required")); content_length=26, headers=Headers())
    raw_key = header(request.headers, "Sec-WebSocket-Key", nothing)
    raw_key === nothing && return Response(400, BytesBody(Vector{UInt8}("missing websocket key")); content_length=21, headers=Headers())
    allowed = check_origin === nothing ? _origin_allowed_default(request) : _run_origin_check(check_origin, request)
    allowed || return Response(403, BytesBody(Vector{UInt8}("websocket origin rejected")); content_length=25, headers=Headers())
    key = ws_get_request_sec_websocket_key(request)
    key === nothing && return Response(400, BytesBody(Vector{UInt8}("invalid websocket key")); content_length=21, headers=Headers())
    headers = Headers()
    setheader(headers, "Upgrade", "websocket")
    setheader(headers, "Connection", "Upgrade")
    setheader(headers, "Sec-WebSocket-Accept", ws_compute_accept_key(key::String))
    selected = isempty(subprotocols) ? nothing : ws_select_subprotocol(request, subprotocols)
    selected === nothing || setheader(headers, "Sec-WebSocket-Protocol", selected::String)
    return Response(101, EmptyBody(); headers=headers, content_length=0, request=request)
end

_upgrade_response(request::Request, server::Server)::Response =
    _upgrade_response(request; subprotocols=server.subprotocols, check_origin=server.check_origin)

"""
    upgrade(f, stream::HTTP.Stream; kwargs...)

Upgrade an in-flight HTTP/1.1 server `stream` to a WebSocket connection and run
`f(ws::WebSocket)`. This is the manual counterpart to [`listen!`](@ref): it lets
a single `HTTP.listen!` / `HTTP.Router` server mix ordinary HTTP routes with
WebSocket routes by upgrading the connection from inside a stream handler.

Guard the call with [`isupgrade`](@ref) and call `upgrade` before writing any
response to the stream:

```julia
HTTP.listen!("127.0.0.1", 8080) do stream
    if HTTP.WebSockets.isupgrade(stream.message)
        HTTP.WebSockets.upgrade(stream) do ws
            for msg in ws
                HTTP.WebSockets.send(ws, msg)
            end
        end
    else
        HTTP.setstatus(stream, 200)
        HTTP.startwrite(stream)
        write(stream, "ok")
    end
end
```

`f` runs synchronously; the connection is closed when it returns. Keyword
arguments mirror [`listen!`](@ref): `subprotocols`, `check_origin`,
`maxframesize`, and `maxfragmentation`. WebSocket upgrades over HTTP/2 are not
supported.
"""
function upgrade(
    f::Function,
    stream::Stream;
    subprotocols::AbstractVector{<:AbstractString}=String[],
    check_origin::Union{Nothing,Function}=nothing,
    maxframesize::Integer=typemax(Int),
    maxfragmentation::Integer=DEFAULT_MAX_FRAG,
)
    stream.tracked === nothing &&
        throw(WebSocketError(CloseFrameBody(1011, "stream cannot be upgraded: not an HTTP/1.1 server stream")))
    (stream.message.proto_major != UInt8(1) || stream.h2_conn !== nothing) &&
        throw(WebSocketError(CloseFrameBody(1011, "WebSocket upgrade over HTTP/2 is not supported")))

    conn = stream.tracked.conn
    response = _upgrade_response(stream.message; subprotocols=subprotocols, check_origin=check_origin)
    _write_ws_response!(conn, response)

    # We have written the handshake response directly to the connection, so take
    # ownership of it away from the normal HTTP/1 server loop: mark the stream's
    # read/write sides closed (so the loop's post-handler closewrite/closeread
    # become no-ops) and request connection close (so the loop does not try to
    # read another request off what is now a WebSocket).
    @atomic :release stream.response_started = true
    @atomic :release stream.write_closed = true
    @atomic :release stream.read_closed = true
    stream.response.close = true

    if response.status != 101
        _close_ws_server_conn!(conn)
        throw(WebSocketError(CloseFrameBody(1002, "websocket upgrade rejected with status $(response.status)")))
    end

    # The server loop armed a body read-deadline before invoking the handler and
    # only clears it after the handler returns (i.e. after this whole session);
    # clear it now so a long-lived socket is not torn down mid-session.
    _clear_deadlines!(conn)

    buffered = stream.reader isa _ConnReader ? _take_conn_reader_buffer!(stream.reader::_ConnReader) : UInt8[]
    close_transport! = let conn = conn
        () -> _close_ws_server_conn!(conn)
    end
    ws = WebSocket(
        conn,
        close_transport!,
        subprotocol=header(response.headers, "Sec-WebSocket-Protocol"),
        maxframesize=maxframesize,
        maxfragmentation=maxfragmentation,
        is_client=false,
    )
    ws.handshake_request = stream.message
    ws.handshake_response = response
    if !isempty(buffered)
        ws_on_incoming_data!(frame -> _process_incoming_frame!(ws, frame), ws.codec, buffered)
        _flush_ws_output!(ws)
    end
    _start_read_task!(ws)
    try
        f(ws)
    catch err
        if !isclosed(ws)
            if err isa WebSocketError
                close(ws, (err::WebSocketError).message)
            else
                close(ws, CloseFrameBody(1011, "unexpected server websocket error"))
            end
        end
        isok(err) || rethrow(err)
    finally
        if !isclosed(ws)
            body = ws.closebody === nothing ? CloseFrameBody(1000, "") : ws.closebody::CloseFrameBody
            @try_ignore begin
                close(ws, body)
            end
        end
    end
    return nothing
end

function _serve_ws_session!(server::Server, conn, request::Request, response::Response)::Nothing
    close_transport! = () -> begin
        _close_ws_server_conn!(conn)
        return nothing
    end
    ws = WebSocket(
        conn,
        close_transport!,
        subprotocol=header(response.headers, "Sec-WebSocket-Protocol"),
        maxframesize=server.maxframesize,
        maxfragmentation=server.maxfragmentation,
        is_client=false,
    )
    ws.handshake_request = request
    ws.handshake_response = response
    _start_read_task!(ws, server.read_buffer_bytes)
    _track_session!(server, ws)
    try
        server.handler(ws)
    catch err
        if !isclosed(ws)
            if err isa WebSocketError
                close(ws, (err::WebSocketError).message)
            else
                close(ws, CloseFrameBody(1011, "unexpected server websocket error"))
            end
        end
        isok(err) || rethrow(err)
    finally
        if !isclosed(ws)
            # Prefer the real close reason captured by _queue_close! (e.g.
            # 1009 frame too large, 1007 invalid utf8, 1002 protocol error)
            # over the default 1000 so the peer sees the actual cause when
            # a handler returns normally after an internal protocol violation.
            body = ws.closebody === nothing ? CloseFrameBody(1000, "") : ws.closebody::CloseFrameBody
            @try_ignore begin
                close(ws, body)
            end
        end
        _untrack_session!(server, ws)
    end
    return nothing
end

function _serve_ws_conn!(server::Server, conn)::Nothing
    task = current_task()
    _track_conn!(server, conn, task)
    try
        request = read_request(_ConnReader(conn))
        response = _upgrade_response(request, server)
        _write_ws_response!(conn, response)
        response.status == 101 || return nothing
        _serve_ws_session!(server, conn, request, response)
    finally
        _close_ws_server_conn!(conn)
        _untrack_conn!(server, conn, task)
    end
    return nothing
end

function _mark_ws_server_listening!(server::Server, listener)::Nothing
    bound_address = _listener_bound_address(listener)
    lock(server.lock)
    try
        server.listener = listener
        server.bound_address = bound_address
    finally
        unlock(server.lock)
    end
    return nothing
end

function serve!(server::Server, listener, ready::Threads.Event)::Server
    _server_shutting_down(server) && throw(ProtocolError("websocket server is shutting down"))
    _mark_ws_server_listening!(server, listener)
    notify(ready)
    while !_server_shutting_down(server)
        conn = try
            if listener isa TLS.Listener
                TLS.accept(listener::TLS.Listener)
            else
                TCP.accept(listener::TCP.Listener)
            end
        catch err
            _server_shutting_down(server) && return server
            err isa EOFError && return server
            rethrow(err)
        end
        Threads.@spawn _serve_ws_conn!(server, conn)
    end
    return server
end

function _listen_ws(server::Server, ready::Threads.Event)
    listener = server.tls_config === nothing ?
               TCP.listen(server.network, server.address; backlog=128) :
               TLS.listen(server.network, server.address, server.tls_config::TLS.Config; backlog=128)
    try
        serve!(server, listener, ready)
    finally
        @try_ignore begin
            if listener isa TLS.Listener
                TLS.close(listener::TLS.Listener)
            else
                TCP.close(listener::TCP.Listener)
            end
        end
    end
    return server
end

"""
    forceclose(server) -> nothing

Immediately stop accepting new WebSocket connections and close active sessions.
"""
function forceclose(server::Server)::Nothing
    @atomic :release server.shutting_down = true
    listener = nothing
    lock(server.lock)
    try
        listener = server.listener
        server.listener = nothing
    finally
        unlock(server.lock)
    end
    if listener !== nothing
        @try_ignore begin
            if listener isa TLS.Listener
                TLS.close(listener::TLS.Listener)
            else
                TCP.close(listener::TCP.Listener)
            end
        end
    end
    sessions = _active_sessions(server)
    for session in sessions
        @try_ignore begin
            close(session::WebSocket, CloseFrameBody(1001, "server shutting down"))
        end
    end
    lock(server.lock)
    try
        for conn in server.active_tcp_conns
            _close_ws_server_conn!(conn)
        end
        for conn in server.active_tls_conns
            _close_ws_server_conn!(conn)
        end
    finally
        unlock(server.lock)
    end
    return nothing
end

function Base.close(server::Server)
    forceclose(server)
    wait(server)
    return nothing
end

function Base.wait(server::Server)
    serve_task = nothing
    lock(server.lock)
    try
        serve_task = server.serve_task
    finally
        unlock(server.lock)
    end
    serve_task === nothing || wait(serve_task::Task)
    for task in _active_ws_tasks(server)
        task === current_task() && continue
        wait(task)
    end
    return nothing
end

"""
    listen!(handler, host="127.0.0.1", port=8080; kwargs...) -> Server

Start a background WebSocket server and return its [`Server`](@ref) handle.

Pass `tls_config` to serve `wss://` traffic, `subprotocols` to advertise
supported subprotocols, and `check_origin` to customize origin validation. Pass
`listenany=true` to ignore `port` and bind to an OS-assigned ephemeral port;
read the actual address afterwards with [`server_addr`](@ref).
"""
function listen!(
    handler::Function,
    host::AbstractString="127.0.0.1",
    port::Integer=8080;
    tls_config::Union{Nothing,TLS.Config}=nothing,
    subprotocols::AbstractVector{<:AbstractString}=String[],
    check_origin::Union{Nothing,Function}=nothing,
    maxframesize::Integer=typemax(Int),
    maxfragmentation::Integer=DEFAULT_MAX_FRAG,
    read_buffer_bytes::Integer=DEFAULT_READ_BUFFER_BYTES,
    listenany::Bool=false,
)::Server
    bind_port = listenany ? 0 : Int(port)
    server = Server(
        network="tcp",
        address=HostResolvers.join_host_port(host, bind_port),
        handler=handler,
        tls_config=tls_config,
        subprotocols=subprotocols,
        check_origin=check_origin,
        maxframesize=maxframesize,
        maxfragmentation=maxfragmentation,
        read_buffer_bytes=read_buffer_bytes,
    )
    ready = Threads.Event(true)
    server.serve_task = Threads.@spawn begin
        try
            _listen_ws(server, ready)
        catch
            notify(ready)
            rethrow()
        end
    end
    wait(ready)
    return server
end

"""`serve!` is an alias for [`listen!`](@ref)."""
serve!(handler::Function, host::AbstractString="127.0.0.1", port::Integer=8080; kwargs...) = listen!(handler, host, port; kwargs...)

"""
    listen(handler, host="127.0.0.1", port=8080; kwargs...) -> Server

Start a WebSocket server and block until it exits.
"""
function listen(handler::Function, host::AbstractString="127.0.0.1", port::Integer=8080; kwargs...)
    server = listen!(handler, host, port; kwargs...)
    wait(server)
    return server
end

end
