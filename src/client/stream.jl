const on_response_headers = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_response_headers(aws_stream_ptr, header_block, header_array::Ptr{aws_http_header}, num_headers, stream_ptr)
    stream = unsafe_pointer_to_objref(stream_ptr)
    headers = stream.response.headers
    addheaders(headers, header_array, num_headers)
    return Cint(0)
end

writebuf(body, maxsize=length(body) == 0 ? typemax(Int64) : length(body)) = Base.GenericIOBuffer{AbstractVector{UInt8}}(body, true, true, true, false, maxsize)

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
    return
end

const on_destroy = Ref{Ptr{Cvoid}}(C_NULL)

function c_on_destroy(stream)
    return
end

if !@isdefined aws_websocket_server_upgrade_options
    const aws_websocket_server_upgrade_options = Ptr{Cvoid}
end

mutable struct Stream{T}
    allocator::Ptr{aws_allocator}
    decompress::Union{Nothing, Bool}
    http2::Bool
    status::Cint # used as a ref
    fut::Future{Nothing}
    chunk::Union{Nothing, InputStream}
    final_chunk_written::Bool
    bufferstream::Union{Nothing, Base.BufferStream}
    gzipstream::Union{Nothing, CodecZlib.GzipDecompressorStream}
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
    Stream{T}(allocator, decompress, http2) where {T} = new{T}(allocator, decompress, http2, 0, Future{Nothing}(), nothing, false, nothing, nothing)
end

Base.hash(s::Stream, h::UInt) = hash(s.ptr, h)

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
    @assert (isdefined(s, :response) &&
             isdefined(s.response, :request) &&
             s.response.request.method in ("POST", "PUT", "PATCH")) "write is only allowed for POST, PUT, and PATCH requests"
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

function with_stream(conn::Ptr{aws_http_connection}, req::Request, chunkedbody, on_stream_response_body, decompress, http2, readtimeout, allocator)
    stream = Stream{Nothing}(allocator, decompress, http2)
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