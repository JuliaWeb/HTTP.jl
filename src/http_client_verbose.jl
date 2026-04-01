# Internal client-side verbose logging, capture, and formatting helpers.

const _VERBOSE_H1_CAPTURE_HEADROOM_BYTES = 256 * 1024

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

function _verbose_config(verbose=false, verbose_body_nbytes::Integer=_VERBOSE_DEFAULT_BODY_NBYTES, verbose_io::IO=stderr)::_VerboseConfig
    level = _normalize_verbose_level(verbose)
    return _VerboseConfig(level, _normalize_verbose_body_nbytes(verbose_body_nbytes), verbose_io)
end

@inline function _request_context_verbose_config(ctx::RequestContext)::_VerboseConfig
    return ctx.verbose_config
end

@inline function _set_request_context_verbose_config!(ctx::RequestContext, config::_VerboseConfig)::Nothing
    ctx.verbose_config = config
    ctx.verbose_exchange_state = _VerboseExchangeState(config)
    return nothing
end

@inline function _request_context_verbose_exchange(ctx::RequestContext)::Union{Nothing,_VerboseExchangeState}
    exchange = ctx.verbose_exchange_state
    return exchange.active ? exchange : nothing
end

@inline function _set_request_context_verbose_exchange!(ctx::RequestContext, exchange::Union{Nothing,_VerboseExchangeState})::Nothing
    ctx.verbose_exchange_state = exchange === nothing ? _VerboseExchangeState(ctx.verbose_config) : exchange
    return nothing
end

@inline function _verbose_enabled(config::_VerboseConfig, level::Integer=1)::Bool
    return config.level >= level
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
        true,
        protocol,
        Int(attempt),
        Int(redirect_count),
        String(url),
        request.method,
        request.target,
        request.host,
        request.headers,
        request.proto_major,
        request.proto_minor,
        0,
        "",
        Headers(),
        Headers(),
        UInt8(1),
        UInt8(1),
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
    if !_verbose_enabled(config, 2)
        _set_request_context_verbose_exchange!(request.context, nothing)
        return nothing
    end
    exchange = _new_verbose_exchange(config, protocol, attempt, redirect_count, url, request)
    _set_request_context_verbose_exchange!(request.context, exchange)
    return exchange
end

@inline function _set_verbose_response_head!(exchange::Union{Nothing,_VerboseExchangeState}, head::_IncomingResponseHead)::Nothing
    exchange === nothing && return nothing
    exchange.response_status = head.status
    exchange.response_reason = head.reason
    exchange.response_headers = head.headers
    exchange.response_trailers = head.trailers
    exchange.response_proto_major = head.proto_major
    exchange.response_proto_minor = head.proto_minor
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

function _verbose_line!(config::_VerboseConfig, level::Integer, message::AbstractString)::Nothing
    _verbose_enabled(config, level) || return nothing
    io = config.io
    println(io, "[http] ", message)
    flush(io)
    return nothing
end

function _verbose_block!(config::_VerboseConfig, level::Integer, label::AbstractString, body::AbstractString)::Nothing
    _verbose_enabled(config, level) || return nothing
    io = config.io
    println(io, "[http] ", label)
    if !isempty(body)
        write(io, body)
        endswith(body, "\n") || write(io, '\n')
    end
    flush(io)
    return nothing
end

const _HTTP_REDACTED_HEADERS = Set([
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
])

const _VERBOSE_MASKED_HEADERS = _HTTP_REDACTED_HEADERS

@inline function _http_render_header_value(name::AbstractString, value::AbstractString)::String
    return lowercase(String(name)) in _HTTP_REDACTED_HEADERS ? "******" : String(value)
end

@inline function _verbose_header_value(name::AbstractString, value::AbstractString)::String
    return _http_render_header_value(name, value)
end

function _verbose_request_summary(request::Request, url::AbstractString)::String
    return string(request.method, " ", url)
end

@inline function _http_proto_string(proto_major::Integer, proto_minor::Integer)::String
    if proto_major == 2
        return "HTTP/2"
    end
    return string("HTTP/", Int(proto_major), ".", Int(proto_minor))
end

function _verbose_response_summary(head::_IncomingResponseHead)::String
    proto = _http_proto_string(head.proto_major, head.proto_minor)
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
)::Tuple{String,Bool}
    body_total == 0 && return "", false
    encoding = _body_content_encoding(headers)
    if encoding !== nothing
        return string("<", encoding::String, "-compressed ", body_total, "-byte body omitted>"), false
    end
    text = _render_textual_bytes(body_bytes)
    return text === nothing ? (_render_binary_note(body_total), false) : (text, true)
end

function _render_capture_suffix(capture::_VerboseCaptureBuffer)::String
    capture.truncated || return ""
    return string("\n[truncated after ", length(capture.bytes), " of ", capture.total, " bytes]")
end

@inline function _render_truncation_suffix(rendered::Int, total::Int64)::String
    rendered >= total && return ""
    return string("\n[truncated after ", rendered, " of ", total, " bytes]")
end

@inline function _http_body_total_hint(body, fallback::Int64)::Int64
    body === nothing && return Int64(0)
    body isa AbstractString && return Int64(ncodeunits(body::AbstractString))
    body isa AbstractVector{UInt8} && return Int64(length(body::AbstractVector{UInt8}))
    body isa EmptyBody && return Int64(0)
    body isa BytesBody && return Int64(length(_remaining_bytes_body(body::BytesBody)))
    fallback >= 0 && return fallback
    return Int64(0)
end

function _http_omitted_body_note(kind::AbstractString, total::Int64, headers::Union{Nothing,Headers})::String
    encoding = _body_content_encoding(headers)
    if encoding !== nothing
        return total > 0 ? string("<", encoding::String, "-compressed ", total, "-byte body omitted>") :
                           string("<", encoding::String, "-compressed body omitted>")
    end
    return total > 0 ? string("<", total, "-byte ", kind, " omitted>") : string("<", kind, " omitted>")
end

function _http_collect_body_bytes(body, fallback::Int64, limit::Int)
    body === nothing && return UInt8[], Int64(0), false, nothing
    if body isa AbstractString
        bytes = collect(codeunits(String(body::AbstractString)))
        total = Int64(length(bytes))
        shown = min(length(bytes), limit)
        return bytes[1:shown], total, shown < length(bytes), nothing
    end
    if body isa AbstractVector{UInt8}
        bytes = body::AbstractVector{UInt8}
        total = Int64(length(bytes))
        shown = min(length(bytes), limit)
        return collect(view(bytes, 1:shown)), total, shown < length(bytes), nothing
    end
    if body isa EmptyBody
        return UInt8[], Int64(0), false, nothing
    end
    if body isa BytesBody
        bytes = _remaining_bytes_body(body::BytesBody)
        total = Int64(length(bytes))
        shown = min(length(bytes), limit)
        return bytes[1:shown], total, shown < length(bytes), nothing
    end
    if body isa CallbackBody
        total = _http_body_total_hint(body, fallback)
        return UInt8[], total, false, _http_omitted_body_note("streaming body", total, nothing)
    end
    if body isa AbstractBody
        total = _http_body_total_hint(body, fallback)
        return UInt8[], total, false, _http_omitted_body_note("streaming body", total, nothing)
    end
    total = _http_body_total_hint(body, fallback)
    return UInt8[], total, false, _http_omitted_body_note(string(typeof(body), " body"), total, nothing)
end

function _render_message_body(
    body,
    content_length::Int64,
    headers::Union{Nothing,Headers};
    body_limit::Int,
)::String
    bytes, total, truncated, note = _http_collect_body_bytes(body, content_length, body_limit)
    note === nothing || return note
    rendered, previewed = _render_body_for_verbose(bytes, total, headers)
    if isempty(rendered) && total > 0
        rendered = _http_omitted_body_note("body", total, headers)
        previewed = false
    end
    return string(rendered, truncated && previewed ? _render_truncation_suffix(length(bytes), total) : "")
end

function _write_message_headers!(io::IO, headers::Headers, host::Union{Nothing,String}=nothing)::Nothing
    wrote_any = false
    if host !== nothing && !hasheader(headers, "Host")
        print(io, "Host: ", _http_render_header_value("Host", host::String))
        wrote_any = true
    end
    for (key, value) in headers
        key == "Host" && host !== nothing && continue
        wrote_any && write(io, "\r\n")
        print(io, key, ": ", _http_render_header_value(key, value))
        wrote_any = true
    end
    return nothing
end

@inline function _count_label(count::Integer, noun::AbstractString)::String
    count == 1 && return string(count, " ", noun)
    return string(count, " ", noun, "s")
end

function _body_summary_label(body, content_length::Int64)::String
    body === nothing && return "no body"
    total = _http_body_total_hint(body, content_length)
    if body isa EmptyBody
        return "no body"
    elseif body isa AbstractBody && !(body isa BytesBody)
        return total > 0 ? string(total, "-byte streaming body") : "streaming body"
    elseif body isa AbstractBody || body isa AbstractVector{UInt8} || body isa AbstractString
        return total == 0 ? "empty body" : string(total, "-byte body")
    end
    return total > 0 ? string(total, "-byte body") : string(typeof(body), " body")
end

@inline function _request_summary_target(request::Request)::String
    request.host === nothing || return string(request.host::String, request.target)
    return request.target
end

function Base.summary(io::IO, request::Request)
    print(io, "HTTP.Request ", request.method, " ", _request_summary_target(request))
end

function Base.summary(io::IO, response::Response)
    reason = isempty(response.reason) ? "" : string(" ", response.reason)
    print(io, "HTTP.Response ", response.status, reason)
end

function Base.show(io::IO, request::Request)
    print(io, "Request(")
    summary(io, request)
    print(io, ", ", _count_label(length(request.headers), "header"), ", ", _body_summary_label(request.body, request.content_length), ")")
end

function Base.show(io::IO, response::Response)
    print(io, "Response(")
    summary(io, response)
    print(io, ", ", _count_label(length(response.headers), "header"), ", ", _body_summary_label(response.body, response.content_length), ")")
end

function _show_request_message(io::IO, request::Request, body_limit::Int)::Nothing
    print(io, request.method, " ", request.target, " ", _http_proto_string(request.proto_major, request.proto_minor), "\r\n")
    _write_message_headers!(io, request.headers, request.host)
    body = _render_message_body(request.body, request.content_length, request.headers; body_limit=body_limit)
    if !isempty(body) || !isempty(request.trailers)
        write(io, "\r\n\r\n")
        isempty(body) || write(io, body)
    end
    if !isempty(request.trailers)
        isempty(body) || write(io, "\r\n")
        _write_message_headers!(io, request.trailers)
    end
    return nothing
end

function _show_response_message(io::IO, response::Response, body_limit::Int)::Nothing
    print(io, _http_proto_string(response.proto_major, response.proto_minor), " ", response.status)
    isempty(response.reason) || print(io, " ", response.reason)
    write(io, "\r\n")
    _write_message_headers!(io, response.headers)
    body = _render_message_body(response.body, response.content_length, response.headers; body_limit=body_limit)
    if !isempty(body) || !isempty(response.trailers)
        write(io, "\r\n\r\n")
        isempty(body) || write(io, body)
    end
    if !isempty(response.trailers)
        isempty(body) || write(io, "\r\n")
        _write_message_headers!(io, response.trailers)
    end
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", request::Request)
    get(io, :compact, false)::Bool && return show(io, request)
    return _show_request_message(io, request, _VERBOSE_DEFAULT_BODY_NBYTES)
end

function Base.show(io::IO, ::MIME"text/plain", response::Response)
    get(io, :compact, false)::Bool && return show(io, response)
    return _show_response_message(io, response, _VERBOSE_DEFAULT_BODY_NBYTES)
end

function Base.print(io::IO, request::Request)
    return _show_request_message(io, request, typemax(Int))
end

function Base.print(io::IO, response::Response)
    return _show_response_message(io, response, typemax(Int))
end

function _format_h1_raw_message(capture::_VerboseCaptureBuffer, headers::Union{Nothing,Headers}=nothing)::String
    bytes = capture.bytes
    boundary = _find_double_crlf(bytes)
    if boundary === nothing
        rendered, previewed = _render_body_for_verbose(bytes, capture.total, headers)
        return string(rendered, previewed ? _render_capture_suffix(capture) : "")
    end
    header_text = String(copy(view(bytes, 1:(boundary - 1))))
    body_bytes = boundary > length(bytes) ? UInt8[] : collect(view(bytes, boundary:length(bytes)))
    body_total = max(capture.total - Int64(boundary - 1), Int64(0))
    rendered_body, previewed = _render_body_for_verbose(body_bytes, body_total, headers)
    return string(header_text, rendered_body, previewed ? _render_capture_suffix(capture) : "")
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
    io = IOBuffer()
    print(io, exchange.request_method, " ", exchange.request_target, " HTTP/2\r\n")
    exchange.request_host === nothing || print(io, "Host: ", exchange.request_host::String, "\r\n")
    _write_verbose_headers!(io, exchange.request_headers)
    write(io, "\r\n")
    body_bytes = exchange.request_capture.bytes
    rendered_body, previewed = _render_body_for_verbose(body_bytes, exchange.request_capture.total, exchange.request_headers)
    write(io, rendered_body)
    previewed && write(io, _render_capture_suffix(exchange.request_capture))
    return String(take!(io))
end

function _format_h2_response(exchange::_VerboseExchangeState)::String
    io = IOBuffer()
    print(io, "HTTP/2 ", exchange.response_status)
    isempty(exchange.response_reason) || print(io, " ", exchange.response_reason)
    write(io, "\r\n")
    _write_verbose_headers!(io, exchange.response_headers)
    write(io, "\r\n")
    body_bytes = exchange.response_capture.bytes
    rendered_body, previewed = _render_body_for_verbose(body_bytes, exchange.response_capture.total, exchange.response_headers)
    write(io, rendered_body)
    if !isempty(exchange.response_trailers)
        write(io, "\r\n")
        _write_verbose_headers!(io, exchange.response_trailers)
    end
    previewed && write(io, _render_capture_suffix(exchange.response_capture))
    return String(take!(io))
end

function _format_verbose_request(exchange::_VerboseExchangeState)::String
    if exchange.protocol == :h1
        return _format_h1_raw_message(exchange.request_capture, exchange.request_headers)
    end
    return _format_h2_request(exchange)
end

function _format_verbose_response(exchange::_VerboseExchangeState)::String
    if exchange.protocol == :h1
        headers = isempty(exchange.response_headers) ? nothing : exchange.response_headers
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

function _verbose_log_response_dump!(exchange::_VerboseExchangeState, complete::Bool)::Nothing
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
    exchange::Union{Nothing,_VerboseExchangeState},
    capture_body::Bool,
) where {B<:AbstractBody}
    exchange === nothing && return incoming
    _set_verbose_response_head!(exchange, incoming.head)
    if _body_immediately_empty(incoming.rawbody)
        _verbose_log_response_dump!(exchange, true)
        return incoming
    end
    wrapped = _VerboseResponseBodyCapture(
        incoming.rawbody,
        capture_body ? exchange.response_capture : nothing,
        complete -> _verbose_log_response_dump!(exchange, complete),
        false,
    )
    return _IncomingResponse(incoming.head, wrapped)
end

function _verbose_finish_response_capture!(body::_VerboseResponseBodyCapture, complete::Bool)::Nothing
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
    _verbose_finish_response_capture!(body, true)
    return 0
end

function body_close!(body::_VerboseResponseBodyCapture)
    try
        body_close!(body.inner)
    finally
        _verbose_finish_response_capture!(body, false)
    end
    return nothing
end
