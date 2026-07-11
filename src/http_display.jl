# Request/response summaries and human-readable rendering helpers.

const _DEFAULT_MESSAGE_SHOW_BODY_NBYTES = 1000

const _HTTP_REDACTED_HEADERS = Set([
    "authorization",
    "proxy-authorization",
    "cookie",
    "set-cookie",
])

@inline function _http_render_header_value(name::AbstractString, value::AbstractString)::String
    return lowercase(String(name)) in _HTTP_REDACTED_HEADERS ? "******" : String(value)
end

@inline function _http_proto_string(major::Integer, minor::Integer)::String
    return string("HTTP/", Int(major), ".", Int(minor))
end

function _render_textual_bytes(bytes::AbstractVector{UInt8})::Union{Nothing,String}
    isempty(bytes) && return ""
    try
        return String(copy(bytes))
    catch
        return nothing
    end
end

function _escape_terminal_control_chars(text::AbstractString)::String
    out = IOBuffer()
    changed = false
    for c in text
        code = UInt32(c)
        if c == '\n'
            write(out, "\\n")
            changed = true
        elseif c == '\r'
            write(out, "\\r")
            changed = true
        elseif c == '\t'
            write(out, "\\t")
            changed = true
        elseif c == '\e'
            write(out, "\\e")
            changed = true
        elseif code <= 0x1f || 0x7f <= code <= 0x9f
            if code <= 0xff
                write(out, "\\x", uppercase(lpad(string(code, base=16), 2, '0')))
            else
                write(out, "\\u{", string(code, base=16), "}")
            end
            changed = true
        else
            print(out, c)
        end
    end
    return changed ? String(take!(out)) : String(text)
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

function _render_message_body_preview(
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
    return text === nothing ? (_render_binary_note(body_total), false) : (_escape_terminal_control_chars(text), true)
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
    rendered, previewed = _render_message_body_preview(bytes, total, headers)
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

function _show_redacted_header_pair(io::IO, key::String, value::String)::Nothing
    show(io, key)
    print(io, " => ")
    show(io, _http_render_header_value(key, value))
    return nothing
end

function Base.show(io::IO, headers::Headers)
    print(io, "HTTP.Headers([")
    for (i, (key, value)) in enumerate(headers)
        i > 1 && print(io, ", ")
        _show_redacted_header_pair(io, key, value)
    end
    print(io, "])")
end

function Base.show(io::IO, ::MIME"text/plain", headers::Headers)
    summary(io, headers)
    isempty(headers) && return
    print(io, ":")
    key_width = maximum(length(repr(key)) for (key, _) in headers)
    for (key, value) in headers
        print(io, "\n ", lpad(repr(key), key_width), " => ")
        show(io, _http_render_header_value(key, value))
    end
    return
end

@inline function _request_summary_target(request::Request)::String
    request.host === nothing || return string(request.host::String, request.target)
    return request.target
end

function Base.summary(io::IO, request::Request)
    print(io, "HTTP.Request ", request.method, " ", _request_summary_target(request))
end

function Base.summary(io::IO, response::Response)
    reason = isempty(response.reason) ? "" : string(" ", _escape_terminal_control_chars(response.reason))
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
    isempty(response.reason) || print(io, " ", _escape_terminal_control_chars(response.reason))
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
    return _show_request_message(io, request, _DEFAULT_MESSAGE_SHOW_BODY_NBYTES)
end

function Base.show(io::IO, ::MIME"text/plain", response::Response)
    get(io, :compact, false)::Bool && return show(io, response)
    return _show_response_message(io, response, _DEFAULT_MESSAGE_SHOW_BODY_NBYTES)
end

function Base.print(io::IO, request::Request)
    return _show_request_message(io, request, typemax(Int))
end

function Base.print(io::IO, response::Response)
    return _show_response_message(io, response, typemax(Int))
end
