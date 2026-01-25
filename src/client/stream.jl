const on_response_headers = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_response_headers(aws_stream_ptr, header_block, header_array::Ptr{aws_http_header}, num_headers, stream_ptr)
    stream = unsafe_pointer_to_objref(stream_ptr)
    if header_block == AWS_HTTP_HEADER_BLOCK_TRAILING
        trailers = stream.response.trailers
        if trailers === nothing
            trailers = Headers(stream.response.allocator)
            stream.response.trailers = trailers
        end
        addheaders(trailers, header_array, num_headers)
    else
        headers = stream.response.headers
        addheaders(headers, header_array, num_headers)
    end
    return Cint(0)
end

writebuf(body, maxsize=length(body) == 0 ? typemax(Int64) : length(body)) = Base.GenericIOBuffer{AbstractVector{UInt8}}(body, true, true, true, false, maxsize)

function aws_http2_stream_add_trailing_headers(http2_stream::Ptr{aws_http_stream}, trailing_headers::Ptr{aws_http_headers})
    return ccall((:aws_http2_stream_add_trailing_headers, LibAwsHTTPFork.libaws_c_http_jq),
        Cint, (Ptr{aws_http_stream}, Ptr{aws_http_headers}), http2_stream, trailing_headers)
end

const on_response_header_block_done = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_response_header_block_done(aws_stream_ptr, header_block, stream_ptr)
    stream = unsafe_pointer_to_objref(stream_ptr)
    if aws_http_stream_get_incoming_response_status(aws_stream_ptr, FieldRef(stream, :status)) != 0
        return aws_raise_error(aws_last_error())
    end
    stream.response.status = stream.status
    # if this is the end of the main header block, prepare our response body to be written to, otherwise return
    if header_block != AWS_HTTP_HEADER_BLOCK_MAIN
        return Cint(0)
    end
    if stream.decompress !== false
        val = getheader(stream.response.headers, "content-encoding")
        stream.decompress = val !== nothing && val == "gzip"
    end
    notify(stream.headers_ready)
    return Cint(0)
end

const on_response_body = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_response_body(aws_stream_ptr, data::Ptr{aws_byte_cursor}, stream_ptr)
    stream = unsafe_pointer_to_objref(stream_ptr)
    bc = unsafe_load(data)
    stream.response.metrics.response_body_length += bc.len
    if stream.decompress
        if stream.gzipstream === nothing
            stream.bufferstream = b = Base.BufferStream()
            stream.gzipstream = g = CodecZlib.GzipDecompressorStream(b)
            unsafe_write(g, bc.ptr, bc.len)
        else
            unsafe_write(stream.gzipstream, bc.ptr, bc.len)
        end
    else
        if stream.bufferstream === nothing
            stream.bufferstream = b = Base.BufferStream()
            unsafe_write(b, bc.ptr, bc.len)
        else
            unsafe_write(stream.bufferstream, bc.ptr, bc.len)
        end
    end
    return Cint(0)
end

const on_metrics = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_metrics(aws_stream_ptr, metrics::Ptr{aws_http_stream_metrics}, stream_ptr)
    stream = unsafe_pointer_to_objref(stream_ptr)
    m = unsafe_load(metrics)
    if m.send_start_timestamp_ns != -1
        stream.response.metrics.stream_metrics = m
    end
    return
end

const on_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_complete(aws_stream_ptr, error_code, stream_ptr)
    stream = unsafe_pointer_to_objref(stream_ptr)
    if stream.gzipstream !== nothing
        close(stream.gzipstream)
    end
    if stream.bufferstream !== nothing
        close(stream.bufferstream)
    end
    if error_code != 0
        notify(stream.fut, CapturedException(aws_error(error_code), Base.backtrace()))
    else
        notify(stream.fut, nothing)
    end
    notify(stream.headers_ready)
    release_stream!(stream)
    return
end

const on_destroy = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_destroy(stream)
    return
end

const on_stream_acquired = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_stream_acquired(aws_stream_ptr, error_code, fut_ptr)
    fut = unsafe_pointer_to_objref(fut_ptr)
    if error_code != 0
        notify(fut, CapturedException(aws_error(error_code), Base.backtrace()))
    else
        notify(fut, aws_stream_ptr)
    end
    return
end

if !@isdefined aws_websocket_server_upgrade_options
    const aws_websocket_server_upgrade_options = Ptr{Cvoid}
end

mutable struct Stream{T} <: IO
    allocator::Ptr{aws_allocator}
    decompress::Union{Nothing, Bool}
    http2::Bool
    server_side::Bool
    status::Cint # used as a ref
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
    released::Bool
    # remaining fields are initially undefined
    ptr::Ptr{aws_http_stream}
    connection::T # Connection{F, S} (in servers.jl)
    request_options::aws_http_make_request_options
    response::Response
    method::aws_byte_cursor
    path::aws_byte_cursor
    request_handler_options::aws_http_request_handler_options
    request::Request
    http2_stream_write_data_options::aws_http2_stream_write_data_options
    chunk_options::aws_http1_chunk_options
    websocket_options::aws_websocket_server_upgrade_options
    Stream{T}(allocator, decompress, http2, server_side::Bool=false) where {T} = new{T}(
        allocator,
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
        false,
    )
end

Base.hash(s::Stream, h::UInt) = hash(s.ptr, h)

getrequest(s::Stream) = s.request

const ACTIVE_STREAMS_LOCK = ReentrantLock()
const ACTIVE_STREAMS = IdDict{Stream, Bool}()

function retain_stream!(s::Stream)
    lock(ACTIVE_STREAMS_LOCK)
    try
        ACTIVE_STREAMS[s] = true
    finally
        unlock(ACTIVE_STREAMS_LOCK)
    end
    return
end

function release_stream!(s::Stream)
    lock(ACTIVE_STREAMS_LOCK)
    try
        pop!(ACTIVE_STREAMS, s, nothing)
    finally
        unlock(ACTIVE_STREAMS_LOCK)
    end
    return
end

function release_stream_ptr!(s::Stream)
    if isdefined(s, :ptr) && s.ptr != C_NULL && !s.released
        aws_http_stream_release(s.ptr)
        s.released = true
        s.ptr = Ptr{aws_http_stream}(C_NULL)
    end
    return
end

function _with_http2_connection(f::Function, stream::Stream)
    stream.ptr == C_NULL && throw(ArgumentError("HTTP stream is not initialized"))
    conn = aws_http_stream_get_connection(stream.ptr)
    return f(_ensure_http2_connection(conn))
end

http2_ping(stream::Stream; data=nothing) = _with_http2_connection(conn -> http2_ping(conn; data=data), stream)
http2_change_settings(stream::Stream, settings) = _with_http2_connection(conn -> http2_change_settings(conn, settings), stream)
http2_local_settings(stream::Stream) = _with_http2_connection(http2_local_settings, stream)
http2_remote_settings(stream::Stream) = _with_http2_connection(http2_remote_settings, stream)
http2_send_goaway(stream::Stream, http2_error::Integer; allow_more_streams::Bool=true, debug_data=nothing) =
    _with_http2_connection(conn -> http2_send_goaway(conn, http2_error; allow_more_streams=allow_more_streams, debug_data=debug_data), stream)
http2_get_sent_goaway(stream::Stream) = _with_http2_connection(http2_get_sent_goaway, stream)
http2_get_received_goaway(stream::Stream) = _with_http2_connection(http2_get_received_goaway, stream)

const on_stream_write_on_complete = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_stream_write_on_complete(aws_stream_ptr, error_code, fut_ptr)
    fut = unsafe_pointer_to_objref(fut_ptr)
    if error_code != 0
        notify(fut, CapturedException(aws_error(error_code), Base.backtrace()))
    else
        notify(fut, nothing)
    end
    return
end

function writechunk(s::Stream, chunk::RequestBodyTypes)
    if !s.server_side && !(chunk isa AbstractString && isempty(chunk))
        @assert (isdefined(s, :response) &&
                 isdefined(s.response, :request) &&
                 s.response.request.method in ("POST", "PUT", "PATCH")) "write is only allowed for POST, PUT, and PATCH requests"
    end
    s.chunk = InputStream(s.allocator, chunk)
    fut = Future{Nothing}()
    if s.http2
        s.http2_stream_write_data_options = aws_http2_stream_write_data_options(
            s.chunk.ptr,
            chunk == "",
            on_stream_write_on_complete[],
            pointer_from_objref(fut)
        )
        aws_http2_stream_write_data(s.ptr, FieldRef(s, :http2_stream_write_data_options)) != 0 && aws_throw_error()
    else
        s.chunk_options = aws_http1_chunk_options(
            s.chunk.ptr,
            s.chunk.bodylen,
            C_NULL,
            0,
            on_stream_write_on_complete[],
            pointer_from_objref(fut)
        )
        aws_http1_stream_write_chunk(s.ptr, FieldRef(s, :chunk_options)) != 0 && aws_throw_error()
    end
    wait(fut)
    return s.chunk.bodylen
end

function _ensure_response!(s::Stream)
    if !isdefined(s, :response) || s.response === nothing
        s.response = Response(200, nothing, nothing, s.http2, s.allocator)
    end
    return s.response
end

function _send_response!(s::Stream)
    if s.response_started
        return s.response
    end
    resp = _ensure_response!(s)
    aws_http_stream_send_response(s.ptr, resp.ptr) != 0 && aws_throw_error()
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
        setinputstream!(resp, nothing)
    end
    if s.http2
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
            else
                body = s.responsebuf === nothing ? UInt8[] : take!(s.responsebuf)
                setinputstream!(resp, body)
            end
            _send_response!(s)
        end
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
        aws_http_stream_activate(s.ptr) != 0 && aws_throw_error()
        s.activated = true
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
            s.responsebuf === nothing && (s.responsebuf = IOBuffer())
            write(s.responsebuf, data)
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
            s.responsebuf === nothing && (s.responsebuf = IOBuffer())
            write(s.responsebuf, data)
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
            s.responsebuf === nothing && (s.responsebuf = IOBuffer())
            write(s.responsebuf, b)
            return 1
        end
    end
    writechunk(s, UInt8[b])
    return 1
end

function closeread(s::Stream)
    startread(s)
    try
        wait(s.fut)
    finally
        release_stream_ptr!(s)
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
    s.ptr == C_NULL && error("stream is not initialized")
    if s.http2
        aws_http2_stream_add_trailing_headers(s.ptr, headers.ptr) != 0 && aws_throw_error()
    else
        aws_http1_stream_add_chunked_trailer(s.ptr, headers.ptr) != 0 && aws_throw_error()
    end
    return
end

function addtrailer(s::Stream, h::Pair)
    trailers = Headers(s.allocator)
    addheader(trailers, String(h.first), String(h.second))
    return addtrailer(s, trailers)
end

function addtrailer(s::Stream, h::AbstractVector{<:Pair})
    trailers = Headers(s.allocator)
    for (k, v) in h
        addheader(trailers, String(k), String(v))
    end
    return addtrailer(s, trailers)
end

function with_stream_manager(client::Client, req::Request, chunkedbody, on_stream_response_body, decompress, readtimeout, allocator; context=nothing)
    if context === nothing
        stream = Stream{Nothing}(allocator, decompress, true, false)
        if on_stream_response_body !== nothing
            stream.bufferstream = Base.BufferStream()
        end
        acquire_fut = Future{Ptr{aws_http_stream}}()
        GC.@preserve stream acquire_fut begin
            stream.request_options = aws_http_make_request_options(
                1,
                req.ptr,
                pointer_from_objref(stream),
                on_response_headers[],
                on_response_header_block_done[],
                on_response_body[],
                on_metrics[],
                on_complete[],
                on_destroy[],
                chunkedbody !== nothing, # http2_use_manual_data_writes
                readtimeout * 1000 # response_first_byte_timeout_ms
            )
            stream.response = resp = Response(0, nothing, nothing, true, allocator)
            resp.metrics = RequestMetrics()
            resp.request = req
            acquire_opts = aws_http2_stream_manager_acquire_stream_options(
                on_stream_acquired[],
                pointer_from_objref(acquire_fut),
                FieldRef(stream, :request_options),
            )
            aws_http2_stream_manager_acquire_stream(client.http2_stream_manager, Ref(acquire_opts))
            stream_ptr = wait(acquire_fut)
            stream.ptr = stream_ptr
            stream.activated = true
            try
                if chunkedbody !== nothing
                    foreach(chunk -> writechunk(stream, chunk), chunkedbody)
                    writechunk(stream, "")
                end
                if on_stream_response_body !== nothing
                    try
                        while !eof(stream.bufferstream)
                            on_stream_response_body(resp, _readavailable(stream.bufferstream))
                        end
                        wait(stream.fut)
                    catch e
                        rethrow(DontRetry(e))
                    end
                else
                    wait(stream.fut)
                    if stream.bufferstream !== nothing
                        resp.body = _readavailable(stream.bufferstream)
                    else
                        resp.body = UInt8[]
                    end
                end
                return resp
            finally
                aws_http_stream_release(stream_ptr)
                stream.released = true
                stream.ptr = Ptr{aws_http_stream}(C_NULL)
            end
        end
    end

    start_time = time()
    stream = Stream{Nothing}(allocator, decompress, true, false)
    if on_stream_response_body !== nothing
        stream.bufferstream = Base.BufferStream()
    end
    acquire_fut = Future{Ptr{aws_http_stream}}()
    GC.@preserve stream acquire_fut begin
        stream.request_options = aws_http_make_request_options(
            1,
            req.ptr,
            pointer_from_objref(stream),
            on_response_headers[],
            on_response_header_block_done[],
            on_response_body[],
            on_metrics[],
            on_complete[],
            on_destroy[],
            chunkedbody !== nothing, # http2_use_manual_data_writes
            readtimeout * 1000 # response_first_byte_timeout_ms
        )
        stream.response = resp = Response(0, nothing, nothing, true, allocator)
        resp.metrics = RequestMetrics()
        resp.request = req
        acquire_opts = aws_http2_stream_manager_acquire_stream_options(
            on_stream_acquired[],
            pointer_from_objref(acquire_fut),
            FieldRef(stream, :request_options),
        )
        aws_http2_stream_manager_acquire_stream(client.http2_stream_manager, Ref(acquire_opts))
        stream_ptr = wait(acquire_fut)
        stream.ptr = stream_ptr
        stream.activated = true
        try
            if chunkedbody !== nothing
                foreach(chunk -> writechunk(stream, chunk), chunkedbody)
                writechunk(stream, "")
            end
            if on_stream_response_body !== nothing
                try
                    while !eof(stream.bufferstream)
                        on_stream_response_body(resp, _readavailable(stream.bufferstream))
                    end
                    wait(stream.fut)
                catch e
                    rethrow(DontRetry(e))
                end
            else
                wait(stream.fut)
                if stream.bufferstream !== nothing
                    resp.body = _readavailable(stream.bufferstream)
                else
                    resp.body = UInt8[]
                end
            end
            return resp
        finally
            aws_http_stream_release(stream_ptr)
            stream.released = true
            stream.ptr = Ptr{aws_http_stream}(C_NULL)
            _record_layer!(context, :streamlayer, start_time)
        end
    end
end

function with_stream(conn::Ptr{aws_http_connection}, req::Request, chunkedbody, on_stream_response_body, decompress, http2, readtimeout, allocator; context=nothing)
    if context === nothing
        stream = Stream{Nothing}(allocator, decompress, http2, false)
        if on_stream_response_body !== nothing
            stream.bufferstream = Base.BufferStream()
        end
        GC.@preserve stream begin
            stream.request_options = aws_http_make_request_options(
                1,
                req.ptr,
                pointer_from_objref(stream),
                on_response_headers[],
                on_response_header_block_done[],
                on_response_body[],
                on_metrics[],
                on_complete[],
                on_destroy[],
                http2 && chunkedbody !== nothing, # http2_use_manual_data_writes
                readtimeout * 1000 # response_first_byte_timeout_ms
            )
            stream_ptr = aws_http_connection_make_request(conn, FieldRef(stream, :request_options))
            stream_ptr == C_NULL && aws_throw_error()
            stream.ptr = stream_ptr
            http2 = aws_http_connection_get_version(conn) == AWS_HTTP_VERSION_2
            stream.response = resp = Response(0, nothing, nothing, http2, allocator)
            resp.metrics = RequestMetrics()
            resp.request = req
            try
                aws_http_stream_activate(stream_ptr) != 0 && aws_throw_error()
                # write chunked body if provided
                if chunkedbody !== nothing
                    foreach(chunk -> writechunk(stream, chunk), chunkedbody)
                    # write final chunk
                    writechunk(stream, "")
                end
                if on_stream_response_body !== nothing
                    try
                        while !eof(stream.bufferstream)
                            on_stream_response_body(resp, _readavailable(stream.bufferstream))
                        end
                        wait(stream.fut)
                    catch e
                        rethrow(DontRetry(e))
                    end
                else
                    wait(stream.fut)
                    if stream.bufferstream !== nothing
                        resp.body = _readavailable(stream.bufferstream)
                    else
                        resp.body = UInt8[]
                    end
                end
                return resp
            finally
                aws_http_stream_release(stream_ptr)
                stream.released = true
                stream.ptr = Ptr{aws_http_stream}(C_NULL)
            end
        end # GC.@preserve
    end

    start_time = time()
    stream = Stream{Nothing}(allocator, decompress, http2, false)
    if on_stream_response_body !== nothing
        stream.bufferstream = Base.BufferStream()
    end
    GC.@preserve stream begin
        stream.request_options = aws_http_make_request_options(
            1,
            req.ptr,
            pointer_from_objref(stream),
            on_response_headers[],
            on_response_header_block_done[],
            on_response_body[],
            on_metrics[],
            on_complete[],
            on_destroy[],
            http2 && chunkedbody !== nothing, # http2_use_manual_data_writes
            readtimeout * 1000 # response_first_byte_timeout_ms
        )
        stream_ptr = aws_http_connection_make_request(conn, FieldRef(stream, :request_options))
        stream_ptr == C_NULL && aws_throw_error()
        stream.ptr = stream_ptr
        http2 = aws_http_connection_get_version(conn) == AWS_HTTP_VERSION_2
        stream.response = resp = Response(0, nothing, nothing, http2, allocator)
        resp.metrics = RequestMetrics()
        resp.request = req
        try
            aws_http_stream_activate(stream_ptr) != 0 && aws_throw_error()
            # write chunked body if provided
            if chunkedbody !== nothing
                foreach(chunk -> writechunk(stream, chunk), chunkedbody)
                # write final chunk
                writechunk(stream, "")
            end
            if on_stream_response_body !== nothing
                try
                    while !eof(stream.bufferstream)
                        on_stream_response_body(resp, _readavailable(stream.bufferstream))
                    end
                    wait(stream.fut)
                catch e
                    rethrow(DontRetry(e))
                end
            else
                wait(stream.fut)
                if stream.bufferstream !== nothing
                    resp.body = _readavailable(stream.bufferstream)
                else
                    resp.body = UInt8[]
                end
            end
            return resp
        finally
            aws_http_stream_release(stream_ptr)
            stream.released = true
            stream.ptr = Ptr{aws_http_stream}(C_NULL)
            _record_layer!(context, :streamlayer, start_time)
        end
    end # GC.@preserve
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
