# HTTP/3 client connections (RFC 9114) over Reseau's QUIC transport.
#
# A connection opens its control stream with SETTINGS, and a background task
# takes the server's unidirectional streams: its control stream (SETTINGS,
# then GOAWAY), its QPACK streams (drained: with no dynamic table there is
# nothing on them to act on), and unknown types (refused). Each request has a
# bidirectional stream: HEADERS and DATA out, then HEADERS, DATA, and
# optional trailers back, read straight from the stream by whichever task
# reads the body. Protocol errors close the connection with their HTTP/3
# error code (Section 8).

using Reseau: QUIC, UDP

"""
    H3StreamResetError

The server reset an HTTP/3 request stream with error `code`.
`H3_REQUEST_REJECTED` (0x10b) means the request was not processed (RFC 9114
Section 4.1.1), so it is retried when retries are enabled.
"""
struct H3StreamResetError <: HTTPError
    code::UInt64
end

function Base.showerror(io::IO, err::H3StreamResetError)
    print(io, "HTTP/3 stream reset by peer: ", _h3_error_name(err.code))
    return nothing
end

"""
    H3GoAwayError

The server's GOAWAY means it will not process this request (RFC 9114
Section 5.2); it is safe to retry on a new connection.
"""
struct H3GoAwayError <: HTTPError
    stream_id::UInt64
end

function Base.showerror(io::IO, err::H3GoAwayError)
    print(io, "HTTP/3 connection is going away; requests from stream ", err.stream_id, " on are not processed")
    return nothing
end

"""
    H3Connection

An HTTP/3 client connection from [`connect_h3!`](@ref). Send requests with
[`h3_roundtrip!`](@ref) from any task; they share the connection.
"""
mutable struct H3Connection
    quic::QUIC.Connection
    address::String
    lock::ReentrantLock
    cond::Threads.Condition
    control::QUIC.Stream
    # What the server's SETTINGS allow; 0 for no limit.
    peer_settings_received::Bool
    peer_max_field_section_size::Int64
    # The server's critical unidirectional streams, by type, once seen.
    peer_streams::Set{UInt64}
    # The first request stream ID the server's GOAWAY refuses.
    goaway_id::UInt64
    # Why the connection can take no more requests.
    error::Union{Nothing,Exception}
    active_streams::Int
    last_activity_ns::Int64
    max_field_section_size::Int
    # Dropped from the pool while requests were in progress: closes once
    # the last of them ends.
    retiring::Bool
    @atomic closed::Bool
end

"""
    H3Body

The streaming body of an HTTP/3 response: DATA frames read from the request
stream as the caller reads, then trailers.
"""
mutable struct H3Body <: AbstractBody
    conn::H3Connection
    stream::QUIC.Stream
    request::Request
    trailers::Headers
    expected_content_length::Int64
    bytes_read::Int64
    frame_remaining::Int64
    trailers_seen::Bool
    # Once set, every later read throws it, so a failed body never looks
    # like one that ended cleanly.
    error::Union{Nothing,Exception}
    @atomic closed::Bool
    cancel_context::Union{Nothing,RequestContext}
    cancel_callback::Union{Nothing,Function}
end

const _H3_MAX_CONTROL_FRAME = 16 * 1024

# Connection state.

function _h3_set_error!(conn::H3Connection, err::Exception)::Bool
    lock(conn.lock)
    try
        conn.error === nothing || return false
        conn.error = err
        notify(conn.cond; all=true)
        return true
    finally
        unlock(conn.lock)
    end
end

# Close the connection for an HTTP/3 protocol violation.
function _h3_fail!(conn::H3Connection, code::UInt64, message::AbstractString)::Nothing
    _h3_set_error!(conn, ProtocolError(string("HTTP/3 connection error ", _h3_error_name(code), ": ", message)))
    close(conn.quic; code=code, reason=message)
    return nothing
end

_h3_fail!(conn::H3Connection, err::_H3Error) = _h3_fail!(conn, err.code, err.message)

function _h3_quic_closed!(conn::H3Connection, err::QUIC.ConnectionError)::Nothing
    _h3_set_error!(conn, ProtocolError(string("HTTP/3 connection closed: ", sprint(showerror, err)), err))
    return nothing
end

function _h3_conn_available(conn::H3Connection)::Bool
    (@atomic :acquire conn.closed) && return false
    lock(conn.lock)
    try
        return conn.error === nothing && conn.goaway_id == typemax(UInt64)
    finally
        unlock(conn.lock)
    end
end

function _h3_conn_quiet(conn::H3Connection)::Bool
    lock(conn.lock)
    try
        return conn.active_streams == 0
    finally
        unlock(conn.lock)
    end
end

function _h3_conn_idle_expired(conn::H3Connection, idle_timeout_ns::Int64, now_ns::Int64)::Bool
    idle_timeout_ns > 0 || return false
    lock(conn.lock)
    try
        return conn.active_streams == 0 && now_ns - conn.last_activity_ns >= idle_timeout_ns
    finally
        unlock(conn.lock)
    end
end

function _h3_note_goaway!(conn::H3Connection, id::UInt64)::Nothing
    lock(conn.lock)
    try
        # A GOAWAY may only lower the limit (Section 5.2).
        id > conn.goaway_id && throw(_H3Error(_H3_ID_ERROR, "GOAWAY raised the stream limit"))
        conn.goaway_id = id
        notify(conn.cond; all=true)
    finally
        unlock(conn.lock)
    end
    return nothing
end

function _h3_unregister!(conn::H3Connection)::Nothing
    lock(conn.lock)
    retire = false
    try
        conn.active_streams -= 1
        conn.last_activity_ns = Int64(time_ns())
        retire = conn.retiring && conn.active_streams == 0
        notify(conn.cond; all=true)
    finally
        unlock(conn.lock)
    end
    retire && @try_ignore close(conn)
    return nothing
end

# Drop `conn` from use: close it now if it is quiet, else once its last
# request ends.
function _h3_retire!(conn::H3Connection)::Nothing
    lock(conn.lock)
    quiet = try
        conn.retiring = true
        conn.active_streams == 0
    finally
        unlock(conn.lock)
    end
    quiet && @try_ignore close(conn)
    return nothing
end

# The server's unidirectional streams.

function _h3_apply_settings!(conn::H3Connection, settings::Vector{Pair{UInt64,UInt64}})::Nothing
    lock(conn.lock)
    try
        for (id, value) in settings
            if id == _H3_SETTING_MAX_FIELD_SECTION_SIZE
                conn.peer_max_field_section_size = value > typemax(Int64) ? Int64(0) : Int64(value)
            end
        end
        conn.peer_settings_received = true
        notify(conn.cond; all=true)
    finally
        unlock(conn.lock)
    end
    return nothing
end

function _h3_read_control!(conn::H3Connection, s::QUIC.Stream)::Nothing
    first = true
    while true
        header = _h3_read_frame_header(s)
        header === nothing && throw(_H3Error(_H3_CLOSED_CRITICAL_STREAM, "the server closed its control stream"))
        type, len = header
        if first
            type == _H3_FRAME_SETTINGS || throw(_H3Error(_H3_MISSING_SETTINGS, "the control stream did not start with SETTINGS"))
            first = false
            _h3_apply_settings!(conn, _h3_decode_settings(_h3_read_payload(s, len, _H3_MAX_CONTROL_FRAME)))
        elseif type == _H3_FRAME_GOAWAY
            id = _h3_decode_goaway(_h3_read_payload(s, len, _H3_MAX_CONTROL_FRAME))
            # A server's GOAWAY names a client-initiated bidirectional stream.
            id % 4 == 0 || throw(_H3Error(_H3_ID_ERROR, "GOAWAY names stream $(id), which is not a request stream"))
            _h3_note_goaway!(conn, id)
        elseif type == _H3_FRAME_SETTINGS || type == _H3_FRAME_MAX_PUSH_ID || type == _H3_FRAME_DATA ||
               type == _H3_FRAME_HEADERS || type == _H3_FRAME_PUSH_PROMISE || _h3_is_http2_frame_type(type)
            throw(_H3Error(_H3_FRAME_UNEXPECTED, "frame type 0x$(string(type; base=16)) on the control stream"))
        else
            # CANCEL_PUSH (no push was allowed) and unknown types.
            _h3_skip!(s, len)
        end
    end
end

function _h3_claim_peer_stream!(conn::H3Connection, type::UInt64)::Nothing
    lock(conn.lock)
    try
        type in conn.peer_streams && throw(_H3Error(_H3_STREAM_CREATION_ERROR, "a second stream of type 0x$(string(type; base=16))"))
        push!(conn.peer_streams, type)
    finally
        unlock(conn.lock)
    end
    return nothing
end

function _h3_serve_uni_stream!(conn::H3Connection, s::QUIC.Stream)::Nothing
    try
        type = _h3_read_varint(s)
        type === nothing && return nothing
        if type == _H3_STREAM_CONTROL
            _h3_claim_peer_stream!(conn, type)
            _h3_read_control!(conn, s)
        elseif type == _H3_STREAM_QPACK_ENCODER || type == _H3_STREAM_QPACK_DECODER
            _h3_claim_peer_stream!(conn, type)
            # With a dynamic table capacity of 0 the encoder can send nothing
            # that refers to a table, and this decoder sends nothing for the
            # peer to acknowledge, so the contents are dropped.
            while !isempty(readavailable(s))
            end
            throw(_H3Error(_H3_CLOSED_CRITICAL_STREAM, "the server closed a QPACK stream"))
        elseif type == _H3_STREAM_PUSH
            throw(_H3Error(_H3_ID_ERROR, "server push was not allowed"))
        else
            QUIC.stop_sending!(s, _H3_STREAM_CREATION_ERROR)
        end
    catch err
        if err isa _H3Error
            _h3_fail!(conn, err::_H3Error)
        elseif err isa QUIC.StreamResetError
            _h3_fail!(conn, _H3_CLOSED_CRITICAL_STREAM, "the server reset a critical stream")
        elseif err isa QUIC.ConnectionError
            _h3_quic_closed!(conn, err::QUIC.ConnectionError)
        else
            # Nothing waits on this task, so an unexpected error ends the
            # connection rather than going unseen.
            _h3_fail!(conn, _H3_INTERNAL_ERROR, "unexpected error on a server stream")
        end
    end
    return nothing
end

function _h3_accept_loop!(conn::H3Connection)::Nothing
    try
        while true
            s = QUIC.accept_stream(conn.quic)
            if QUIC.isbidi(s)
                _h3_fail!(conn, _H3_STREAM_CREATION_ERROR, "the server opened a bidirectional stream")
                return nothing
            end
            Threads.@spawn _h3_serve_uni_stream!(conn, s)
        end
    catch err
        if err isa QUIC.ConnectionError
            _h3_quic_closed!(conn, err::QUIC.ConnectionError)
        else
            _h3_fail!(conn, _H3_INTERNAL_ERROR, "unexpected error accepting server streams")
        end
    end
    return nothing
end

# Connecting.

function _make_tls_config_for_h3(
    config::Union{Nothing,TLS.Config},
    address::String,
    server_name::Union{Nothing,String}=nothing,
)::TLS.Config
    host, _ = HostResolvers.split_host_port(address)
    if config === nothing
        return TLS.Config(
            server_name === nothing ? host : server_name,
            true,
            true,
            TLS.ClientAuthMode.NoClientCert,
            nothing,
            nothing,
            nothing,
            nothing,
            ["h3"],
            UInt16[],
            Int64(0),
            TLS.TLS1_3_VERSION,
            nothing,
            false,
            64,
        )
    end
    # QUIC must negotiate "h3"; an ALPN list meant for TCP does not apply.
    effective_server_name = if server_name === nothing
        config.server_name === nothing ? host : config.server_name::String
    else
        server_name
    end
    return _copy_tls_config_for_request(config, effective_server_name, ["h3"], copy(config.curve_preferences), config.handshake_timeout_ns)
end

"""
    connect_h3!(address; host_resolver=HostResolvers.HostResolver(), tls_config=nothing,
                server_name=nothing, connect_deadline_ns=0) -> H3Connection

Open an HTTP/3 connection to `address` (`"host:port"`) over QUIC. The TLS
settings come from `tls_config`, with ALPN `h3`. Throws
[`ConnectError`](@ref) when the QUIC handshake fails or `connect_deadline_ns`
passes first.
"""
function connect_h3!(
    address::AbstractString;
    host_resolver::HostResolvers.HostResolver=HostResolvers.HostResolver(),
    tls_config::Union{Nothing,TLS.Config}=nothing,
    server_name::Union{Nothing,AbstractString}=nothing,
    connect_deadline_ns::Int64=Int64(0),
)::H3Connection
    return _connect_h3!(String(address), String(address), host_resolver, tls_config,
        server_name === nothing ? nothing : String(server_name), connect_deadline_ns)
end

# Connects to `connect_address`, an Alt-Svc alternative or the origin
# itself, for the origin `address`: requests name the origin as their
# `:authority`, and its host (or `server_name`) is the TLS server name.
function _connect_h3!(
    address::String,
    connect_address::String,
    host_resolver::HostResolvers.HostResolver,
    tls_config::Union{Nothing,TLS.Config},
    server_name::Union{Nothing,String},
    connect_deadline_ns::Int64,
)::H3Connection
    config = _make_tls_config_for_h3(tls_config, address, server_name)
    deadline_ns = _min_nonzero_ns(connect_deadline_ns, HostResolvers._connect_deadline_ns(host_resolver))
    quic = try
        addrs = HostResolvers.resolve_tcp_addrs(host_resolver.resolver, "udp", connect_address; policy=host_resolver.policy)
        QUIC.connect(first(addrs), config; deadline_ns=deadline_ns, local_addr=host_resolver.local_addr)
    catch err
        err isa Exception || rethrow()
        throw(ConnectError(connect_address, err::Exception))
    end
    ok = false
    try
        alpn = QUIC.alpn_protocol(quic)
        alpn == "h3" || throw(ConnectError(connect_address, ProtocolError("HTTP/3 server negotiated ALPN $(repr(alpn))")))
        control = QUIC.open_stream(quic; bidi=false)
        lk = ReentrantLock()
        conn = H3Connection(
            quic, address, lk, Threads.Condition(lk), control, false, Int64(0), Set{UInt64}(),
            typemax(UInt64), nothing, 0, Int64(time_ns()), _H2_DEFAULT_MAX_HEADER_LIST_SIZE, false, false,
        )
        out = UInt8[]
        _h3_append_varint!(out, _H3_STREAM_CONTROL)
        # A dynamic table capacity and blocked streams of 0 are the defaults.
        settings = Pair{UInt64,UInt64}[_H3_SETTING_MAX_FIELD_SECTION_SIZE => UInt64(conn.max_field_section_size)]
        _h3_append_frame!(out, _H3_FRAME_SETTINGS, _h3_encode_settings(settings))
        write(control, out)
        Threads.@spawn _h3_accept_loop!(conn)
        ok = true
        return conn
    finally
        ok || close(quic; code=_H3_INTERNAL_ERROR)
    end
end

"""
    close(conn::H3Connection)

Close the connection with H3_NO_ERROR. Requests in progress fail.
"""
function Base.close(conn::H3Connection)
    @atomic :release conn.closed = true
    _h3_set_error!(conn, ProtocolError("HTTP/3 connection closed"))
    close(conn.quic; code=_H3_NO_ERROR)
    return nothing
end

Base.isopen(conn::H3Connection)::Bool = !(@atomic :acquire conn.closed) && isopen(conn.quic)

# Requests.

# Frame types a request stream must not carry (Sections 7.2.4 to 7.2.7, 7.2.8).
function _h3_check_request_frame(type::UInt64)::Nothing
    if type == _H3_FRAME_SETTINGS || type == _H3_FRAME_GOAWAY || type == _H3_FRAME_MAX_PUSH_ID ||
       type == _H3_FRAME_CANCEL_PUSH || _h3_is_http2_frame_type(type)
        throw(_H3Error(_H3_FRAME_UNEXPECTED, "frame type 0x$(string(type; base=16)) on a request stream"))
    end
    type == _H3_FRAME_PUSH_PROMISE && throw(_H3Error(_H3_ID_ERROR, "server push was not allowed"))
    return nothing
end

# Reads and decodes a HEADERS frame's field section. One too large for this
# client's limit fails only its stream (a static-only decoder keeps no state
# to lose); one that cannot be decoded is QPACK_DECOMPRESSION_FAILED, a
# connection error (RFC 9204 Section 2.2).
function _h3_decode_fields(conn::H3Connection, s::QUIC.Stream, len::Int64)::Vector{HeaderField}
    limit = conn.max_field_section_size
    len > limit && throw(_H3StreamError(_H3_FRAME_ERROR, "HTTP/3 HEADERS frame too large: $(len) bytes (max: $(limit))"))
    payload = _h3_read_payload(s, len, limit)
    fields = try
        _qpack_decode(payload)
    catch err
        err isa ProtocolError || rethrow()
        throw(_H3Error(_QPACK_DECOMPRESSION_FAILED, (err::ProtocolError).message))
    end
    _header_list_size(fields) > limit && throw(_H3StreamError(_H3_MESSAGE_ERROR, "HTTP/3 field section exceeds $(limit) bytes"))
    return fields
end

# A malformed message fails its stream with H3_MESSAGE_ERROR (RFC 9114
# Section 4.1.2).
function _h3_message_error(@nospecialize(err::Exception))::Exception
    err isa ProtocolError || return err
    return _H3StreamError(_H3_MESSAGE_ERROR, (err::ProtocolError).message)
end

function _h3_decode_response_head(fields::Vector{HeaderField})::Tuple{Int,Headers}
    try
        return _decode_response_headers(fields)
    catch err
        err isa Exception || rethrow()
        throw(_h3_message_error(err::Exception))
    end
end

function _h3_decode_trailers(fields::Vector{HeaderField})::Headers
    try
        return _decode_h2_trailer_headers(fields)
    catch err
        err isa Exception || rethrow()
        throw(_h3_message_error(err::Exception))
    end
end

# Abandon both directions of a request stream.
function _h3_cancel_stream!(s::QUIC.Stream, code::UInt64)::Nothing
    QUIC.stop_sending!(s, code)
    QUIC.reset_stream!(s, code)
    return nothing
end

# The exception a request sees for a failure on its stream.
function _h3_request_error(conn::H3Connection, ctx::RequestContext, @nospecialize(err::Exception))::Exception
    if err isa _H3StreamError
        e = err::_H3StreamError
        return ProtocolError(e.message, e.kind)
    elseif err isa _H3Error
        _h3_fail!(conn, err::_H3Error)
        return ProtocolError(sprint(showerror, err), err::_H3Error)
    elseif err isa QUIC.StreamResetError
        e = err::QUIC.StreamResetError
        e.remote || return canceled(ctx) ? _canceled_error(ctx) : ProtocolError("HTTP/3 request stream was reset")
        return H3StreamResetError(e.code)
    elseif err isa QUIC.StreamStoppedError
        e = err::QUIC.StreamStoppedError
        canceled(ctx) && return _canceled_error(ctx)
        return e.remote ? H3StreamResetError(e.code) : ProtocolError("HTTP/3 request stream was stopped")
    elseif err isa QUIC.ConnectionError
        _h3_quic_closed!(conn, err::QUIC.ConnectionError)
        return ProtocolError(string("HTTP/3 connection closed: ", sprint(showerror, err)), err::QUIC.ConnectionError)
    end
    return err
end

function _h3_open_request_stream!(conn::H3Connection, request::Request)::QUIC.Stream
    lock(conn.lock)
    try
        err = conn.error
        err === nothing || throw(err)
        conn.goaway_id == typemax(UInt64) || throw(H3GoAwayError(conn.goaway_id))
        conn.active_streams += 1
    finally
        unlock(conn.lock)
    end
    s = try
        QUIC.open_stream(conn.quic; deadline_ns=_request_write_deadline_ns(request))
    catch err
        _h3_unregister!(conn)
        rethrow()
    end
    lock(conn.lock)
    try
        if QUIC.stream_id(s) >= conn.goaway_id
            conn.active_streams -= 1
            QUIC.reset_stream!(s, _H3_REQUEST_CANCELLED)
            throw(H3GoAwayError(conn.goaway_id))
        end
    finally
        unlock(conn.lock)
    end
    return s
end

function _h3_write_data!(s::QUIC.Stream, data::AbstractVector{UInt8})::Nothing
    isempty(data) && return nothing
    header = UInt8[]
    _h3_append_varint!(header, _H3_FRAME_DATA)
    _h3_append_varint!(header, UInt64(length(data)))
    write(s, header)
    if data isa Union{Vector{UInt8},SubArray{UInt8,1}}
        write(s, data)
    else
        write(s, Vector{UInt8}(data))
    end
    return nothing
end

function _write_request_body_h3!(s::QUIC.Stream, request::Request)::Nothing
    body = request.body
    try
        if body isa BytesBody
            b = body::BytesBody
            if !body_closed(b)
                _h3_write_data!(s, view(b.data, b.next_index:length(b.data)))
                b.next_index = length(b.data) + 1
            end
        elseif !(body isa EmptyBody)
            # A streaming body is held to the Content-Length the request
            # declared: no more is sent, and a body of another length fails
            # the request, as in quic-go.
            limit = request.content_length
            sent = Int64(0)
            buf = Vector{UInt8}(undef, 64 * 1024)
            while (n = body_read!(body, buf)) > 0
                if limit >= 0 && sent + n > limit
                    _h3_write_data!(s, view(buf, 1:Int(limit - sent)))
                    throw(_H3StreamError(_H3_REQUEST_CANCELLED, "HTTP/3 request body is longer than its Content-Length of $(limit) bytes"))
                end
                _h3_write_data!(s, view(buf, 1:n))
                sent += n
            end
            limit >= 0 && sent < limit &&
                throw(_H3StreamError(_H3_REQUEST_CANCELLED, "HTTP/3 request body ended after $(sent) of its $(limit) Content-Length bytes"))
        end
    finally
        @try_ignore body_close!(body)
    end
    closewrite(s)
    return nothing
end

function _h3_read_response_head!(conn::H3Connection, s::QUIC.Stream)::Vector{HeaderField}
    while true
        header = _h3_read_frame_header(s)
        header === nothing && throw(ProtocolError("HTTP/3 response ended before its headers"))
        type, len = header
        if type == _H3_FRAME_HEADERS
            fields = _h3_decode_fields(conn, s, len)
            status = _h2_header_block_status(fields)
            if status !== nothing && 100 <= status < 200
                status == 101 && throw(_H3StreamError(_H3_MESSAGE_ERROR, "HTTP/3 does not support 101 Switching Protocols"))
                _h3_decode_response_head(fields)
                continue
            end
            return fields
        elseif type == _H3_FRAME_DATA
            throw(_H3Error(_H3_FRAME_UNEXPECTED, "DATA before the response headers"))
        end
        _h3_check_request_frame(type)
        _h3_skip!(s, len)
    end
end

function _h3_roundtrip_incoming!(conn::H3Connection, request::Request)::_IncomingResponse
    ctx = get_request_context(request)
    canceled(ctx) && throw(_canceled_error(ctx))
    fields = _request_headers_for_h2(conn.address, request, true)
    lock(conn.lock)
    peer_limit = try
        conn.peer_max_field_section_size
    finally
        unlock(conn.lock)
    end
    if peer_limit > 0 && _header_list_size(fields) > peer_limit
        throw(ProtocolError("HTTP/3 request headers exceed the server's SETTINGS_MAX_FIELD_SECTION_SIZE"))
    end
    s = try
        _h3_open_request_stream!(conn, request)
    catch err
        err isa Exception || rethrow()
        throw(_h3_request_error(conn, ctx, err::Exception))
    end
    cancel_cb = let s = s
        () -> _h3_cancel_stream!(s, _H3_REQUEST_CANCELLED)
    end
    _on_cancel!(ctx, cancel_cb)
    cleanup = true
    cancel_code = _H3_REQUEST_CANCELLED
    try
        canceled(ctx) && throw(_canceled_error(ctx))
        QUIC.set_write_deadline!(s, _request_write_deadline_ns(request))
        head = UInt8[]
        _h3_append_frame!(head, _H3_FRAME_HEADERS, _qpack_encode(fields))
        try
            write(s, head)
            _write_request_body_h3!(s, request)
        catch err
            # A server may answer before reading the whole body and stop it
            # with H3_NO_ERROR (Section 4.1); the response follows.
            (err isa QUIC.StreamStoppedError && (err::QUIC.StreamStoppedError).remote &&
                (err::QUIC.StreamStoppedError).code == _H3_NO_ERROR) || rethrow()
            @try_ignore body_close!(request.body)
        end
        QUIC.set_read_deadline!(s, _request_response_header_deadline_ns(request))
        response_fields = _h3_read_response_head!(conn, s)
        status, response_headers = _h3_decode_response_head(response_fields)
        content_length = _parse_content_length(response_headers)
        trailers = Headers()
        lock(conn.lock)
        try
            conn.last_activity_ns = Int64(time_ns())
        finally
            unlock(conn.lock)
        end
        if request.method == "HEAD" || !_body_allowed_for_status(status)
            # Nothing more is read; whatever the server still sends is dropped.
            QUIC.stop_sending!(s, _H3_NO_ERROR)
            _remove_cancel_callback!(ctx, cancel_cb)
            cleanup = false
            _h3_unregister!(conn)
            return _IncomingResponse(
                _IncomingResponseHead(status, "", response_headers, trailers, max(content_length, Int64(0)),
                    UInt8(3), UInt8(0), false, request, nothing, nothing, 0),
                EmptyBody(),
            )
        end
        body = H3Body(conn, s, request, trailers, content_length, Int64(0), Int64(0), false, nothing, false, ctx, cancel_cb)
        cleanup = false
        return _IncomingResponse(
            _IncomingResponseHead(status, "", response_headers, trailers, content_length,
                UInt8(3), UInt8(0), false, request, nothing, nothing, 0),
            body,
        )
    catch err
        err isa Exception || rethrow()
        err isa _H3StreamError && (cancel_code = (err::_H3StreamError).code)
        throw(_h3_request_error(conn, ctx, err::Exception))
    finally
        if cleanup
            _remove_cancel_callback!(ctx, cancel_cb)
            @try_ignore _h3_cancel_stream!(s, cancel_code)
            _h3_unregister!(conn)
        end
    end
end

"""
    h3_roundtrip!(conn, request) -> Response

Send `request` over an `H3Connection` and return the streaming `Response`.
"""
function h3_roundtrip!(conn::H3Connection, request::Request)::Response
    return _streaming_response(_h3_roundtrip_incoming!(conn, request))
end

# Response bodies.

body_closed(body::H3Body)::Bool = @atomic :acquire body.closed

function _h3_finish_body!(body::H3Body)::Nothing
    @atomic :release body.closed = true
    ctx = body.cancel_context
    cb = body.cancel_callback
    body.cancel_context = nothing
    body.cancel_callback = nothing
    ctx === nothing || cb === nothing || _remove_cancel_callback!(ctx::RequestContext, cb::Function)
    _h3_unregister!(body.conn)
    return nothing
end

function _h3_body_failed!(body::H3Body, code::UInt64)::Nothing
    @try_ignore _h3_cancel_stream!(body.stream, code)
    _h3_finish_body!(body)
    return nothing
end

function body_read!(body::H3Body, dst::AbstractVector{UInt8})::Int
    failure = body.error
    failure === nothing || throw(failure)
    isempty(dst) && return 0
    body_closed(body) && return 0
    s = body.stream
    ctx = get_request_context(body.request)
    try
        QUIC.set_read_deadline!(s, _request_read_deadline_ns(body.request))
        while true
            if body.frame_remaining > 0
                # Up to the Content-Length; a byte past it is an error, raised
                # once the bytes before it have been returned.
                expected = body.expected_content_length
                expected >= 0 && body.bytes_read >= expected &&
                    throw(_H3StreamError(_H3_MESSAGE_ERROR, "HTTP/3 response body exceeded Content-Length", _PROTOCOL_ERROR_RESPONSE_LENGTH))
                want = min(Int64(length(dst)), body.frame_remaining)
                expected >= 0 && (want = min(want, expected - body.bytes_read))
                n = readbytes!(s, dst, Int(want); all=false)
                n == 0 && throw(_H3Error(_H3_FRAME_ERROR, "stream ended inside a DATA frame"))
                body.frame_remaining -= n
                body.bytes_read += n
                return n
            end
            header = _h3_read_frame_header(s)
            if header === nothing
                expected = body.expected_content_length
                expected >= 0 && body.bytes_read != expected &&
                    throw(_H3StreamError(_H3_MESSAGE_ERROR, "HTTP/3 response body ended before Content-Length bytes were received", _PROTOCOL_ERROR_RESPONSE_LENGTH))
                _h3_finish_body!(body)
                return 0
            end
            type, len = header
            if type == _H3_FRAME_DATA
                body.trailers_seen && throw(_H3Error(_H3_FRAME_UNEXPECTED, "DATA after the trailers"))
                body.frame_remaining = len
            elseif type == _H3_FRAME_HEADERS
                body.trailers_seen && throw(_H3Error(_H3_FRAME_UNEXPECTED, "HEADERS after the trailers"))
                body.trailers_seen = true
                append!(body.trailers, _h3_decode_trailers(_h3_decode_fields(body.conn, s, len)))
            else
                _h3_check_request_frame(type)
                _h3_skip!(s, len)
            end
        end
    catch err
        err isa Exception || rethrow()
        code = err isa _H3StreamError ? (err::_H3StreamError).code : _H3_REQUEST_CANCELLED
        mapped = _h3_request_error(body.conn, ctx, err::Exception)
        body.error = mapped
        body_closed(body) || _h3_body_failed!(body, code)
        throw(mapped)
    end
end

function body_close!(body::H3Body)
    body_closed(body) && return nothing
    _h3_body_failed!(body, _H3_REQUEST_CANCELLED)
    return nothing
end

# Requests the server did not process (RFC 9114 Sections 4.1.1 and 5.2), so
# safe to retry whatever their method.
function _h3_guaranteed_unprocessed(err)::Bool
    current = err
    current isa RequestRetryError && (current = (current::RequestRetryError).err)
    current isa H3StreamResetError && return (current::H3StreamResetError).code == _H3_REQUEST_REJECTED
    return current isa H3GoAwayError
end
