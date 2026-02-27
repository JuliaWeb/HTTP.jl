# HTTP Request/Response - Headers and Messages
# Port of aws-c-http/include/aws/http/request_response.h, request_response.c

# ─── Header compression (HPACK cache control) ───

@enumx HttpHeaderCompression::UInt8 begin
    USE_CACHE = 0
    NO_CACHE = 1
    NO_FORWARD_CACHE = 2
end

# ─── Header block type ───

@enumx HttpHeaderBlock::UInt8 begin
    MAIN = 0
    INFORMATIONAL = 1
    TRAILING = 2
end

# ─── HTTP header struct ───

struct HttpHeader
    name::String
    value::String
    compression::HttpHeaderCompression.T
end

HttpHeader(name::AbstractString, value::AbstractString) =
    HttpHeader(String(name), String(value), HttpHeaderCompression.USE_CACHE)

# ─── Utility functions ───

"""
    is_pseudo_header_name(name::AbstractString) -> Bool

Check if a header name is an HTTP/2 pseudo-header (starts with ':').
"""
is_pseudo_header_name(name::AbstractString)::Bool = !isempty(name) && name[1] == ':'

"""
    http_header_name_eq(a::AbstractString, b::AbstractString) -> Bool

Case-insensitive header name comparison.
"""
http_header_name_eq(a::AbstractString, b::AbstractString)::Bool = lowercase(a) == lowercase(b)

"""
    trim_http_whitespace(s::AbstractString) -> String

Trim HTTP optional whitespace (SP, HTAB) from both ends per RFC 7230 §3.2.
"""
trim_http_whitespace(s::AbstractString)::String = String(strip(c -> c == ' ' || c == '\t', s))

# ─── HttpHeaders (header collection) ───

const _HTTP_REQUEST_NUM_RESERVED_HEADERS = 16

mutable struct HttpHeaders
    headers::Vector{HttpHeader}
end

"""
    http_headers_new() -> HttpHeaders

Create a new empty header collection.
"""
function http_headers_new()::HttpHeaders
    return HttpHeaders(sizehint!(HttpHeader[], _HTTP_REQUEST_NUM_RESERVED_HEADERS))
end

"""
    http_headers_count(headers::HttpHeaders) -> Int

Return the number of headers in the collection.
"""
http_headers_count(headers::HttpHeaders)::Int = length(headers.headers)

# Internal: add header with optional front-insertion
function _http_headers_add_impl(headers::HttpHeaders, header::HttpHeader, front::Bool)::Int
    if isempty(header.name)
        return raise_error(ERROR_HTTP_INVALID_HEADER_NAME)
    end

    # Trim HTTP whitespace from value (RFC 7230 §3.2)
    stored = HttpHeader(String(header.name), trim_http_whitespace(header.value), header.compression)

    if front
        pushfirst!(headers.headers, stored)
    else
        push!(headers.headers, stored)
    end

    return OP_SUCCESS
end

"""
    http_headers_add_header(headers::HttpHeaders, header::HttpHeader) -> Int

Add a header. Pseudo-headers (starting with ':') are inserted at the front
when the collection already contains non-pseudo headers at the end.
"""
function http_headers_add_header(headers::HttpHeaders, header::HttpHeader)::Int
    pseudo = is_pseudo_header_name(header.name)
    front = false
    if pseudo && !isempty(headers.headers)
        front = !is_pseudo_header_name(headers.headers[end].name)
    end
    return _http_headers_add_impl(headers, header, front)
end

"""
    http_headers_add(headers, name, value) -> Int

Add a header by name and value strings.
"""
function http_headers_add(headers::HttpHeaders, name::AbstractString, value::AbstractString)::Int
    return http_headers_add_header(headers, HttpHeader(name, value))
end

"""
    http_headers_add_array(headers, array) -> Int

Add an array of headers. On failure, rolls back partially added headers.
"""
function http_headers_add_array(headers::HttpHeaders, array::AbstractVector{HttpHeader})::Int
    orig_count = http_headers_count(headers)
    for h in array
        if http_headers_add_header(headers, h) != OP_SUCCESS
            # Roll back (removes from end, matching C behavior)
            resize!(headers.headers, orig_count)
            return OP_ERR
        end
    end
    return OP_SUCCESS
end

# Internal: erase headers matching name in 1-indexed range [start_idx, end_idx]
function _http_headers_erase_range(headers::HttpHeaders, name::AbstractString, start_idx::Int, end_idx::Int)::Bool
    erased_any = false
    # Iterate in reverse to avoid index shifting issues
    for i in min(end_idx, length(headers.headers)):-1:max(start_idx, 1)
        if http_header_name_eq(headers.headers[i].name, name)
            deleteat!(headers.headers, i)
            erased_any = true
        end
    end
    return erased_any
end

"""
    http_headers_set(headers, name, value) -> Int

Set a header value (add new + remove existing with same name).
"""
function http_headers_set(headers::HttpHeaders, name::AbstractString, value::AbstractString)::Int
    prev_count = http_headers_count(headers)
    pseudo = is_pseudo_header_name(name)
    header = HttpHeader(name, value)

    if _http_headers_add_impl(headers, header, pseudo) != OP_SUCCESS
        return OP_ERR
    end

    # Erase pre-existing headers AFTER add (C does this to handle self-referencing cursors).
    # For pseudo (front-inserted), skip new header at index 1.
    start = pseudo ? 2 : 1
    _http_headers_erase_range(headers, name, start, prev_count)

    return OP_SUCCESS
end

"""
    http_headers_get_index(headers, index) -> Union{HttpHeader, Nothing}

Get the header at a 0-based index. Returns `nothing` on invalid index.
"""
function http_headers_get_index(headers::HttpHeaders, index::Int)::Union{HttpHeader, Nothing}
    if index < 0 || index >= http_headers_count(headers)
        raise_error(ERROR_INVALID_INDEX)
        return nothing
    end
    return headers.headers[index + 1]
end

"""
    http_headers_get(headers, name) -> Union{String, Nothing}

Get the value of the first header matching name (case-insensitive).
"""
function http_headers_get(headers::HttpHeaders, name::AbstractString)::Union{String, Nothing}
    for h in headers.headers
        if http_header_name_eq(h.name, name)
            return h.value
        end
    end
    raise_error(ERROR_HTTP_HEADER_NOT_FOUND)
    return nothing
end

"""
    http_headers_get_all(headers, name) -> Union{String, Nothing}

Get all values for headers matching name, joined with ", " (RFC 9110 §5.3).
"""
function http_headers_get_all(headers::HttpHeaders, name::AbstractString)::Union{String, Nothing}
    parts = String[]
    for h in headers.headers
        if http_header_name_eq(h.name, name)
            push!(parts, h.value)
        end
    end
    if isempty(parts)
        raise_error(ERROR_HTTP_HEADER_NOT_FOUND)
        return nothing
    end
    return join(parts, ", ")
end

"""
    http_headers_has(headers, name) -> Bool

Check if any header with the given name exists (case-insensitive).
"""
function http_headers_has(headers::HttpHeaders, name::AbstractString)::Bool
    return http_headers_get(headers, name) !== nothing
end

"""
    http_headers_erase(headers, name) -> Int

Remove all headers with the given name (case-insensitive).
"""
function http_headers_erase(headers::HttpHeaders, name::AbstractString)::Int
    if !_http_headers_erase_range(headers, name, 1, http_headers_count(headers))
        return raise_error(ERROR_HTTP_HEADER_NOT_FOUND)
    end
    return OP_SUCCESS
end

"""
    http_headers_erase_value(headers, name, value) -> Int

Remove the first header with matching name (case-insensitive) and exact value.
"""
function http_headers_erase_value(headers::HttpHeaders, name::AbstractString, value::AbstractString)::Int
    for (i, h) in enumerate(headers.headers)
        if http_header_name_eq(h.name, name) && h.value == value
            deleteat!(headers.headers, i)
            return OP_SUCCESS
        end
    end
    return raise_error(ERROR_HTTP_HEADER_NOT_FOUND)
end

"""
    http_headers_erase_index(headers, index) -> Int

Remove the header at the given 0-based index.
"""
function http_headers_erase_index(headers::HttpHeaders, index::Int)::Int
    if index < 0 || index >= http_headers_count(headers)
        return raise_error(ERROR_INVALID_INDEX)
    end
    deleteat!(headers.headers, index + 1)
    return OP_SUCCESS
end

"""
    http_headers_clear(headers)

Remove all headers.
"""
function http_headers_clear(headers::HttpHeaders)
    empty!(headers.headers)
    return nothing
end

# ─── HTTP/2 pseudo-header accessors ───

function http2_headers_get_request_method(headers::HttpHeaders)::Union{String, Nothing}
    return http_headers_get(headers, HTTP_HEADER_METHOD_STR)
end

function http2_headers_set_request_method(headers::HttpHeaders, method::AbstractString)::Int
    return http_headers_set(headers, HTTP_HEADER_METHOD_STR, method)
end

function http2_headers_get_request_scheme(headers::HttpHeaders)::Union{String, Nothing}
    return http_headers_get(headers, HTTP_HEADER_SCHEME_STR)
end

function http2_headers_set_request_scheme(headers::HttpHeaders, scheme::AbstractString)::Int
    return http_headers_set(headers, HTTP_HEADER_SCHEME_STR, scheme)
end

function http2_headers_get_request_authority(headers::HttpHeaders)::Union{String, Nothing}
    return http_headers_get(headers, HTTP_HEADER_AUTHORITY_STR)
end

function http2_headers_set_request_authority(headers::HttpHeaders, authority::AbstractString)::Int
    return http_headers_set(headers, HTTP_HEADER_AUTHORITY_STR, authority)
end

function http2_headers_get_request_path(headers::HttpHeaders)::Union{String, Nothing}
    return http_headers_get(headers, HTTP_HEADER_PATH_STR)
end

function http2_headers_set_request_path(headers::HttpHeaders, path::AbstractString)::Int
    return http_headers_set(headers, HTTP_HEADER_PATH_STR, path)
end

function http2_headers_get_response_status(headers::HttpHeaders)::Union{Int, Nothing}
    val = http_headers_get(headers, HTTP_HEADER_STATUS_STR)
    val === nothing && return nothing
    code = tryparse(Int, val)
    code === nothing && return nothing
    return code
end

function http2_headers_set_response_status(headers::HttpHeaders, status_code::Int)::Int
    if status_code < 0 || status_code > 999
        return raise_error(ERROR_INVALID_ARGUMENT)
    end
    status = if status_code < 10
        "00$(status_code)"
    elseif status_code < 100
        "0$(status_code)"
    else
        string(status_code)
    end
    return http_headers_set(headers, HTTP_HEADER_STATUS_STR, status)
end

# ─── Http2PrioritySettings ───

struct Http2PrioritySettings
    stream_dependency::UInt32
    stream_dependency_exclusive::Bool
    weight::UInt16
end

Http2PrioritySettings() = Http2PrioritySettings(UInt32(0), false, UInt16(16))

# ─── HttpStreamMetrics ───

struct HttpStreamMetrics
    send_start_timestamp_ns::Int64
    send_end_timestamp_ns::Int64
    sending_duration_ns::Int64
    receive_start_timestamp_ns::Int64
    receive_end_timestamp_ns::Int64
    receiving_duration_ns::Int64
    stream_id::UInt32
end

HttpStreamMetrics() = HttpStreamMetrics(Int64(-1), Int64(-1), Int64(-1), Int64(-1), Int64(-1), Int64(-1), UInt32(0))

# ─── HttpMessage (request/response) ───

const HttpBodyStream = Union{Nothing, IO, Sockets.AbstractInputStream}

mutable struct HttpMessage
    headers::HttpHeaders
    body_stream::HttpBodyStream
    http_version::HttpVersion.T
    is_request::Bool
    # Request fields (valid when is_request == true; empty string = not set)
    method::String
    path::String
    # Response field (valid when is_request == false; HTTP_STATUS_CODE_UNKNOWN = not set)
    status::Int
end

# Internal constructors

function _message_new_request(existing_headers::Union{HttpHeaders, Nothing}, version::HttpVersion.T)::HttpMessage
    hdrs = existing_headers !== nothing ? existing_headers : http_headers_new()
    return HttpMessage(hdrs, nothing, version, true, "", "", HTTP_STATUS_CODE_UNKNOWN)
end

function _message_new_response(version::HttpVersion.T)::HttpMessage
    return HttpMessage(http_headers_new(), nothing, version, false, "", "", HTTP_STATUS_CODE_UNKNOWN)
end

"""
    http_message_new_request() -> HttpMessage

Create a blank HTTP/1.1 request message.
"""
http_message_new_request() = _message_new_request(nothing, HttpVersion.HTTP_1_1)

"""
    http_message_new_request_with_headers(headers::HttpHeaders) -> HttpMessage

Create an HTTP/1.1 request message with existing headers.
"""
http_message_new_request_with_headers(headers::HttpHeaders) = _message_new_request(headers, HttpVersion.HTTP_1_1)

"""
    http_message_new_response() -> HttpMessage

Create a blank HTTP/1.1 response message.
"""
http_message_new_response() = _message_new_response(HttpVersion.HTTP_1_1)

"""
    http2_message_new_request() -> HttpMessage

Create a blank HTTP/2 request message.
"""
http2_message_new_request() = _message_new_request(nothing, HttpVersion.HTTP_2)

"""
    http2_message_new_response() -> HttpMessage

Create a blank HTTP/2 response message.
"""
http2_message_new_response() = _message_new_response(HttpVersion.HTTP_2)

http_message_is_request(message::HttpMessage)::Bool = message.is_request
http_message_is_response(message::HttpMessage)::Bool = !message.is_request
http_message_get_protocol_version(message::HttpMessage)::HttpVersion.T = message.http_version

# ─── Request method accessors ───

function http_message_set_request_method(message::HttpMessage, method::AbstractString)::Int
    if !message.is_request
        return raise_error(ERROR_INVALID_STATE)
    end
    if message.http_version == HttpVersion.HTTP_1_1
        message.method = isempty(method) ? "" : String(method)
        return OP_SUCCESS
    elseif message.http_version == HttpVersion.HTTP_2
        return http2_headers_set_request_method(message.headers, method)
    else
        return raise_error(ERROR_UNIMPLEMENTED)
    end
end

function http_message_get_request_method(message::HttpMessage)::Union{String, Nothing}
    if !message.is_request
        raise_error(ERROR_HTTP_DATA_NOT_AVAILABLE)
        return nothing
    end
    if message.http_version == HttpVersion.HTTP_1_1
        if !isempty(message.method)
            return message.method
        end
        raise_error(ERROR_HTTP_DATA_NOT_AVAILABLE)
        return nothing
    elseif message.http_version == HttpVersion.HTTP_2
        return http2_headers_get_request_method(message.headers)
    else
        raise_error(ERROR_UNIMPLEMENTED)
        return nothing
    end
end

# ─── Request path accessors ───

function http_message_set_request_path(message::HttpMessage, path::AbstractString)::Int
    if !message.is_request
        return raise_error(ERROR_INVALID_STATE)
    end
    if message.http_version == HttpVersion.HTTP_1_1
        message.path = isempty(path) ? "" : String(path)
        return OP_SUCCESS
    elseif message.http_version == HttpVersion.HTTP_2
        return http2_headers_set_request_path(message.headers, path)
    else
        return raise_error(ERROR_UNIMPLEMENTED)
    end
end

function http_message_get_request_path(message::HttpMessage)::Union{String, Nothing}
    if !message.is_request
        raise_error(ERROR_HTTP_DATA_NOT_AVAILABLE)
        return nothing
    end
    if message.http_version == HttpVersion.HTTP_1_1
        if !isempty(message.path)
            return message.path
        end
        raise_error(ERROR_HTTP_DATA_NOT_AVAILABLE)
        return nothing
    elseif message.http_version == HttpVersion.HTTP_2
        return http2_headers_get_request_path(message.headers)
    else
        raise_error(ERROR_UNIMPLEMENTED)
        return nothing
    end
end

# ─── Response status accessors ───

function http_message_set_response_status(message::HttpMessage, status_code::Int)::Int
    if message.is_request
        return raise_error(ERROR_INVALID_STATE)
    end
    if status_code < 0 || status_code > 999
        return raise_error(ERROR_HTTP_INVALID_STATUS_CODE)
    end
    if message.http_version == HttpVersion.HTTP_1_1
        message.status = status_code
        return OP_SUCCESS
    elseif message.http_version == HttpVersion.HTTP_2
        return http2_headers_set_response_status(message.headers, status_code)
    else
        return raise_error(ERROR_UNIMPLEMENTED)
    end
end

function http_message_get_response_status(message::HttpMessage)::Union{Int, Nothing}
    if message.is_request
        raise_error(ERROR_HTTP_DATA_NOT_AVAILABLE)
        return nothing
    end
    if message.http_version == HttpVersion.HTTP_1_1
        if message.status != HTTP_STATUS_CODE_UNKNOWN
            return message.status
        end
        raise_error(ERROR_HTTP_DATA_NOT_AVAILABLE)
        return nothing
    elseif message.http_version == HttpVersion.HTTP_2
        return http2_headers_get_response_status(message.headers)
    else
        raise_error(ERROR_UNIMPLEMENTED)
        return nothing
    end
end

# ─── Body stream accessors ───

function _normalize_body_stream(body_stream)
    if body_stream isa AbstractVector{UInt8}
        return IOBuffer(body_stream)
    elseif body_stream isa AbstractString
        return IOBuffer(String(body_stream))
    end
    return body_stream
end

function http_message_set_body_stream(message::HttpMessage, body_stream)
    message.body_stream = _normalize_body_stream(body_stream)
    return nothing
end

http_message_get_body_stream(message::HttpMessage) = message.body_stream

# ─── Header accessors (convenience, delegate to headers) ───

http_message_get_headers(message::HttpMessage)::HttpHeaders = message.headers

function http_message_add_header(message::HttpMessage, header::HttpHeader)::Int
    return http_headers_add(message.headers, header.name, header.value)
end

function http_message_add_header_array(message::HttpMessage, headers_array::AbstractVector{HttpHeader})::Int
    return http_headers_add_array(message.headers, headers_array)
end

function http_message_erase_header(message::HttpMessage, index::Int)::Int
    return http_headers_erase_index(message.headers, index)
end

http_message_get_header_count(message::HttpMessage)::Int = http_headers_count(message.headers)

function http_message_get_header(message::HttpMessage, index::Int)::Union{HttpHeader, Nothing}
    return http_headers_get_index(message.headers, index)
end

# ─── HTTP/1 to HTTP/2 message conversion ───

# Internal helpers for H1→H2 conversion

function _header_value_has_token(value::AbstractString, token::AbstractString)::Bool
    for part in eachsplit(value, ',')
        trimmed = trim_http_whitespace(part)
        if http_header_name_eq(trimmed, token)
            return true
        end
    end
    return false
end

function _te_header_value_is_trailers_only(value::AbstractString)::Bool
    saw_token = false
    for part in eachsplit(value, ',')
        trimmed = trim_http_whitespace(part)
        isempty(trimmed) && return false
        lowercase(trimmed) != "trailers" && return false
        saw_token = true
    end
    return saw_token
end

function _extract_uri_authority(uri::AbstractString)::String
    isempty(uri) && return ""

    start_idx = firstindex(uri)
    colon_idx = findfirst(==(':'), uri)
    if colon_idx !== nothing
        next_idx = nextind(uri, colon_idx)
        if next_idx <= lastindex(uri) && uri[next_idx] == '/'
            next2_idx = nextind(uri, next_idx)
            if next2_idx <= lastindex(uri) && uri[next2_idx] == '/'
                start_idx = nextind(uri, next2_idx)
            else
                return ""
            end
        end
    end

    start_idx > lastindex(uri) && return ""

    slash_idx = findnext(==('/'), uri, start_idx)
    qmark_idx = findnext(==('?'), uri, start_idx)
    end_idx = lastindex(uri)
    if slash_idx !== nothing || qmark_idx !== nothing
        if slash_idx === nothing
            end_idx = qmark_idx - 1
        elseif qmark_idx === nothing
            end_idx = slash_idx - 1
        else
            end_idx = min(slash_idx, qmark_idx) - 1
        end
    end

    end_idx < start_idx && return ""
    return String(SubString(uri, start_idx, end_idx))
end

# Headers that are connection-specific and must be removed in H1→H2 conversion (RFC 9113 §8.2.2)
const _H1_TO_H2_SKIP_HEADER_NAMES = Set([
    HttpHeaderName.CONNECTION,
    HttpHeaderName.TRANSFER_ENCODING,
    HttpHeaderName.UPGRADE,
    HttpHeaderName.KEEP_ALIVE,
    HttpHeaderName.PROXY_CONNECTION,
    HttpHeaderName.HOST,
])

function _http2_message_new_from_http1(http1_msg::HttpMessage, scheme_override::Union{String, Nothing})::Union{HttpMessage, Nothing}
    old_headers = http_message_get_headers(http1_msg)

    # Get combined Connection header value for filtering
    connection_value = http_headers_get_all(old_headers, "connection")

    message = if http_message_is_request(http1_msg)
        http2_message_new_request()
    else
        http2_message_new_response()
    end

    copied_headers = message.headers

    # Set pseudo-headers from HTTP/1 message
    if http_message_is_request(http1_msg)
        method = http_message_get_request_method(http1_msg)
        if method === nothing
            raise_error(ERROR_HTTP_INVALID_METHOD)
            return nothing
        end

        # Use add (not set) to avoid front-insertion reordering
        if http_headers_add(copied_headers, HTTP_HEADER_METHOD_STR, method) != OP_SUCCESS
            return nothing
        end

        is_connect = lowercase(method) == "connect"

        if is_connect && http_message_get_body_stream(http1_msg) !== nothing
            raise_error(ERROR_INVALID_ARGUMENT)
            return nothing
        end

        if !is_connect
            scheme = something(scheme_override, "https")
            if http_headers_add(copied_headers, HTTP_HEADER_SCHEME_STR, scheme) != OP_SUCCESS
                return nothing
            end
        end

        # Find authority
        authority_value = ""
        authority_set = false

        if is_connect
            path = http_message_get_request_path(http1_msg)
            if path !== nothing && !isempty(path)
                authority_value = path
                authority_set = true
            end
        end

        if !authority_set
            host_val = http_headers_get(old_headers, "host")
            if host_val !== nothing
                authority_value = host_val
                authority_set = true
            end
        end

        if !authority_set && !is_connect
            path = http_message_get_request_path(http1_msg)
            if path !== nothing && !isempty(path)
                auth = _extract_uri_authority(path)
                if !isempty(auth)
                    authority_value = auth
                    authority_set = true
                end
            end
        end

        if authority_set
            if http_headers_add(copied_headers, HTTP_HEADER_AUTHORITY_STR, authority_value) != OP_SUCCESS
                return nothing
            end
        elseif is_connect
            raise_error(ERROR_HTTP_INVALID_PATH)
            return nothing
        else
            raise_error(ERROR_HTTP_INVALID_HEADER_FIELD)
            return nothing
        end

        if !is_connect
            path = http_message_get_request_path(http1_msg)
            if path === nothing
                raise_error(ERROR_HTTP_INVALID_PATH)
                return nothing
            end
            if http_headers_add(copied_headers, HTTP_HEADER_PATH_STR, path) != OP_SUCCESS
                return nothing
            end
        end
    else
        # Response
        status = http_message_get_response_status(http1_msg)
        if status === nothing
            raise_error(ERROR_HTTP_INVALID_STATUS_CODE)
            return nothing
        end
        if http2_headers_set_response_status(copied_headers, status) != OP_SUCCESS
            return nothing
        end
    end

    # Copy headers with filtering
    te_added = false
    for i in 0:(http_headers_count(old_headers) - 1)
        h = http_headers_get_index(old_headers, i)
        h === nothing && continue

        lower_name = lowercase(h.name)
        name_enum = http_lowercase_str_to_header_name(lower_name)
        copy_header = true

        if name_enum == HttpHeaderName.CONNECTION ||
           (connection_value !== nothing && _header_value_has_token(connection_value, lower_name))
            # Skip connection-specific headers (RFC 9113 §8.2.2)
            copy_header = false
        elseif name_enum == HttpHeaderName.TE
            if _te_header_value_is_trailers_only(h.value)
                if !te_added
                    if http_headers_add(copied_headers, lower_name, "trailers") != OP_SUCCESS
                        return nothing
                    end
                    te_added = true
                end
            end
            continue
        elseif name_enum in _H1_TO_H2_SKIP_HEADER_NAMES
            copy_header = false
        end

        if copy_header
            if http_headers_add(copied_headers, lower_name, h.value) != OP_SUCCESS
                return nothing
            end
        end
    end

    # Copy body stream
    http_message_set_body_stream(message, http_message_get_body_stream(http1_msg))

    return message
end

"""
    http2_message_new_from_http1(http1_msg) -> Union{HttpMessage, Nothing}

Convert an HTTP/1 message to HTTP/2 format. Default scheme is "https".
"""
function http2_message_new_from_http1(http1_msg::HttpMessage)::Union{HttpMessage, Nothing}
    return _http2_message_new_from_http1(http1_msg, nothing)
end

"""
    http2_message_new_from_http1_with_scheme(http1_msg, scheme) -> Union{HttpMessage, Nothing}

Convert an HTTP/1 message to HTTP/2 format with explicit scheme.
"""
function http2_message_new_from_http1_with_scheme(http1_msg::HttpMessage, scheme::AbstractString)::Union{HttpMessage, Nothing}
    return _http2_message_new_from_http1(http1_msg, String(scheme))
end
