export Stream, closebody, isaborted, readall!, setstatus

writebuf(body, maxsize=length(body) == 0 ? typemax(Int64) : length(body)) = Base.GenericIOBuffer{AbstractVector{UInt8}}(body, true, true, true, false, maxsize)

mutable struct Stream{T} <: IO
    decompress::Union{Nothing, Bool}
    http2::Bool
    server_side::Bool
    status::Int
    fut::Future{Nothing}
    chunk::Union{Nothing, InputStream}
    final_chunk_written::Bool
    bufferstream::Union{Nothing, Base.BufferStream}
    gzipstream::Union{Nothing, CodecZlib.GzipDecompressorStream}
    responsebuf::Union{Nothing, IOBuffer}
    headers_ready::Threads.Event
    activated::Bool
    write_started::Bool
    read_started::Bool
    response_started::Bool
    handler_started::Bool
    ignore_writes::Bool
    readtimeout::Int
    on_complete::Union{Nothing, Function}
    released::Bool
    # remaining fields are initially undefined
    aws_stream::Any # H1Stream or H2Stream from AwsHTTP
    connection::T
    response::Response
    request::Request
    Stream{T}(decompress, http2, server_side::Bool=false) where {T} = new{T}(
        decompress,
        http2,
        server_side,
        0,
        Future{Nothing}(),
        nothing,
        false,
        nothing,
        nothing,
        nothing,
        Threads.Event(),
        false,
        false,
        false,
        false,
        false,
        false,
        0,
        nothing,
        false,
    )
end

Base.hash(s::Stream, h::UInt) = hash(objectid(s), h)

getrequest(s::Stream) = s.request

function _with_http2_connection(f::Function, stream::Stream)
    !isdefined(stream, :aws_stream) && throw(ArgumentError("HTTP stream is not initialized"))
    conn = stream.aws_stream.owning_connection
    return f(conn)
end

http2_ping(stream::Stream; data=nothing) = _with_http2_connection(conn -> http2_ping(conn; data=data), stream)
http2_change_settings(stream::Stream, settings) = _with_http2_connection(conn -> http2_change_settings(conn, settings), stream)
http2_local_settings(stream::Stream) = _with_http2_connection(http2_local_settings, stream)
http2_remote_settings(stream::Stream) = _with_http2_connection(http2_remote_settings, stream)
http2_send_goaway(stream::Stream, http2_error::Integer; allow_more_streams::Bool=true, debug_data=nothing) =
    _with_http2_connection(conn -> http2_send_goaway(conn, http2_error; allow_more_streams=allow_more_streams, debug_data=debug_data), stream)
http2_get_sent_goaway(stream::Stream) = _with_http2_connection(http2_get_sent_goaway, stream)
http2_get_received_goaway(stream::Stream) = _with_http2_connection(http2_get_received_goaway, stream)
http2_update_window(stream::Stream, increment::Integer) =
    _with_http2_connection(conn -> http2_update_window(conn, increment), stream)

function update_window(stream::Stream, increment::Integer)
    !isdefined(stream, :aws_stream) && throw(ArgumentError("HTTP stream is not initialized"))
    increment < 0 && throw(ArgumentError("increment must be >= 0"))
    if stream.http2
        increment > HTTP2_MAX_WINDOW_SIZE && throw(ArgumentError("increment must be <= $(HTTP2_MAX_WINDOW_SIZE)"))
        AwsHTTP.h2_stream_update_window!(stream.aws_stream, UInt32(increment))
    else
        increment > typemax(UInt64) && throw(ArgumentError("increment too large"))
        AwsHTTP.http_stream_update_window(stream.aws_stream, UInt64(increment))
    end
    return
end

function writechunk(s::Stream, chunk::RequestBodyTypes)
    if !s.server_side && !(chunk isa AbstractString && isempty(chunk))
        @assert (isdefined(s, :response) &&
                 isdefined(s.response, :request) &&
                 s.response.request.method in ("POST", "PUT", "PATCH")) "write is only allowed for POST, PUT, and PATCH requests"
    end
    s.chunk = InputStream()
    is = s.chunk
    if chunk isa AbstractVector{UInt8}
        is.bodyref = chunk
        is.bodylen = length(chunk)
    elseif chunk isa AbstractString
        is.bodyref = chunk
        is.bodylen = sizeof(chunk)
    else
        is.bodyref = chunk
        is.bodylen = nbytes(chunk) === nothing ? 0 : nbytes(chunk)
    end
    write_fut = Reseau.EventLoops.Future{Int}()
    if s.http2
        data = if chunk isa AbstractString
            Vector{UInt8}(codeunits(chunk))
        elseif chunk isa AbstractVector{UInt8}
            chunk
        else
            UInt8[]
        end
        is_final = isempty(data)
        AwsHTTP.h2_stream_write_data!(s.aws_stream, data;
            end_stream=is_final,
            completion=write_fut,
        ) != 0 && aws_throw_error()
    else
        data = if chunk isa AbstractString
            IOBuffer(codeunits(chunk))
        elseif chunk isa AbstractVector{UInt8}
            IOBuffer(chunk)
        else
            IOBuffer(UInt8[])
        end
        h1chunk = AwsHTTP.h1_chunk_new(data, is.bodylen;
            completion=write_fut,
        )
        AwsHTTP.h1_stream_write_chunk!(s.aws_stream, h1chunk) != 0 && aws_throw_error()
        _h1_flush_outgoing!(s)
    end
    write_err = wait(write_fut)
    write_err == AwsHTTP.OP_SUCCESS || throw(CapturedException(aws_error(write_err), Base.backtrace()))
    if isdefined(s, :response) && s.response !== nothing
        if s.server_side
            s.response.metrics.response_body_length += is.bodylen
        else
            s.response.metrics.request_body_length += is.bodylen
        end
    end
    return is.bodylen
end

function _ensure_response!(s::Stream)
    if !isdefined(s, :response) || s.response === nothing
        s.response = Response(200, nothing, nothing, s.http2)
    end
    return s.response
end

# Drive H1 outgoing encoder and send encoded bytes through the channel pipeline.
# Must be called after operations that produce outgoing data (send_response, write_chunk, activate).
# For H1 only; H2 encoding is handled differently.
function _h1_flush_outgoing!(s::Stream)
    !isdefined(s, :aws_stream) && return
    h1conn = s.aws_stream.owning_connection
    slot = h1conn.slot
    slot === nothing && return
    channel = slot.channel
    channel === nothing && return
    if !Reseau.Sockets.channel_thread_is_callers_thread(channel)
        fut = Future{Nothing}()
        task = Reseau.Sockets.ChannelTask(Reseau.EventCallable(status -> begin
            Reseau.TaskStatus.T(status) == Reseau.TaskStatus.RUN_READY || return notify(fut, nothing)
            try
                _h1_flush_outgoing!(s)
                notify(fut, nothing)
            catch e
                notify(fut, CapturedException(e, catch_backtrace()))
            end
            return nothing
        end), "http_h1_flush_outgoing")
        Reseau.Sockets.channel_schedule_task_now!(channel, task)
        wait(fut)
        return
    end
    while true
        status, encoded = AwsHTTP.h1_connection_encode_outgoing!(h1conn)
        status != AwsHTTP.OP_SUCCESS && throw(AWSError("H1 encoding failed"))
        isempty(encoded) && break
        msg = Reseau.Sockets.IoMessage(length(encoded))
        buf = msg.message_data
        @inbounds for i in 1:length(encoded)
            buf.mem[i] = encoded[i]
        end
        buf.len = Csize_t(length(encoded))
        try
            Reseau.Sockets.channel_slot_send_message(slot, msg, Reseau.Sockets.ChannelDirection.WRITE)
        catch e
            e isa Reseau.ReseauError || rethrow()
            throw(AWSError("channel slot send failed"))
        end
    end
    return
end

function _send_response!(s::Stream)
    if s.response_started
        return s.response
    end
    resp = _ensure_response!(s)
    msg = getfield(resp, :msg)
    if s.http2 && AwsHTTP.http_message_get_protocol_version(msg) != AwsHTTP.HttpVersion.HTTP_2
        converted = AwsHTTP.http2_message_new_from_http1(msg)
        converted === nothing && aws_throw_error()
        setfield!(resp, :msg, converted)
        msg = converted
    end
    if s.http2
        # H2 sends response via H2Stream API
        conn = s.aws_stream.owning_connection
        AwsHTTP.h2_stream_send_response!(s.aws_stream, conn, msg) != 0 && aws_throw_error()
    else
        AwsHTTP.h1_stream_send_response!(s.aws_stream, msg) != 0 && aws_throw_error()
        _h1_flush_outgoing!(s)
    end
    s.response_started = true
    return resp
end

function _server_startwrite(s::Stream)
    if s.write_started
        return
    end
    resp = _ensure_response!(s)
    if s.request.method == "HEAD"
        s.ignore_writes = true
        _head_response!(resp)
    end
    if s.http2
        if !s.ignore_writes && resp.inputstream === nothing && hasheader(resp.headers, "content-length")
            removeheader(resp.headers, "content-length")
        end
        if !s.response_started
            _send_response!(s)
        end
        s.write_started = true
        return
    end
    if !s.ignore_writes &&
       !hasheader(resp.headers, "transfer-encoding") &&
       !hasheader(resp.headers, "upgrade")
        hasheader(resp.headers, "content-length") && removeheader(resp.headers, "content-length")
        setheader(resp.headers, "transfer-encoding", "chunked")
    end
    _send_response!(s)
    s.write_started = true
    return
end

function _server_closewrite(s::Stream)
    if s.final_chunk_written
        return
    end
    resp = _ensure_response!(s)
    if s.http2
        if !s.response_started
            if s.ignore_writes
                setinputstream!(resp, nothing)
            end
            _send_response!(s)
        end
        if s.ignore_writes
            s.final_chunk_written = true
            return
        end
        if resp.trailers !== nothing
            AwsHTTP.h2_stream_add_trailing_headers!(s.aws_stream, resp.trailers.hdrs) != 0 && aws_throw_error()
        end
        writechunk(s, "")
        s.final_chunk_written = true
        return
    end
    if !s.response_started
        if !s.ignore_writes &&
           !hasheader(resp.headers, "transfer-encoding") &&
           !hasheader(resp.headers, "upgrade")
            hasheader(resp.headers, "content-length") && removeheader(resp.headers, "content-length")
            setheader(resp.headers, "transfer-encoding", "chunked")
        end
        _send_response!(s)
    end
    if s.ignore_writes
        s.final_chunk_written = true
        return
    end
    if hasheader(resp.headers, "upgrade")
        s.final_chunk_written = true
        return
    end
    if resp.trailers !== nothing
        AwsHTTP.h1_stream_add_chunked_trailer!(s.aws_stream, resp.trailers.hdrs) != 0 && aws_throw_error()
    end
    writechunk(s, "")
    s.final_chunk_written = true
    return
end

function _activate_stream!(s::Stream)
    if s.server_side
        s.activated = true
        return
    end
    if !s.activated
        if s.http2
            conn = s.aws_stream.owning_connection
            status, _ = AwsHTTP.h2_stream_activate!(s.aws_stream, conn)
            status != 0 && aws_throw_error()
            s.activated = true
            AwsHTTP._h2_connection_flush_outgoing!(conn)
        else
            AwsHTTP.h1_stream_activate!(s.aws_stream) != 0 && aws_throw_error()
            s.activated = true
            _h1_flush_outgoing!(s)
        end
    end
    return
end

function startwrite(s::Stream)
    if s.server_side
        return _server_startwrite(s)
    end
    if s.write_started
        return
    end
    if !s.http2 &&
       !hasheader(s.request.headers, "content-length") &&
       !hasheader(s.request.headers, "transfer-encoding") &&
       !hasheader(s.request.headers, "upgrade")
        setheader(s.request.headers, "transfer-encoding", "chunked")
    end
    _activate_stream!(s)
    s.write_started = true
    return
end

function closewrite(s::Stream)
    if s.server_side
        return _server_closewrite(s)
    end
    if s.final_chunk_written
        return
    end
    if s.http2
        _activate_stream!(s)
        writechunk(s, "")
        s.final_chunk_written = true
        return
    end
    if s.write_started
        writechunk(s, "")
        s.final_chunk_written = true
    elseif hasheader(s.request.headers, "transfer-encoding")
        _activate_stream!(s)
        writechunk(s, "")
        s.final_chunk_written = true
    else
        _activate_stream!(s)
    end
    return
end

function closebody(s::Stream)
    closewrite(s)
    return
end

function readall!(s::Stream, buf::Base.GenericIOBuffer=PipeBuffer())
    total = 0
    while !eof(s)
        bytes = readavailable(s)
        total += length(bytes)
        write(buf, bytes)
    end
    return total
end

function isaborted(s::Stream)
    s.server_side && return false
    if !isdefined(s, :response) || s.response === nothing
        return false
    end
    resp = s.response
    return iserror(resp) && hasheader(resp, "Connection", "close")
end

function startread(s::Stream)
    if s.server_side
        if s.read_started
            return s.request
        end
        wait(s.headers_ready)
        s.read_started = true
        return s.request
    end
    if s.read_started
        return s.response
    end
    _activate_stream!(s)
    s.http2 && !s.final_chunk_written && closewrite(s)
    wait(s.headers_ready)
    s.read_started = true
    return s.response
end

function Base.readavailable(s::Stream, n::Int=typemax(Int))
    startread(s)
    if s.bufferstream === nothing
        return UInt8[]
    end
    return _readavailable(s.bufferstream)
end

function Base.read(s::Stream, n::Integer)
    startread(s)
    s.bufferstream === nothing && return UInt8[]
    return read(s.bufferstream, n)
end

function Base.read(s::Stream)
    startread(s)
    s.bufferstream === nothing && return UInt8[]
    return read(s.bufferstream)
end

function Base.read(s::Stream, ::Type{UInt8})
    data = Base.read(s, 1)
    isempty(data) && throw(EOFError())
    return data[1]
end

function Base.eof(s::Stream)
    startread(s)
    s.bufferstream === nothing && return true
    return eof(s.bufferstream)
end

function Base.unsafe_write(s::Stream, p::Ptr{UInt8}, n::UInt)
    n == 0 && return 0
    buf = Vector{UInt8}(undef, n)
    GC.@preserve buf unsafe_copyto!(pointer(buf), p, n)
    Base.write(s, buf)
    return n
end

function Base.write(s::Stream, data::AbstractVector{UInt8})
    startwrite(s)
    if s.server_side
        if s.ignore_writes
            return length(data)
        elseif s.http2
            writechunk(s, data)
            return length(data)
        end
    end
    writechunk(s, data)
    return length(data)
end

function Base.write(s::Stream, data::StridedVector{UInt8})
    startwrite(s)
    if s.server_side
        if s.ignore_writes
            return length(data)
        elseif s.http2
            writechunk(s, data)
            return length(data)
        end
    end
    writechunk(s, data)
    return length(data)
end

function Base.write(s::Stream, data::Union{String, SubString{String}})
    startwrite(s)
    if s.server_side
        if s.ignore_writes
            return sizeof(data)
        elseif s.http2
            writechunk(s, data)
            return sizeof(data)
        end
    end
    writechunk(s, data)
    return sizeof(data)
end

function Base.write(s::Stream, data::AbstractString)
    return Base.write(s, String(data))
end

function Base.write(s::Stream, b::UInt8)
    startwrite(s)
    if s.server_side
        if s.ignore_writes
            return 1
        elseif s.http2
            writechunk(s, UInt8[b])
            return 1
        end
    end
    writechunk(s, UInt8[b])
    return 1
end

function closeread(s::Stream)
    startread(s)
    try
        try
            wait(s.fut)
        catch e
            e isa HTTPError && rethrow()
            if !s.server_side && isdefined(s, :request) && s.request !== nothing
                throw(RequestError(s.request, e))
            end
            rethrow()
        end
    finally
        s.released = true
    end
    return s.response
end

function Base.close(s::Stream)
    try
        closewrite(s)
    finally
        closeread(s)
    end
    return
end

function setstatus(s::Stream, status::Integer)
    s.server_side || error("setstatus is only supported for server streams")
    s.response_started && error("response already started")
    resp = _ensure_response!(s)
    resp.status = status
    return
end

function setheader(s::Stream, v)
    s.server_side || error("setheader is only supported for server streams")
    s.response_started && error("response already started")
    resp = _ensure_response!(s)
    setheader(resp, v)
    return
end

function setheader(s::Stream, k, v)
    return setheader(s, k => v)
end

function setheaderifabsent(s::Stream, k, v)
    s.server_side || error("setheaderifabsent is only supported for server streams")
    s.response_started && error("response already started")
    resp = _ensure_response!(s)
    setheaderifabsent(resp.headers, k, v)
    return
end

function addtrailer(s::Stream, headers::Headers)
    !isdefined(s, :aws_stream) && error("stream is not initialized")
    if s.server_side
        resp = _ensure_response!(s)
        if resp.trailers === nothing
            resp.trailers = headers
        elseif resp.trailers !== headers
            for h in headers
                addheader(resp.trailers, h)
            end
        end
        return
    end
    if s.http2
        AwsHTTP.h2_stream_add_trailing_headers!(s.aws_stream, headers.hdrs) != 0 && aws_throw_error()
    else
        AwsHTTP.h1_stream_add_chunked_trailer!(s.aws_stream, headers.hdrs) != 0 && aws_throw_error()
    end
    return
end

function addtrailer(s::Stream, h::Pair)
    trailers = Headers()
    addheader(trailers, String(h.first), String(h.second))
    return addtrailer(s, trailers)
end

function addtrailer(s::Stream, h::AbstractVector{<:Pair})
    trailers = Headers()
    for (k, v) in h
        addheader(trailers, String(k), String(v))
    end
    return addtrailer(s, trailers)
end

# ─── Callback builders ───
# These create the closure callbacks for AwsHTTP stream options.
# Each closure captures the HTTP.Stream and manipulates it directly
# when the AwsHTTP library fires the callback.

function _on_response_headers(stream::Stream)
    return (aws_stream, header_block, headers_vec) -> begin
        if header_block == AwsHTTP.HttpHeaderBlock.TRAILING
            trailers = stream.response.trailers
            if trailers === nothing
                trailers = Headers()
                stream.response.trailers = trailers
            end
            for h in headers_vec
                addheader(trailers, h)
            end
        else
            hdrs = stream.response.headers
            for h in headers_vec
                addheader(hdrs, h)
            end
        end
        return AwsHTTP.OP_SUCCESS
    end
end

function _on_response_header_block_done(stream::Stream)
    return (aws_stream, header_block) -> begin
        stream.status = aws_stream.response_status
        stream.response.status = stream.status
        if header_block != AwsHTTP.HttpHeaderBlock.MAIN
            return AwsHTTP.OP_SUCCESS
        end
        if stream.decompress !== false
            val = getheader(stream.response.headers, "content-encoding")
            stream.decompress = val !== nothing && val == "gzip"
        end
        notify(stream.headers_ready)
        return AwsHTTP.OP_SUCCESS
    end
end

function _on_response_body(stream::Stream)
    return (aws_stream, data::AbstractVector{UInt8}) -> begin
        stream.response.metrics.response_body_length += length(data)
        if stream.decompress
            if stream.gzipstream === nothing
                stream.bufferstream = b = Base.BufferStream()
                stream.gzipstream = g = CodecZlib.GzipDecompressorStream(b)
                write(g, data)
            else
                write(stream.gzipstream, data)
            end
        else
            if stream.bufferstream === nothing
                stream.bufferstream = b = Base.BufferStream()
                write(b, data)
            else
                write(stream.bufferstream, data)
            end
        end
        return AwsHTTP.OP_SUCCESS
    end
end

function _on_metrics(stream::Stream)
    return (aws_stream, metrics) -> begin
        if metrics.send_start_timestamp_ns != -1
            stream.response.metrics.stream_metrics = metrics
        end
        return nothing
    end
end

function _on_complete(stream::Stream)
    return (aws_stream, error_code) -> begin
        if stream.gzipstream !== nothing
            close(stream.gzipstream)
        end
        if stream.bufferstream !== nothing
            close(stream.bufferstream)
        end
        if error_code != 0 && !stream.http2 && isdefined(stream, :connection) && stream.connection !== nothing
            AwsHTTP.http_connection_close(stream.connection)
        end
        if error_code != 0
            if error_code == AwsHTTP.ERROR_HTTP_RESPONSE_FIRST_BYTE_TIMEOUT && stream.readtimeout > 0
                notify(stream.fut, TimeoutError(stream.readtimeout))
            else
                notify(stream.fut, CapturedException(aws_error(error_code), Base.backtrace()))
            end
        else
            notify(stream.fut, nothing)
        end
        notify(stream.headers_ready)
        stream.released = true
        return nothing
    end
end

function _make_request_options(stream::Stream, req::Request; chunkedbody=nothing, readtimeout=0)
    msg = getfield(req, :msg)
    return AwsHTTP.HttpMakeRequestOptions(;
        request=msg,
        on_response_headers=_on_response_headers(stream),
        on_response_header_block_done=_on_response_header_block_done(stream),
        on_response_body=_on_response_body(stream),
        on_metrics=_on_metrics(stream),
        on_complete=_on_complete(stream),
        http2_use_manual_data_writes=(chunkedbody !== nothing),
        response_first_byte_timeout_ms=UInt64(readtimeout * 1000),
    )
end

# ─── with_stream_manager: H2 stream manager path ───

function with_stream_manager(client::Client, req::Request, chunkedbody, on_stream_response_body, decompress, readtimeout; context=nothing)
    start_time = context !== nothing ? time() : 0.0
    stream = Stream{Nothing}(decompress, true, false)
    stream.readtimeout = readtimeout
    if on_stream_response_body !== nothing
        stream.bufferstream = Base.BufferStream()
    end
    stream.response = resp = Response(0, nothing, nothing, true)
    resp.metrics = RequestMetrics()
    resp.request = req
    resp.metrics.request_body_length = bodylen(req)
    request_options = _make_request_options(stream, req; chunkedbody=chunkedbody, readtimeout=readtimeout)

    # Acquire a connection from the H2 stream manager
    connection, error_code = wait(AwsHTTP.http2_stream_manager_acquire_stream(client.http2_stream_manager))
    if error_code != AwsHTTP.OP_SUCCESS || connection === nothing
        ec = error_code != AwsHTTP.OP_SUCCESS ? error_code : AwsHTTP.ERROR_HTTP_CONNECTION_CLOSED
        throw(CapturedException(aws_error(ec), Base.backtrace()))
    end

    # Create stream on the acquired connection
    aws_stream = AwsHTTP.http_connection_make_request(connection, request_options)
    aws_stream === nothing && aws_throw_error()
    stream.aws_stream = aws_stream
    timeout_task = nothing
    if readtimeout > 0
        timeout_task = errormonitor(Threads.@spawn begin
            _task_sleep_s(readtimeout)
            (@atomic stream.fut.set) != 0 && return
            notify(stream.fut, TimeoutError(readtimeout))
            if isdefined(stream, :aws_stream)
                AwsHTTP.h2_stream_cancel!(stream.aws_stream)
            end
        end)
    end

    # Activate stream
    _activate_stream!(stream)

    try
        # Write chunked body if provided
        if chunkedbody !== nothing
            foreach(chunk -> writechunk(stream, chunk), chunkedbody)
            writechunk(stream, "")
        end
        if on_stream_response_body !== nothing
            try
                while !eof(stream.bufferstream)
                    on_stream_response_body(resp, _readavailable(stream.bufferstream))
                end
                try
                    wait(stream.fut)
                catch e
                    e isa HTTPError && rethrow()
                    throw(RequestError(req, e))
                end
            catch e
                rethrow(DontRetry(e))
            end
        else
            try
                wait(stream.fut)
            catch e
                e isa HTTPError && rethrow()
                throw(RequestError(req, e))
            end
            if stream.bufferstream !== nothing
                resp.body = _readavailable(stream.bufferstream)
            else
                resp.body = UInt8[]
            end
        end
        return resp
    finally
        timeout_task = nothing
        stream.released = true
        AwsHTTP.http2_stream_manager_release_stream(client.http2_stream_manager, connection)
        if context !== nothing
            _record_layer!(context, :streamlayer, start_time)
        end
    end
end

# ─── with_stream: connection manager path ───

function with_stream(conn, req::Request, chunkedbody, on_stream_response_body, decompress, http2, readtimeout; context=nothing)
    start_time = context !== nothing ? time() : 0.0
    stream = Stream{typeof(conn)}(decompress, http2, false)
    stream.readtimeout = readtimeout
    if on_stream_response_body !== nothing
        stream.bufferstream = Base.BufferStream()
    end
    stream.connection = conn

    request_options = _make_request_options(stream, req;
        chunkedbody=(http2 ? chunkedbody : nothing),
        readtimeout=readtimeout)

    aws_stream = AwsHTTP.http_connection_make_request(conn, request_options)
    aws_stream === nothing && aws_throw_error()
    stream.aws_stream = aws_stream
    # Check actual connection version (may have been upgraded)
    actual_http2 = AwsHTTP.http_connection_get_version(conn) == AwsHTTP.HttpVersion.HTTP_2
    stream.http2 = actual_http2
    stream.response = resp = Response(0, nothing, nothing, actual_http2)
    resp.metrics = RequestMetrics()
    resp.request = req
    resp.metrics.request_body_length = bodylen(req)
    timeout_task = nothing
    if readtimeout > 0
        timeout_task = errormonitor(Threads.@spawn begin
            _task_sleep_s(readtimeout)
            (@atomic stream.fut.set) != 0 && return
            if !stream.http2 && isdefined(stream, :connection)
                conn = stream.connection
                if conn !== nothing && conn.slot !== nothing && conn.slot.channel !== nothing
                    Reseau.Sockets.channel_shutdown!(conn.slot.channel, AwsHTTP.ERROR_HTTP_RESPONSE_FIRST_BYTE_TIMEOUT; shutdown_immediately=true)
                elseif conn !== nothing
                    AwsHTTP.http_connection_close(conn)
                end
            end
            notify(stream.fut, TimeoutError(readtimeout))
            if isdefined(stream, :aws_stream)
                if stream.http2
                    AwsHTTP.h2_stream_cancel!(stream.aws_stream)
                else
                    AwsHTTP.http_stream_cancel(stream.aws_stream)
                end
            end
        end)
    end

    try
        _activate_stream!(stream)
        # Write chunked body if provided
        if chunkedbody !== nothing
            foreach(chunk -> writechunk(stream, chunk), chunkedbody)
            writechunk(stream, "")
        end
        if on_stream_response_body !== nothing
            try
                while !eof(stream.bufferstream)
                    on_stream_response_body(resp, _readavailable(stream.bufferstream))
                end
                try
                    wait(stream.fut)
                catch e
                    e isa HTTPError && rethrow()
                    throw(RequestError(req, e))
                end
            catch e
                rethrow(DontRetry(e))
            end
        else
            try
                wait(stream.fut)
            catch e
                e isa HTTPError && rethrow()
                throw(RequestError(req, e))
            end
            if stream.bufferstream !== nothing
                resp.body = _readavailable(stream.bufferstream)
            else
                resp.body = UInt8[]
            end
        end
        return resp
    finally
        timeout_task = nothing
        stream.released = true
        if context !== nothing
            _record_layer!(context, :streamlayer, start_time)
        end
    end
end

# can be removed once https://github.com/JuliaLang/julia/pull/57211 is fully released
function _readavailable(this::Base.BufferStream)
    bytes = lock(this.cond) do
        Base.wait_readnb(this, 1)
        buf = this.buffer
        @assert buf.seekable == false
        take!(buf)
    end
    return bytes
end
