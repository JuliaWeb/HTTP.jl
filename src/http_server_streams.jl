function _server_stream_allows_body(stream::Stream)::Bool
    _require_server_stream(stream)
    _body_allowed_for_status(stream.response.status) || return false
    stream.message.method == "HEAD" && return false
    return true
end

function _server_stream_write_mode(stream::Stream)::_ServerStreamWriteMode.T
    # Framing is chosen late so explicit response headers win, while unread
    # request bodies still force connection close independently of write mode.
    allows_body = _server_stream_allows_body(stream)
    allows_body || return _ServerStreamWriteMode.NONE
    if _server_stream_live_h2(stream)
        return (hasheader(stream.response.headers, "Content-Length") || stream.response.content_length >= 0) ?
               _ServerStreamWriteMode.FIXED :
               _ServerStreamWriteMode.IDENTITY
    end
    headercontains(stream.response.headers, "Transfer-Encoding", "chunked") && return _ServerStreamWriteMode.CHUNKED
    if hasheader(stream.response.headers, "Content-Length") || stream.response.content_length >= 0
        return _ServerStreamWriteMode.FIXED
    end
    if stream.response.proto_major == UInt8(1) && stream.response.proto_minor == UInt8(0)
        stream.response.close = true
        return _ServerStreamWriteMode.IDENTITY
    end
    return _ServerStreamWriteMode.CHUNKED
end

function _write_server_stream_bytes!(stream::Stream, bytes::AbstractVector{UInt8}, buffer::Bool=true)::Nothing
    isempty(bytes) && return nothing
    data = bytes isa Vector{UInt8} ? bytes : Vector{UInt8}(bytes)
    if buffer && (_server_stream_buffered_h2(stream) || _server_stream_buffered_fixed_h1(stream))
        write(stream.request_buffer, data)
        return nothing
    end
    if _server_stream_live_h2(stream)
        deadline_ns = _server_write_deadline_ns(stream.server::Server)
        _write_data_frames_h2_server!(
            stream.h2_conn::Union{TCP.Conn,TLS.Conn},
            stream.h2_write_lock::ReentrantLock,
            stream.h2_send_state::_H2SendWindowState,
            stream.h2_stream_id,
            data;
            end_stream=false,
            write_deadline_ns=deadline_ns,
        )
        return nothing
    end
    _set_write_deadline!(stream.server, stream.tracked.conn)
    total = 0
    while total < length(data)
        chunk = total == 0 ? data : data[(total+1):end]
        n = write(stream.tracked.conn, chunk)
        n > 0 || throw(ProtocolError("server stream write made no progress"))
        total += n
    end
    return nothing
end

function _write_server_stream_head!(stream::Stream)::Nothing
    headers = copy(stream.response.headers)
    response_close = stream.response.close || _should_close_connection(headers, stream.response.proto_major, stream.response.proto_minor)
    response_close && setheader(headers, "Connection", "close")
    mode = _server_stream_write_mode(stream)
    stream.write_mode = mode
    if _server_stream_live_h2(stream)
        if mode == _ServerStreamWriteMode.NONE
            removeheader(headers, "Content-Length")
        elseif stream.response.content_length >= 0
            setheader(headers, "Content-Length", string(stream.response.content_length))
        end
        removeheader(headers, "Connection")
        removeheader(headers, "Transfer-Encoding")
        removeheader(headers, "Keep-Alive")
        removeheader(headers, "Proxy-Connection")
        removeheader(headers, "Upgrade")
        removeheader(headers, "Trailer")
        end_stream = mode == _ServerStreamWriteMode.NONE && isempty(stream.response.trailers)
        _write_h2_response_headers!(
            stream.h2_conn::Union{TCP.Conn,TLS.Conn},
            stream.h2_write_lock::ReentrantLock,
            stream.h2_send_state::_H2SendWindowState,
            stream.h2_stream_id,
            stream.response.status,
            headers,
            end_stream,
            _server_write_deadline_ns(stream.server::Server),
        )
        @atomic :release stream.response_started = true
        return nothing
    end
    if mode == _ServerStreamWriteMode.NONE
        removeheader(headers, "Content-Length")
        removeheader(headers, "Transfer-Encoding")
    elseif mode == _ServerStreamWriteMode.FIXED
        if stream.response.content_length >= 0
            setheader(headers, "Content-Length", string(stream.response.content_length))
        end
    elseif mode == _ServerStreamWriteMode.CHUNKED
        removeheader(headers, "Content-Length")
        setheader(headers, "Transfer-Encoding", "chunked")
        _prepare_trailer_header!(headers, stream.response.trailers)
    else
        removeheader(headers, "Content-Length")
        removeheader(headers, "Transfer-Encoding")
    end
    io = IOBuffer()
    _write_status_line!(io, stream.response)
    _write_headers!(io, headers)
    write(io, "\r\n")
    _write_server_stream_bytes!(stream, take!(io), false)
    @atomic :release stream.response_started = true
    return nothing
end

function _server_startread(stream::Stream)::Request
    _require_server_stream(stream)
    return stream.message
end

function _maybe_write_continue!(stream::Stream)::Nothing
    _require_server_stream(stream)
    stream.message.proto_major == UInt8(2) && return nothing
    already_sent = @atomic :acquire stream.continue_sent
    already_sent && return nothing
    # We only acknowledge `Expect: 100-continue` once the handler actually tries
    # to consume the request body.
    headercontains(stream.message.headers, "Expect", "100-continue") || return nothing
    _stream_request_body_fully_consumed(stream) && return nothing
    response = Response(
        100;
        proto_major=Int(stream.message.proto_major),
        proto_minor=Int(stream.message.proto_minor),
        content_length=0,
        request=stream.message,
    )
    _write_all_response!(stream.tracked.conn, response)
    @atomic :release stream.continue_sent = true
    return nothing
end

function _server_isopen(stream::Stream)::Bool
    _require_server_stream(stream)
    return !(@atomic :acquire stream.read_closed) || !(@atomic :acquire stream.write_closed)
end

function _server_eof(stream::Stream)::Bool
    _require_server_stream(stream)
    return _stream_request_body_fully_consumed(stream)
end

function _server_readbytes!(stream::Stream, dest::AbstractVector{UInt8}, nb::Integer=length(dest))
    _require_server_stream(stream)
    nb >= 0 || throw(ArgumentError("nb must be >= 0"))
    nb == 0 && return 0
    nb <= length(dest) || throw(ArgumentError("nb must be <= length(dest)"))
    _maybe_write_continue!(stream)
    buf = Vector{UInt8}(undef, nb)
    n = _stream_request_body_read!(stream, buf)
    n == 0 && (@atomic :release stream.read_closed = true)
    n > 0 && copyto!(dest, 1, buf, 1, n)
    _stream_request_body_fully_consumed(stream) && (@atomic :release stream.read_closed = true)
    return n
end

function _server_read(stream::Stream)::Vector{UInt8}
    _require_server_stream(stream)
    _maybe_write_continue!(stream)
    out = UInt8[]
    buf = Vector{UInt8}(undef, 16 * 1024)
    while true
        n = _stream_request_body_read!(stream, buf)
        n == 0 && break
        append!(out, @view(buf[1:n]))
    end
    @atomic :release stream.read_closed = true
    return out
end

"""
    setstatus(stream, status) -> nothing

Set the response status for a server-side `Stream` before response writing
starts.
"""
function setstatus(stream::Stream, status::Integer)::Nothing
    _require_server_stream(stream)
    (@atomic :acquire stream.response_started) && throw(ArgumentError("cannot change status after response writing has started"))
    stream.response.status = Int(status)
    return nothing
end

"""
    setheader(stream, key, value) -> nothing
    setheader(stream, key => value) -> nothing

Set a response header for a server-side `Stream` before response writing
starts.
"""
function setheader(stream::Stream, key::AbstractString, value::AbstractString)::Nothing
    _require_server_stream(stream)
    (@atomic :acquire stream.response_started) && throw(ArgumentError("cannot change headers after response writing has started"))
    setheader(stream.response.headers, key, value)
    return nothing
end

function setheader(stream::Stream, header::Pair{<:AbstractString,<:AbstractString})::Nothing
    return setheader(stream, header.first, header.second)
end

"""
    addtrailer(stream, header_or_headers) -> nothing

Append response trailers for a server-side `Stream`. Trailers are emitted when
the response body is closed, so call this before `closewrite(stream)`.
"""
function addtrailer(stream::Stream, trailers::Headers)::Nothing
    _require_server_stream(stream)
    for key in header_keys(trailers)
        values = headers(trailers, key)
        for value in values
            appendheader(stream.response.trailers, key, value)
        end
    end
    return nothing
end

function addtrailer(stream::Stream, header::Pair{<:AbstractString,<:AbstractString})::Nothing
    _require_server_stream(stream)
    appendheader(stream.response.trailers, header.first, header.second)
    return nothing
end

function addtrailer(stream::Stream, headers::AbstractVector{<:Pair})::Nothing
    for header in headers
        addtrailer(stream, header)
    end
    return nothing
end

"""
    startwrite(stream) -> Response

Start the response side of a server-side `Stream` and return the response
metadata. Calling `write(stream, data)` starts writing automatically; use
`startwrite` explicitly when you need headers to be sent before body bytes.
"""
function startwrite(stream::Stream)::Response
    _require_server_stream(stream)
    started = @atomic :acquire stream.response_started
    started && return stream.response
    !_stream_request_body_fully_consumed(stream) && (stream.response.close = true)
    !_server_stream_allows_body(stream) && (stream.ignore_writes = true)
    if _server_stream_buffered_h2(stream)
        @atomic :release stream.response_started = true
        return stream.response
    end
    if _server_stream_live_h2(stream)
        stream.write_mode = _server_stream_write_mode(stream)
        if stream.write_mode == _ServerStreamWriteMode.FIXED && stream.response.content_length < 0
            expected = _parse_content_length(stream.response.headers)
            expected >= 0 || throw(ProtocolError("fixed-length stream response is missing Content-Length"))
            stream.response.content_length = expected
        end
        _write_server_stream_head!(stream)
        return stream.response
    end
    stream.write_mode = _server_stream_write_mode(stream)
    if stream.write_mode == _ServerStreamWriteMode.FIXED
        if stream.response.content_length < 0
            expected = _parse_content_length(stream.response.headers)
            expected >= 0 || throw(ProtocolError("fixed-length stream response is missing Content-Length"))
            stream.response.content_length = expected
        end
        @atomic :release stream.response_started = true
        return stream.response
    end
    _write_server_stream_head!(stream)
    return stream.response
end

function _server_write(stream::Stream, data::AbstractVector{UInt8})::Int
    _require_server_stream(stream)
    (@atomic :acquire stream.write_closed) && throw(ArgumentError("response writes are closed"))
    startwrite(stream)
    stream.ignore_writes && return length(data)
    if _server_stream_buffered_h2(stream) || _server_stream_live_h2(stream) || stream.write_mode == _ServerStreamWriteMode.FIXED
        if stream.response.content_length >= 0 && (stream.written_bytes + length(data)) > stream.response.content_length
            throw(ProtocolError("response body bytes exceeded Content-Length"))
        end
        _write_server_stream_bytes!(stream, data)
        stream.written_bytes += length(data)
        return length(data)
    end
    if stream.write_mode == _ServerStreamWriteMode.CHUNKED
        io = IOBuffer()
        print(io, string(length(data), base=16), "\r\n")
        write(io, data)
        write(io, "\r\n")
        _write_server_stream_bytes!(stream, take!(io))
    else
        _write_server_stream_bytes!(stream, data)
    end
    stream.written_bytes += length(data)
    return length(data)
end

function _server_write(stream::Stream, data::AbstractString)::Int
    return _server_write(stream, Vector{UInt8}(codeunits(String(data))))
end

function _server_closewrite(stream::Stream)::Nothing
    _require_server_stream(stream)
    was_closed = @atomic :acquire stream.write_closed
    was_closed && return nothing
    startwrite(stream)
    if _server_stream_buffered_h2(stream)
        if stream.response.content_length >= 0 && stream.written_bytes != stream.response.content_length
            throw(ProtocolError("response body bytes did not match Content-Length"))
        end
        @atomic :release stream.write_closed = true
        return nothing
    end
    if _server_stream_live_h2(stream)
        if stream.response.content_length >= 0 && stream.written_bytes != stream.response.content_length
            throw(ProtocolError("response body bytes did not match Content-Length"))
        end
        if !isempty(stream.response.trailers)
            _write_h2_trailers!(
                stream.h2_conn::Union{TCP.Conn,TLS.Conn},
                stream.h2_write_lock::ReentrantLock,
                stream.h2_send_state::_H2SendWindowState,
                stream.h2_stream_id,
                stream.response.trailers,
                _server_write_deadline_ns(stream.server::Server),
            )
        elseif !stream.ignore_writes && stream.write_mode != _ServerStreamWriteMode.NONE
            _write_frame_h2_server_threadsafe!(
                stream.h2_write_lock::ReentrantLock,
                stream.h2_conn::Union{TCP.Conn,TLS.Conn},
                DataFrame(stream.h2_stream_id, true, UInt8[]),
                _server_write_deadline_ns(stream.server::Server),
            )
        end
        @atomic :release stream.write_closed = true
        return nothing
    end
    if stream.write_mode == _ServerStreamWriteMode.FIXED
        if stream.response.content_length >= 0 && stream.written_bytes != stream.response.content_length
            throw(ProtocolError("response body bytes did not match Content-Length"))
        end
        _write_server_stream_head!(stream)
        body_bytes = take!(stream.request_buffer)
        _write_server_stream_bytes!(stream, body_bytes, false)
    elseif stream.write_mode == _ServerStreamWriteMode.CHUNKED
        io = IOBuffer()
        write(io, "0\r\n")
        _write_headers!(io, stream.response.trailers)
        write(io, "\r\n")
        _write_server_stream_bytes!(stream, take!(io))
    end
    @atomic :release stream.write_closed = true
    return nothing
end

function _server_closeread(stream::Stream)::Response
    _require_server_stream(stream)
    already_closed = @atomic :acquire stream.read_closed
    already_closed && return stream.response
    if !_stream_request_body_fully_consumed(stream)
        stream.response.close = true
        @try_ignore begin
            _stream_request_body_close!(stream)
        end
    end
    @atomic :release stream.read_closed = true
    return stream.response
end

function _server_close(stream::Stream)::Nothing
    _require_server_stream(stream)
    @try_ignore begin
        _server_closewrite(stream)
    end
    @try_ignore begin
        _server_closeread(stream)
    end
    return nothing
end

function _write_response_body_to_stream!(stream::Stream, body)::Nothing
    body === nothing && return nothing
    if body isa EmptyBody
        return nothing
    end
    if body isa AbstractString
        write(stream, body::AbstractString)
        return nothing
    end
    if body isa AbstractVector{UInt8}
        write(stream, body::AbstractVector{UInt8})
        return nothing
    end
    if body isa AbstractBody
        buf = Vector{UInt8}(undef, 16 * 1024)
        try
            while true
                n = body_read!(body::AbstractBody, buf)
                n == 0 && break
                write(stream, @view(buf[1:n]))
            end
        finally
            @try_ignore begin
                body_close!(body::AbstractBody)
            end
        end
        return nothing
    end
    throw(ProtocolError("unsupported stream response body type $(typeof(body))"))
end

struct _StreamHandlerAdapter{F}
    handler::F
end

function _buffered_stream_request(stream::Stream)::Request
    request = startread(stream)
    body_bytes = read(stream)
    body = isempty(body_bytes) ? EmptyBody() : BytesBody(body_bytes)
    return Request(
        request.method,
        request.target;
        headers=request.headers,
        trailers=request.trailers,
        body=body,
        host=request.host,
        content_length=length(body_bytes),
        proto_major=Int(request.proto_major),
        proto_minor=Int(request.proto_minor),
        close=request.close,
        context=get_request_context(request),
    )
end

function (adapter::_StreamHandlerAdapter)(stream::Stream)
    req = _buffered_stream_request(stream)
    resp = adapter.handler(req)
    resp isa Response || throw(ProtocolError("streamhandler request handler must return HTTP.Response"))
    response = resp::Response
    response.request = req
    stream.response = response
    _write_response_body_to_stream!(stream, response.body)
    closewrite(stream)
    closeread(stream)
    return nothing
end

"""
    streamhandler(request_handler) -> stream handler

Adapter that takes a request handler and returns a stream handler.
"""
function streamhandler(handler)
    return _StreamHandlerAdapter(handler)
end

