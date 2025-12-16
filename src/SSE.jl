module SSE

export SSEEvent, SSEStream, sse_stream

using CodecZlib
using SimpleBufferStream: BufferStream
using ..IOExtras, ..Messages, ..Streams, ..Strings
using ..Exceptions: @try
import ..HTTP

const LF = UInt8('\n')
const CR = UInt8('\r')
const COLON = UInt8(':')
const SPACE = UInt8(' ')
const EMPTY_LINE = UInt8[]
const DEFAULT_SSE_STREAM_MAX_LEN = 16 * 1024 * 1024 # 16 MiB

struct SSEEvent
    data::String
    event::Union{Nothing,String}
    id::Union{Nothing,String}
    retry::Union{Nothing,Int}
    fields::Dict{String,String}
end

"""
    SSEEvent(data; event=nothing, id=nothing, retry=nothing)

Construct an SSE event for server-side emission.

# Arguments
- `data::AbstractString`: The event data (required)
- `event::Union{Nothing,AbstractString}=nothing`: Optional event type name
- `id::Union{Nothing,AbstractString}=nothing`: Optional event ID
- `retry::Union{Nothing,Integer}=nothing`: Optional retry timeout in milliseconds
"""
function SSEEvent(data::AbstractString;
        event::Union{Nothing,AbstractString}=nothing,
        id::Union{Nothing,AbstractString}=nothing,
        retry::Union{Nothing,Integer}=nothing)
    return SSEEvent(
        String(data),
        event === nothing ? nothing : String(event),
        id === nothing ? nothing : String(id),
        retry === nothing ? nothing : Int(retry),
        Dict{String,String}()
    )
end

# Server-side SSE support

"""
    SSEStream <: IO

A stream for writing Server-Sent Events (SSE) to an HTTP response.

Create an SSEStream using [`sse_stream`](@ref) which sets up the response
with the correct content type and returns the stream for writing events.

# Example
```julia
HTTP.serve() do request
    response = HTTP.Response(200)
    HTTP.sse_stream(response) do stream
        for i in 1:5
            write(stream, HTTP.SSEEvent("Event \$i"))
            sleep(1)
        end
    end
    return response
end
```
"""
struct SSEStream <: IO
    buffer::BufferStream
    iobuffer::IOBuffer
    lock::ReentrantLock
end

SSEStream(; max_len::Integer=DEFAULT_SSE_STREAM_MAX_LEN) =
    SSEStream(BufferStream(Int(max_len)), IOBuffer(), ReentrantLock())

Base.isopen(s::SSEStream) = isopen(s.buffer)
Base.eof(s::SSEStream) = eof(s.buffer)
Base.close(s::SSEStream) = close(s.buffer)
Base.readavailable(s::SSEStream) = readavailable(s.buffer)

"""
    write(stream::SSEStream, event::SSEEvent)

Write an SSE event to the stream in the standard SSE wire format.

The event is formatted according to the SSE specification:
- `event:` line (if event type is set)
- `id:` line (if id is set)
- `retry:` line (if retry is set)
- `data:` lines (one per line in the data, supporting multiline data)
- Empty line to signal end of event
"""
function Base.write(s::SSEStream, event::SSEEvent)
    bytes = lock(s.lock) do
        buf = s.iobuffer
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
    return write(s.buffer, bytes)
end

"""
    sse_stream(response::HTTP.Response; max_len=16*1024*1024) -> SSEStream
    sse_stream(response::HTTP.Response, f::Function; max_len=16*1024*1024) -> SSEStream

Create an SSEStream and configure the response for Server-Sent Events.

This function:
1. Creates an SSEStream
2. Sets it as the response body
3. Adds the `Content-Type: text/event-stream` header
4. Adds `Cache-Control: no-cache` header (recommended for SSE)

The `do`-block form runs the writer in a background task and closes the stream
when `f` completes.

# Example
```julia
HTTP.serve() do request
    response = HTTP.Response(200)
    HTTP.sse_stream(response) do stream
        for i in 1:5
            write(stream, HTTP.SSEEvent("Event \$i"))
            sleep(1)
        end
    end
    return response
end
```
"""
function sse_stream(response::Response; max_len::Integer=DEFAULT_SSE_STREAM_MAX_LEN)
    stream = SSEStream(; max_len=max_len)
    response.body = stream
    Messages.setheader(response, "Content-Type" => "text/event-stream")
    Messages.setheader(response, "Cache-Control" => "no-cache")
    return stream
end

function sse_stream(response::Response, f::Function; max_len::Integer=DEFAULT_SSE_STREAM_MAX_LEN)
    stream = sse_stream(response; max_len=max_len)
    Threads.@spawn begin
        try
            f(stream)
        catch err
            err isa InterruptException && rethrow()
            @error "SSE stream handler error" exception=(err, catch_backtrace())
        finally
            close(stream)
        end
    end
    return stream
end

function sse_stream(f::Function, response::Response; max_len::Integer=DEFAULT_SSE_STREAM_MAX_LEN)
    return sse_stream(response, f; max_len=max_len)
end

mutable struct SSEState
    data_lines::Vector{String}
    has_data::Bool
    bom_checked::Bool
    saw_evidence::Bool
    event_name::Union{Nothing,String}
    last_event_id::Union{Nothing,String}
    last_retry::Union{Nothing,Int}
    fields::Dict{String,Vector{String}}
end

function SSEState()
    return SSEState(String[], false, false, false, nothing, nothing, nothing, Dict{String,Vector{String}}())
end

function handle_sse_stream(stream::Stream{<:Response}, callback::Function;
        decompress::Union{Nothing,Bool}=nothing, context_lock::Union{Nothing,ReentrantLock}=nothing)
    callback isa Function || throw(ArgumentError("`sse_callback` must be a callable"))
    response = stream.message
    io, tsk = wrap_stream(stream, response, decompress)
    response.body = HTTP.nobody
    wrapped_callback = wrap_callback(callback, stream)
    bytes_read = 0
    try
        bytes_read = parse_stream!(io, wrapped_callback)
        tsk === nothing || wait(tsk)
    catch
        @try Base.IOError EOFError close(stream)
        tsk === nothing || @try Base.IOError EOFError wait(tsk)
        rethrow()
    end
    if context_lock === nothing
        response.request.context[:nbytes] = get(response.request.context, :nbytes, 0) + bytes_read
    else
        Base.@lock context_lock begin
            response.request.context[:nbytes] = get(response.request.context, :nbytes, 0) + bytes_read
        end
    end
    return
end

function ensure_sse_content_type(response::Response)
    ctype = header(response, "Content-Type")
    isempty(ctype) && throw(ErrorException("Response Content-Type is not text/event-stream"))
    base = strip(first(split(ctype, ';')))
    ascii_lc_isequal(base, "text/event-stream") ||
        throw(ErrorException("Response Content-Type is not text/event-stream"))
end

function wrap_callback(callback::Function, stream::Stream{<:Response})
    dummy = SSEEvent("", nothing, nothing, nothing, Dict{String,String}())
    if applicable(callback, stream, dummy)
        return event -> callback(stream, event)
    else
        return callback
    end
end

function wrap_stream(stream::Stream{<:Response}, response::Response,
        decompress::Union{Nothing,Bool})
    encoding = header(response, "Content-Encoding")
    should_decompress = decompress === true ||
        (decompress === nothing && ascii_lc_isequal(encoding, "gzip"))
    if should_decompress
        buf = BufferStream()
        gzstream = GzipDecompressorStream(buf)
        tsk = @async begin
            try
                write(gzstream, stream)
            finally
                close(gzstream)
            end
        end
        return buf, tsk
    else
        return stream, nothing
    end
end

function parse_stream!(io, callback::Function)
    state = SSEState()
    partial = Vector{UInt8}()
    total = 0
    detect_bytes = 8 * 1024
    while !eof(io)
        chunk = readavailable(io)
        isempty(chunk) && continue
        total += length(chunk)
        process_chunk!(state, partial, chunk, callback)
        if total >= detect_bytes && !state.saw_evidence && !looks_like_sse_prefix(partial)
            throw(ErrorException("Response does not appear to be a Server-Sent Events stream"))
        end
    end
    if !isempty(partial)
        process_line!(state, partial, callback)
        empty!(partial)
    end
    total > 0 && !state.saw_evidence &&
        throw(ErrorException("Response does not appear to be a Server-Sent Events stream"))
    dispatch_pending!(state, callback)
    return total
end

function looks_like_sse_prefix(partial::Vector{UInt8})
    isempty(partial) && return false
    idx = 1
    if length(partial) >= 3 && partial[1] == 0xEF && partial[2] == 0xBB && partial[3] == 0xBF
        idx = 4
    end
    idx > length(partial) && return false
    b = partial[idx]
    b == COLON && return true
    return startswith_known_field(partial, idx)
end

function startswith_known_field(bytes::Vector{UInt8}, idx::Int)
    remaining = length(bytes) - idx + 1
    remaining >= 4 && bytes[idx] == UInt8('d') && bytes[idx + 1] == UInt8('a') &&
        bytes[idx + 2] == UInt8('t') && bytes[idx + 3] == UInt8('a') && return true
    remaining >= 5 && bytes[idx] == UInt8('e') && bytes[idx + 1] == UInt8('v') &&
        bytes[idx + 2] == UInt8('e') && bytes[idx + 3] == UInt8('n') && bytes[idx + 4] == UInt8('t') &&
        return true
    remaining >= 2 && bytes[idx] == UInt8('i') && bytes[idx + 1] == UInt8('d') && return true
    remaining >= 5 && bytes[idx] == UInt8('r') && bytes[idx + 1] == UInt8('e') &&
        bytes[idx + 2] == UInt8('t') && bytes[idx + 3] == UInt8('r') && bytes[idx + 4] == UInt8('y') &&
        return true
    return false
end

function process_chunk!(state::SSEState, partial::Vector{UInt8}, chunk::AbstractVector{UInt8}, callback::Function)
    start = 1
    len = length(chunk)
    while start <= len
        nl = findnext(isequal(LF), chunk, start)
        nl === nothing && break
        stop = nl - 1
        if isempty(partial)
            if stop >= start
                process_line!(state, @view(chunk[start:stop]), callback)
            else
                process_line!(state, EMPTY_LINE, callback)
            end
        else
            if stop >= start
                append!(partial, @view(chunk[start:stop]))
            end
            process_line!(state, partial, callback)
            empty!(partial)
        end
        start = nl + 1
    end
    if start <= len
        append!(partial, @view(chunk[start:len]))
    end
end

function process_line!(state::SSEState, raw::AbstractVector{UInt8}, callback::Function)
    line_len = trim_length(raw)
    if line_len == 0
        dispatch_event!(state, callback)
        return
    end
    line = line_len == length(raw) ? raw : @view raw[1:line_len]
    if !state.bom_checked
        state.bom_checked = true
        if length(line) >= 3 && line[1] == 0xEF && line[2] == 0xBB && line[3] == 0xBF
            line = length(line) == 3 ? EMPTY_LINE : @view line[4:length(line)]
            isempty(line) && return
        end
    end
    firstbyte = line[1]
    if firstbyte == COLON
        state.saw_evidence = true
        return
    end
    colon_idx = findfirst(isequal(COLON), line)
    if colon_idx === nothing
        field = bytes_to_string(line)
        value = ""
    else
        field = colon_idx == 1 ? "" : bytes_to_string(@view line[1:colon_idx-1])
        value_slice = colon_idx == length(line) ? EMPTY_LINE : @view line[colon_idx+1:length(line)]
        if !isempty(value_slice) && value_slice[1] == SPACE
            value_slice = length(value_slice) == 1 ? EMPTY_LINE : @view value_slice[2:length(value_slice)]
        end
        value = bytes_to_string(value_slice)
    end
    process_field!(state, field, value)
end

function trim_length(bytes::AbstractVector{UInt8})
    len = length(bytes)
    while len > 0 && bytes[len] == CR
        len -= 1
    end
    return len
end

function bytes_to_string(bytes::AbstractVector{UInt8})
    isempty(bytes) && return ""
    try
        return String(bytes)
    catch e
        if e isa ArgumentError
            throw(ErrorException("SSE stream emitted invalid UTF-8 data"))
        end
        rethrow()
    end
end

function process_field!(state::SSEState, field::String, value::String)
    if field == "data"
        state.saw_evidence = true
        append_field!(state, field, value)
        push!(state.data_lines, value)
        state.has_data = true
    elseif field == "event"
        state.saw_evidence = true
        append_field!(state, field, value)
        state.event_name = value
    elseif field == "id"
        state.saw_evidence = true
        occursin('\0', value) && return
        append_field!(state, field, value)
        state.last_event_id = value
    elseif field == "retry"
        state.saw_evidence = true
        retry = parse_retry(value)
        append_field!(state, field, value)
        # Only update last_retry if the value was valid
        retry !== nothing && (state.last_retry = retry)
    else
        append_field!(state, field, value)
    end
end

function append_field!(state::SSEState, field::String, value::String)
    vec = get!(state.fields, field) do
        String[]
    end
    push!(vec, value)
end

function parse_retry(value::String)
    # Per SSE spec, if the value is not a valid integer, ignore the field
    retry = tryparse(Int, strip(value))
    # Also ignore negative values per spec
    (retry === nothing || retry < 0) && return nothing
    return retry
end

function dispatch_event!(state::SSEState, callback::Function)
    if state.has_data
        emit_event(state, callback)
    end
    reset_current_event!(state)
end

function emit_event(state::SSEState, callback::Function)
    data = isempty(state.data_lines) ? "" : join(state.data_lines, "\n")
    fields = build_fields(state)
    event = SSEEvent(data, state.event_name, state.last_event_id, state.last_retry, fields)
    callback(event)
end

function build_fields(state::SSEState)
    out = Dict{String,String}()
    for (k, entries) in state.fields
        isempty(entries) && continue
        out[k] = length(entries) == 1 ? entries[1] : join(entries, "\n")
    end
    return out
end

function reset_current_event!(state::SSEState)
    empty!(state.data_lines)
    state.has_data = false
    state.event_name = nothing
    for vec in values(state.fields)
        empty!(vec)
    end
end

function dispatch_pending!(state::SSEState, callback::Function)
    if state.has_data
        emit_event(state, callback)
        reset_current_event!(state)
    else
        reset_current_event!(state)
    end
end

end # module
