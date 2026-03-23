# Internal client-side verbose logging, capture, and formatting helpers.

const _VERBOSE_DEFAULT_BODY_NBYTES = 1000
const _VERBOSE_H1_CAPTURE_HEADROOM_BYTES = 256 * 1024
const _VERBOSE_CONTEXT_CONFIG_KEY = :_http_verbose_config
const _VERBOSE_CONTEXT_EXCHANGE_KEY = :_http_verbose_exchange

struct _VerboseConfig
    level::Int
    body_nbytes::Int
    io::IO
end

mutable struct _VerboseCaptureBuffer
    bytes::Vector{UInt8}
    limit::Int
    total::Int64
    truncated::Bool
end

mutable struct _VerboseExchangeState
    config::_VerboseConfig
    protocol::Symbol
    attempt::Int
    redirect_count::Int
    url::String
    request::Request
    response_head::Union{Nothing,_IncomingResponseHead}
    request_capture::_VerboseCaptureBuffer
    response_capture::_VerboseCaptureBuffer
    @atomic request_logged::Bool
    @atomic response_logged::Bool
    @atomic response_complete::Bool
end

mutable struct _VerboseTeeWriteIO{S} <: IO
    inner::S
    capture::_VerboseCaptureBuffer
end

mutable struct _VerboseRequestBody{B<:AbstractBody} <: AbstractBody
    inner::B
    capture::_VerboseCaptureBuffer
end

mutable struct _VerboseResponseBodyCapture{B<:AbstractBody} <: AbstractBody
    inner::B
    capture::Union{Nothing,_VerboseCaptureBuffer}
    on_finish::Function
    @atomic finished::Bool
end

@inline function _normalize_verbose_level(verbose)::Int
    verbose === nothing && return 0
    verbose === false && return 0
    verbose === true && return 1
    verbose isa Integer || throw(ArgumentError("verbose must be Bool or an integer level 0-3"))
    level = Int(verbose)
    0 <= level <= 3 || throw(ArgumentError("verbose must be one of false, true, 0, 1, 2, or 3"))
    return level
end

function _normalize_verbose_body_nbytes(value)::Int
    value isa Integer || throw(ArgumentError("verbose_body_nbytes must be an integer"))
    n = Int(value)
    n >= 0 || throw(ArgumentError("verbose_body_nbytes must be >= 0"))
    return n
end

function _verbose_config(; verbose=false, verbose_body_nbytes::Integer=_VERBOSE_DEFAULT_BODY_NBYTES, verbose_io::IO=stderr)::Union{Nothing,_VerboseConfig}
    level = _normalize_verbose_level(verbose)
    level == 0 && return nothing
    return _VerboseConfig(level, _normalize_verbose_body_nbytes(verbose_body_nbytes), verbose_io)
end

@inline function _request_context_verbose_config(ctx::RequestContext)::Union{Nothing,_VerboseConfig}
    return get(ctx, _VERBOSE_CONTEXT_CONFIG_KEY, nothing)
end

@inline function _set_request_context_verbose_config!(ctx::RequestContext, config::Union{Nothing,_VerboseConfig})::Nothing
    config === nothing && return nothing
    ctx[_VERBOSE_CONTEXT_CONFIG_KEY] = config
    return nothing
end

@inline function _request_context_verbose_exchange(ctx::RequestContext)::Union{Nothing,_VerboseExchangeState}
    return get(ctx, _VERBOSE_CONTEXT_EXCHANGE_KEY, nothing)
end

@inline function _set_request_context_verbose_exchange!(ctx::RequestContext, exchange::Union{Nothing,_VerboseExchangeState})::Nothing
    if exchange === nothing
        metadata = ctx.metadata
        metadata === nothing || delete!(metadata::Dict{Symbol,Any}, _VERBOSE_CONTEXT_EXCHANGE_KEY)
    else
        ctx[_VERBOSE_CONTEXT_EXCHANGE_KEY] = exchange
    end
    return nothing
end

@inline function _verbose_enabled(config::Union{Nothing,_VerboseConfig}, level::Integer=1)::Bool
    return config !== nothing && (config::_VerboseConfig).level >= level
end

function _VerboseCaptureBuffer(limit::Integer)
    limit_i = Int(limit)
    limit_i >= 0 || throw(ArgumentError("capture limit must be >= 0"))
    return _VerboseCaptureBuffer(UInt8[], limit_i, Int64(0), false)
end

@inline function _verbose_capture_limit(config::_VerboseConfig)::Int
    return config.level >= 3 ? typemax(Int) : config.body_nbytes
end

@inline function _verbose_h1_capture_limit(config::_VerboseConfig)::Int
    return config.level >= 3 ? typemax(Int) : (_VERBOSE_H1_CAPTURE_HEADROOM_BYTES + config.body_nbytes)
end

@inline function _verbose_request_capture_limit(config::_VerboseConfig, protocol::Symbol)::Int
    return protocol == :h1 ? _verbose_h1_capture_limit(config) : _verbose_capture_limit(config)
end

@inline function _verbose_response_capture_limit(config::_VerboseConfig, protocol::Symbol)::Int
    return protocol == :h1 ? _verbose_h1_capture_limit(config) : _verbose_capture_limit(config)
end

function _new_verbose_exchange(
    config::_VerboseConfig,
    protocol::Symbol,
    attempt::Integer,
    redirect_count::Integer,
    url::AbstractString,
    request::Request,
)::_VerboseExchangeState
    return _VerboseExchangeState(
        config,
        protocol,
        Int(attempt),
        Int(redirect_count),
        String(url),
        request,
        nothing,
        _VerboseCaptureBuffer(_verbose_request_capture_limit(config, protocol)),
        _VerboseCaptureBuffer(_verbose_response_capture_limit(config, protocol)),
        false,
        false,
        false,
    )
end

function _begin_verbose_exchange!(
    request::Request,
    protocol::Symbol,
    attempt::Integer,
    redirect_count::Integer,
    url::AbstractString,
)::Union{Nothing,_VerboseExchangeState}
    config = _request_context_verbose_config(request.context)
    _verbose_enabled(config, 2) || return nothing
    exchange = _new_verbose_exchange(config::_VerboseConfig, protocol, attempt, redirect_count, url, request)
    _set_request_context_verbose_exchange!(request.context, exchange)
    return exchange
end

@inline function _set_verbose_response_head!(exchange::Union{Nothing,_VerboseExchangeState}, head::_IncomingResponseHead)::Nothing
    exchange === nothing && return nothing
    (exchange::_VerboseExchangeState).response_head = head
    return nothing
end

function _wrap_verbose_request_body!(request::Request, exchange::Union{Nothing,_VerboseExchangeState})::Request
    exchange === nothing && return request
    body = request.body
    (body isa EmptyBody || body isa _VerboseRequestBody) && return request
    wrapped = _VerboseRequestBody(body, exchange.request_capture)
    return _request_nocopy(
        request.method,
        request.target,
        request.headers,
        request.trailers,
        wrapped,
        request.host,
        request.content_length,
        request.proto_major,
        request.proto_minor,
        request.close,
        request.context,
    )
end

function _verbose_capture!(capture::_VerboseCaptureBuffer, data::AbstractVector{UInt8})::Nothing
    n = length(data)
    n == 0 && return nothing
    capture.total += n
    remaining = capture.limit - length(capture.bytes)
    if remaining > 0
        copied = min(remaining, n)
        append!(capture.bytes, view(data, 1:copied))
    end
    if length(capture.bytes) < capture.total
        capture.truncated = true
    end
    return nothing
end

@inline function _verbose_capture!(capture::_VerboseCaptureBuffer, byte::UInt8)::Nothing
    capture.total += 1
    if length(capture.bytes) < capture.limit
        push!(capture.bytes, byte)
    else
        capture.truncated = true
    end
    return nothing
end

function _verbose_line!(config::Union{Nothing,_VerboseConfig}, level::Integer, message::AbstractString)::Nothing
    _verbose_enabled(config, level) || return nothing
    io = (config::_VerboseConfig).io
    println(io, "[http] ", message)
    flush(io)
    return nothing
end

function _verbose_block!(config::Union{Nothing,_VerboseConfig}, level::Integer, label::AbstractString, body::AbstractString)::Nothing
    _verbose_enabled(config, level) || return nothing
    io = (config::_VerboseConfig).io
    println(io, "[http] ", label)
    if !isempty(body)
        write(io, body)
        endswith(body, "\n") || write(io, '\n')
    end
    flush(io)
    return nothing
end

const _VERBOSE_MASKED_HEADERS = Set([
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
])

@inline function _verbose_header_value(name::AbstractString, value::AbstractString)::String
    return lowercase(String(name)) in _VERBOSE_MASKED_HEADERS ? "******" : String(value)
end

function _verbose_request_summary(request::Request, url::AbstractString)::String
    return string(request.method, " ", url)
end

function _verbose_response_summary(head::_IncomingResponseHead)::String
    proto = head.proto_major == 2 ? "HTTP/2" : string("HTTP/", Int(head.proto_major), ".", Int(head.proto_minor))
    reason = isempty(head.reason) ? "" : string(" ", head.reason)
    return string(proto, " ", head.status, reason)
end

@inline function _find_double_crlf(bytes::AbstractVector{UInt8})::Union{Nothing,Int}
    n = length(bytes)
    n < 4 && return nothing
    @inbounds for i in 1:(n - 3)
        bytes[i] == 0x0d || continue
        bytes[i + 1] == 0x0a || continue
        bytes[i + 2] == 0x0d || continue
        bytes[i + 3] == 0x0a || continue
        return i + 4
    end
    return nothing
end

function _render_textual_bytes(bytes::AbstractVector{UInt8})::Union{Nothing,String}
    isempty(bytes) && return ""
    try
        return String(copy(bytes))
    catch
        return nothing
    end
end

function _render_binary_note(total::Int64)::String
    return total == 0 ? "" : string("<", total, "-byte binary body omitted>")
end

function _body_content_encoding(headers::Union{Nothing,Headers})::Union{Nothing,String}
    headers === nothing && return nothing
    value = header(headers::Headers, "Content-Encoding", nothing)
    value === nothing && return nothing
    normalized = lowercase(strip(value::String))
    isempty(normalized) && return nothing
    normalized == "identity" && return nothing
    return normalized
end

function _render_body_for_verbose(
    body_bytes::AbstractVector{UInt8},
    body_total::Int64,
    headers::Union{Nothing,Headers},
)::String
    body_total == 0 && return ""
    encoding = _body_content_encoding(headers)
    if encoding !== nothing
        return string("<", encoding::String, "-compressed ", body_total, "-byte body omitted>")
    end
    text = _render_textual_bytes(body_bytes)
    return text === nothing ? _render_binary_note(body_total) : text
end

function _render_capture_suffix(capture::_VerboseCaptureBuffer)::String
    capture.truncated || return ""
    return string("\n[truncated after ", length(capture.bytes), " of ", capture.total, " bytes]")
end

function _format_h1_raw_message(capture::_VerboseCaptureBuffer, headers::Union{Nothing,Headers}=nothing)::String
    bytes = capture.bytes
    boundary = _find_double_crlf(bytes)
    if boundary === nothing
        rendered = _render_body_for_verbose(bytes, capture.total, headers)
        return string(rendered, _render_capture_suffix(capture))
    end
    header_text = String(copy(view(bytes, 1:(boundary - 1))))
    body_bytes = boundary > length(bytes) ? UInt8[] : collect(view(bytes, boundary:length(bytes)))
    body_total = max(capture.total - Int64(boundary - 1), Int64(0))
    rendered_body = _render_body_for_verbose(body_bytes, body_total, headers)
    return string(header_text, rendered_body, _render_capture_suffix(capture))
end

function _write_verbose_headers!(io::IO, hdrs::Headers)::Nothing
    for key in header_keys(hdrs)
        values = headers(hdrs, key)
        for value in values
            print(io, key, ": ", _verbose_header_value(key, value), "\r\n")
        end
    end
    return nothing
end

function _format_h2_request(exchange::_VerboseExchangeState)::String
    req = exchange.request
    io = IOBuffer()
    print(io, req.method, " ", req.target, " HTTP/2\r\n")
    req.host === nothing || print(io, "Host: ", req.host::String, "\r\n")
    _write_verbose_headers!(io, req.headers)
    write(io, "\r\n")
    body_bytes = exchange.request_capture.bytes
    write(io, _render_body_for_verbose(body_bytes, exchange.request_capture.total, req.headers))
    write(io, _render_capture_suffix(exchange.request_capture))
    return String(take!(io))
end

function _format_h2_response(exchange::_VerboseExchangeState)::String
    head = exchange.response_head
    head === nothing && return ""
    io = IOBuffer()
    print(io, "HTTP/2 ", head.status)
    isempty(head.reason) || print(io, " ", head.reason)
    write(io, "\r\n")
    _write_verbose_headers!(io, head.headers)
    write(io, "\r\n")
    body_bytes = exchange.response_capture.bytes
    write(io, _render_body_for_verbose(body_bytes, exchange.response_capture.total, head.headers))
    if !isempty(head.trailers)
        write(io, "\r\n")
        _write_verbose_headers!(io, head.trailers)
    end
    write(io, _render_capture_suffix(exchange.response_capture))
    return String(take!(io))
end

function _format_verbose_request(exchange::_VerboseExchangeState)::String
    if exchange.protocol == :h1
        return _format_h1_raw_message(exchange.request_capture, exchange.request.headers)
    end
    return _format_h2_request(exchange)
end

function _format_verbose_response(exchange::_VerboseExchangeState)::String
    if exchange.protocol == :h1
        headers = exchange.response_head === nothing ? nothing : (exchange.response_head::_IncomingResponseHead).headers
        return _format_h1_raw_message(exchange.response_capture, headers)
    end
    return _format_h2_response(exchange)
end

function _verbose_log_request_dump!(exchange::_VerboseExchangeState)::Nothing
    was_logged = @atomic :acquire exchange.request_logged
    was_logged && return nothing
    @atomic :release exchange.request_logged = true
    _verbose_block!(exchange.config, 2, string("request dump (", exchange.protocol, ", attempt ", exchange.attempt, ")"), _format_verbose_request(exchange))
    return nothing
end

function _verbose_log_response_dump!(exchange::_VerboseExchangeState; complete::Bool)::Nothing
    was_logged = @atomic :acquire exchange.response_logged
    was_logged && return nothing
    @atomic :release exchange.response_complete = complete
    _verbose_log_request_dump!(exchange)
    @atomic :release exchange.response_logged = true
    label = string("response dump (", exchange.protocol, ", attempt ", exchange.attempt, complete ? ")" : ", incomplete)")
    _verbose_block!(exchange.config, 2, label, _format_verbose_response(exchange))
    return nothing
end

function _attach_verbose_to_incoming_response(
    incoming::_IncomingResponse{B},
    exchange::Union{Nothing,_VerboseExchangeState};
    capture_body::Bool,
) where {B<:AbstractBody}
    exchange === nothing && return incoming
    _set_verbose_response_head!(exchange, incoming.head)
    if incoming.rawbody isa EmptyBody
        _verbose_log_response_dump!(exchange; complete=true)
        return incoming
    end
    wrapped = _VerboseResponseBodyCapture(
        incoming.rawbody,
        capture_body ? exchange.response_capture : nothing,
        complete -> _verbose_log_response_dump!(exchange; complete=complete),
        false,
    )
    return _IncomingResponse(incoming.head, wrapped)
end

function _verbose_finish_response_capture!(body::_VerboseResponseBodyCapture; complete::Bool)::Nothing
    was_finished = @atomic :acquire body.finished
    was_finished && return nothing
    @atomic :release body.finished = true
    body.on_finish(complete)
    return nothing
end

function Base.write(io::_VerboseTeeWriteIO, b::UInt8)::Int
    n = write(io.inner, b)
    n == 1 && _verbose_capture!(io.capture, b)
    return n
end

function _verbose_tee_write_bytes!(io::_VerboseTeeWriteIO, data::AbstractVector{UInt8})::Int
    n = write(io.inner, data)
    n > 0 && _verbose_capture!(io.capture, view(data, 1:n))
    return n
end

Base.write(io::_VerboseTeeWriteIO, data::StridedVector{UInt8})::Int = _verbose_tee_write_bytes!(io, data)
Base.write(io::_VerboseTeeWriteIO, data::AbstractVector{UInt8})::Int = _verbose_tee_write_bytes!(io, data)

function Base.write(io::_VerboseTeeWriteIO, data::Union{String,SubString{String}})::Int
    n = write(io.inner, data)
    if n > 0
        bytes = codeunits(String(data))
        _verbose_capture!(io.capture, view(bytes, 1:n))
    end
    return n
end

function body_closed(body::_VerboseRequestBody)::Bool
    return body_closed(body.inner)
end

function body_read!(body::_VerboseRequestBody, dst::Vector{UInt8})::Int
    n = body_read!(body.inner, dst)
    n > 0 && _verbose_capture!(body.capture, view(dst, 1:n))
    return n
end

function body_close!(body::_VerboseRequestBody)
    body_close!(body.inner)
    return nothing
end

function body_closed(body::_VerboseResponseBodyCapture)::Bool
    return body_closed(body.inner)
end

function body_read!(body::_VerboseResponseBodyCapture, dst::Vector{UInt8})::Int
    n = body_read!(body.inner, dst)
    if n > 0
        capture = body.capture
        capture === nothing || _verbose_capture!(capture::_VerboseCaptureBuffer, view(dst, 1:n))
        return n
    end
    _verbose_finish_response_capture!(body; complete=true)
    return 0
end

function body_close!(body::_VerboseResponseBodyCapture)
    try
        body_close!(body.inner)
    finally
        _verbose_finish_response_capture!(body; complete=false)
    end
    return nothing
end
