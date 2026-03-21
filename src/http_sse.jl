# Server-Sent Event parsing plus client/server helpers.
export SSEEvent
export SSEStream
export sse_stream

import Base: close, eof, isopen, readavailable, write

const _SSE_LF = UInt8('\n')
const _SSE_CR = UInt8('\r')
const _SSE_COLON = UInt8(':')
const _SSE_SPACE = UInt8(' ')
const _DEFAULT_SSE_STREAM_MAX_LEN = 16 * 1024 * 1024

"""
    SSEEvent
    SSEEvent(data; event=nothing, id=nothing, retry=nothing)

Server-Sent Event value used for both client-side parsing and server-side
emission.

Fields:
- `data`: concatenated `data:` lines joined by `\n`
- `event`: optional event name
- `id`: last event id in effect when the event dispatched
- `retry`: last valid retry hint in milliseconds
- `fields`: all observed fields collected into a string dictionary
"""
struct SSEEvent
    data::String
    event::Union{Nothing,String}
    id::Union{Nothing,String}
    retry::Union{Nothing,Int}
    fields::Dict{String,String}
end

function SSEEvent(
    data::AbstractString;
    event::Union{Nothing,AbstractString}=nothing,
    id::Union{Nothing,AbstractString}=nothing,
    retry::Union{Nothing,Integer}=nothing,
)
    return SSEEvent(
        String(data),
        event === nothing ? nothing : String(event),
        id === nothing ? nothing : String(id),
        retry === nothing ? nothing : Int(retry),
        Dict{String,String}(),
    )
end

"""
    SSEStream(; max_len=16*1024*1024)

Writable Server-Sent Events body used by `sse_stream(response)`.

`SSEStream` is also an `AbstractBody`, so server response writers can stream it
directly to HTTP/1 or HTTP/2 connections while user code keeps pushing
`SSEEvent` values into it.
"""
mutable struct SSEStream <: AbstractBody
    buffer::Base.BufferStream
    format_buffer::IOBuffer
    lock::ReentrantLock
    max_len::Int
end

function SSEStream(; max_len::Integer=_DEFAULT_SSE_STREAM_MAX_LEN)
    max_len > 0 || throw(ArgumentError("max_len must be > 0"))
    return SSEStream(Base.BufferStream(), IOBuffer(), ReentrantLock(), Int(max_len))
end

function isopen(stream::SSEStream)::Bool
    return isopen(stream.buffer)
end

function eof(stream::SSEStream)::Bool
    return eof(stream.buffer)
end

function close(stream::SSEStream)
    close(stream.buffer)
    return nothing
end

function readavailable(stream::SSEStream)
    return readavailable(stream.buffer)
end

function body_closed(stream::SSEStream)::Bool
    return !isopen(stream)
end

function body_close!(stream::SSEStream)
    close(stream)
    return nothing
end

function body_read!(stream::SSEStream, dst::Vector{UInt8})::Int
    isempty(dst) && return 0
    return readbytes!(stream.buffer, dst, length(dst))
end

function write(stream::SSEStream, event::SSEEvent)::Int
    bytes = lock(stream.lock) do
        buf = stream.format_buffer
        truncate(buf, 0)
        if event.event !== nothing
            write(buf, "event: ", event.event, "\n")
        end
        if event.id !== nothing
            write(buf, "id: ", event.id, "\n")
        end
        if event.retry !== nothing
            write(buf, "retry: ", string(event.retry), "\n")
        end
        for line in split(event.data, '\n'; keepempty=true)
            write(buf, "data: ", line, "\n")
        end
        write(buf, "\n")
        return take!(buf)
    end
    length(bytes) <= stream.max_len || throw(ArgumentError("serialized SSE event exceeds max_len"))
    return write(stream.buffer, bytes)
end

"""
    sse_stream(response; max_len=16*1024*1024) -> SSEStream
    sse_stream(response, f; max_len=16*1024*1024) -> SSEStream

Attach a writable `SSEStream` to `response`, set the standard SSE headers, and
return the stream for incremental event emission.

The `do`-block form runs the producer on a background task and closes the
stream automatically when the callback finishes.
"""
function sse_stream(response::Response; max_len::Integer=_DEFAULT_SSE_STREAM_MAX_LEN)::SSEStream
    fieldtype(typeof(response), :body) <: AbstractBody ||
        throw(ArgumentError("sse_stream requires a Response whose body field can hold AbstractBody values"))
    stream = response.body isa SSEStream ? response.body::SSEStream : SSEStream(; max_len=max_len)
    response.body = stream
    response.content_length = Int64(-1)
    setheader(response.headers, "Content-Type", "text/event-stream")
    setheader(response.headers, "Cache-Control", "no-cache")
    removeheader(response.headers, "Content-Length")
    return stream
end

function sse_stream(response::Response, f::Function; max_len::Integer=_DEFAULT_SSE_STREAM_MAX_LEN)::SSEStream
    stream = sse_stream(response; max_len=max_len)
    errormonitor(Threads.@spawn begin
        try
            f(stream)
        catch err
            err isa InterruptException && rethrow()
            @error "SSE stream handler error" exception = (err, catch_backtrace())
        finally
            try
                close(stream)
            catch
            end
        end
    end)
    return stream
end

function sse_stream(f::Function, response::Response; max_len::Integer=_DEFAULT_SSE_STREAM_MAX_LEN)::SSEStream
    return sse_stream(response, f; max_len=max_len)
end

mutable struct _SSEState
    data_lines::Vector{String}
    has_data::Bool
    bom_checked::Bool
    saw_evidence::Bool
    event_name::Union{Nothing,String}
    last_event_id::Union{Nothing,String}
    last_retry::Union{Nothing,Int}
    fields::Dict{String,Vector{String}}
end

function _SSEState()
    return _SSEState(String[], false, false, false, nothing, nothing, nothing, Dict{String,Vector{String}}())
end

mutable struct _SSEClientStream{F} <: IO
    response::Response
    cancel_cb::F
    @atomic closed::Bool
end

function _SSEClientStream(response::Response, cancel_cb::F) where {F}
    return _SSEClientStream{F}(response, cancel_cb, false)
end

function Base.getproperty(stream::_SSEClientStream, field::Symbol)
    if field === :response || field === :cancel_cb || field === :closed
        return getfield(stream, field)
    end
    return getproperty(getfield(stream, :response), field)
end

function close(stream::_SSEClientStream)
    was_closed = @atomic :acquire stream.closed
    was_closed && return nothing
    @atomic :release stream.closed = true
    stream.cancel_cb()
    return nothing
end

function isopen(stream::_SSEClientStream)::Bool
    return !(@atomic :acquire stream.closed)
end

struct _SSEStop <: Exception
end

function _wrap_sse_callback(callback::Function, stream::_SSEClientStream, response::Response)::Function
    dummy = SSEEvent("", nothing, nothing, nothing, Dict{String,String}())
    if applicable(callback, stream, dummy)
        return event -> begin
            callback(stream, event)
            isopen(stream) || throw(_SSEStop())
            return nothing
        end
    end
    _ = response
    applicable(callback, dummy) || throw(ArgumentError("sse_callback must accept (event) or (stream, event)"))
    return event -> begin
        callback(event)
        return nothing
    end
end

function _trim_sse_line_length(bytes::AbstractVector{UInt8})::Int
    len = length(bytes)
    while len > 0 && bytes[len] == _SSE_CR
        len -= 1
    end
    return len
end

function _sse_bytes_to_string(bytes::AbstractVector{UInt8})::String
    isempty(bytes) && return ""
    try
        return String(bytes)
    catch err
        err isa ArgumentError && throw(ErrorException("SSE stream emitted invalid UTF-8 data"))
        rethrow(err)
    end
end

function _looks_like_sse_prefix(partial::Vector{UInt8})::Bool
    isempty(partial) && return false
    idx = 1
    if length(partial) >= 3 && partial[1] == 0xEF && partial[2] == 0xBB && partial[3] == 0xBF
        idx = 4
    end
    idx > length(partial) && return false
    b = partial[idx]
    b == _SSE_COLON && return true
    remaining = length(partial) - idx + 1
    remaining >= 4 && partial[idx] == UInt8('d') && partial[idx+1] == UInt8('a') &&
        partial[idx+2] == UInt8('t') && partial[idx+3] == UInt8('a') && return true
    remaining >= 5 && partial[idx] == UInt8('e') && partial[idx+1] == UInt8('v') &&
        partial[idx+2] == UInt8('e') && partial[idx+3] == UInt8('n') && partial[idx+4] == UInt8('t') &&
        return true
    remaining >= 2 && partial[idx] == UInt8('i') && partial[idx+1] == UInt8('d') && return true
    remaining >= 5 && partial[idx] == UInt8('r') && partial[idx+1] == UInt8('e') &&
        partial[idx+2] == UInt8('t') && partial[idx+3] == UInt8('r') && partial[idx+4] == UInt8('y') &&
        return true
    return false
end

function _append_sse_field!(state::_SSEState, field::String, value::String)::Nothing
    values = get(() -> String[], state.fields, field)
    push!(values, value)
    state.fields[field] = values
    return nothing
end

function _parse_sse_retry(value::String)
    parsed = tryparse(Int, strip(value))
    (parsed === nothing || parsed < 0) && return nothing
    return parsed
end

function _process_sse_field!(state::_SSEState, field::String, value::String)::Nothing
    if field == "data"
        state.saw_evidence = true
        _append_sse_field!(state, field, value)
        push!(state.data_lines, value)
        state.has_data = true
        return nothing
    end
    if field == "event"
        state.saw_evidence = true
        _append_sse_field!(state, field, value)
        state.event_name = value
        return nothing
    end
    if field == "id"
        state.saw_evidence = true
        occursin('\0', value) && return nothing
        _append_sse_field!(state, field, value)
        state.last_event_id = value
        return nothing
    end
    if field == "retry"
        state.saw_evidence = true
        _append_sse_field!(state, field, value)
        parsed = _parse_sse_retry(value)
        parsed === nothing || (state.last_retry = parsed)
        return nothing
    end
    _append_sse_field!(state, field, value)
    return nothing
end

function _build_sse_fields(state::_SSEState)::Dict{String,String}
    out = Dict{String,String}()
    for (key, entries) in state.fields
        isempty(entries) && continue
        out[key] = length(entries) == 1 ? entries[1] : join(entries, "\n")
    end
    return out
end

function _reset_sse_event!(state::_SSEState)::Nothing
    empty!(state.data_lines)
    state.has_data = false
    state.event_name = nothing
    for values in values(state.fields)
        empty!(values)
    end
    return nothing
end

function _emit_sse_event!(state::_SSEState, callback::Function)::Nothing
    data = isempty(state.data_lines) ? "" : join(state.data_lines, "\n")
    event = SSEEvent(data, state.event_name, state.last_event_id, state.last_retry, _build_sse_fields(state))
    callback(event)
    return nothing
end

function _dispatch_sse_event!(state::_SSEState, callback::Function)::Nothing
    if state.has_data
        _emit_sse_event!(state, callback)
    end
    _reset_sse_event!(state)
    return nothing
end

function _process_sse_line!(state::_SSEState, raw::AbstractVector{UInt8}, callback::Function)::Nothing
    line_len = _trim_sse_line_length(raw)
    if line_len == 0
        _dispatch_sse_event!(state, callback)
        return nothing
    end
    line = line_len == length(raw) ? raw : @view raw[1:line_len]
    if !state.bom_checked
        state.bom_checked = true
        if length(line) >= 3 && line[1] == 0xEF && line[2] == 0xBB && line[3] == 0xBF
            line = length(line) == 3 ? UInt8[] : @view line[4:length(line)]
            isempty(line) && return nothing
        end
    end
    line[1] == _SSE_COLON && (state.saw_evidence = true; return nothing)
    colon_idx = findfirst(isequal(_SSE_COLON), line)
    if colon_idx === nothing
        field = _sse_bytes_to_string(line)
        value = ""
    else
        field = colon_idx == 1 ? "" : _sse_bytes_to_string(@view line[1:colon_idx-1])
        value_slice = colon_idx == length(line) ? UInt8[] : @view line[colon_idx+1:length(line)]
        if !isempty(value_slice) && value_slice[1] == _SSE_SPACE
            value_slice = length(value_slice) == 1 ? UInt8[] : @view value_slice[2:length(value_slice)]
        end
        value = _sse_bytes_to_string(value_slice)
    end
    _process_sse_field!(state, field, value)
    return nothing
end

function _process_sse_chunk!(state::_SSEState, partial::Vector{UInt8}, chunk::AbstractVector{UInt8}, callback::Function)::Nothing
    start = 1
    len = length(chunk)
    while start <= len
        nl = findnext(isequal(_SSE_LF), chunk, start)
        nl === nothing && break
        stop = nl - 1
        if isempty(partial)
            if stop >= start
                _process_sse_line!(state, @view(chunk[start:stop]), callback)
            else
                _process_sse_line!(state, UInt8[], callback)
            end
        else
            if stop >= start
                append!(partial, @view(chunk[start:stop]))
            end
            _process_sse_line!(state, partial, callback)
            empty!(partial)
        end
        start = nl + 1
    end
    start <= len && append!(partial, @view(chunk[start:len]))
    return nothing
end

function _parse_sse_stream!(io::IO, callback::Function)::Int64
    state = _SSEState()
    partial = UInt8[]
    total = Int64(0)
    detect_bytes = 8 * 1024
    while !eof(io)
        chunk = readavailable(io)
        isempty(chunk) && continue
        total += length(chunk)
        _process_sse_chunk!(state, partial, chunk, callback)
        if total >= detect_bytes && !state.saw_evidence && !_looks_like_sse_prefix(partial)
            throw(ErrorException("Response does not appear to be a Server-Sent Events stream"))
        end
    end
    if !isempty(partial)
        _process_sse_line!(state, partial, callback)
        empty!(partial)
    end
    total > 0 && !state.saw_evidence && throw(ErrorException("Response does not appear to be a Server-Sent Events stream"))
    if state.has_data
        _emit_sse_event!(state, callback)
        _reset_sse_event!(state)
    end
    return total
end

function _consume_incoming_sse!(
    incoming::_IncomingResponse,
    response::Response,
    callback::Function;
    decompress::Union{Nothing,Bool},
)::Nothing
    raw_stream = Base.BufferStream()
    reader = if _should_decompress_response(incoming.head.headers, decompress)
        CodecZlib.GzipDecompressorStream(raw_stream)
    else
        raw_stream
    end
    cancelled = Ref(false)
    producer = errormonitor(Threads.@spawn begin
        try
            _pump_response_body!(raw_stream, incoming.rawbody)
        catch err
            cancelled[] || rethrow(err)
        end
    end)
    stream = _SSEClientStream(response, () -> begin
        cancelled[] = true
        try
            body_close!(incoming.rawbody)
        catch
        end
        try
            close(raw_stream)
        catch
        end
        return nothing
    end)
    wrapped = _wrap_sse_callback(callback, stream, response)
    parse_err = nothing
    try
        _parse_sse_stream!(reader, wrapped)
    catch err
        err isa _SSEStop || (parse_err = err)
    finally
        try
            close(reader)
        catch
        end
        try
            wait(producer)
        catch err
            cancelled[] || parse_err !== nothing || rethrow(err)
        end
    end
    parse_err === nothing || throw(parse_err)
    if isopen(stream)
        close(stream)
    end
    return nothing
end
