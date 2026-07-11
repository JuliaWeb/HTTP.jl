# HTTP/1.1 parser and serializer primitives used by client and server stacks.

const _HTTP1_DEFAULT_MAX_LINE_BYTES = 8 * 1024
const _HTTP1_DEFAULT_MAX_HEADER_BYTES = 1 * 1024 * 1024

"""
    FixedLengthBody

HTTP/1 body reader for a known `Content-Length`.

Reads are bounded strictly by `remaining`; once the counter reaches zero the
body reports EOF even if more bytes are available on the underlying stream.
"""
mutable struct FixedLengthBody{I<:IO} <: AbstractBody
    io::I
    remaining::Int64
    @atomic closed::Bool
end

"""
    ChunkedBody

HTTP/1 body reader for `Transfer-Encoding: chunked`.

This reader owns the chunk parser state. It lazily advances from chunk-size
line to chunk payload to trailing CRLF, and after the terminal zero-sized chunk
it parses trailer headers into `trailers`.
"""
mutable struct ChunkedBody{I<:IO} <: AbstractBody
    io::I
    chunk_remaining::Int64
    done::Bool
    trailers::Headers
    max_line_bytes::Int
    max_header_bytes::Int
    @atomic closed::Bool
end

"""
    EOFBody

HTTP/1 body reader that consumes until EOF (typically response bodies without
length/chunk framing on non-keepalive connections).

Because EOF is the framing signal, these bodies generally imply that the
connection cannot be safely reused afterwards.
"""
mutable struct EOFBody{I<:IO} <: AbstractBody
    io::I
    @atomic closed::Bool
end

"""
    FixedLengthBody(io, remaining)

Create a fixed-length HTTP/1 body reader with `remaining` bytes available.
"""
function FixedLengthBody(io::I, remaining::Integer) where {I<:IO}
    remaining < 0 && throw(ArgumentError("remaining must be >= 0"))
    return FixedLengthBody(io, Int64(remaining), false)
end

"""
    ChunkedBody(io; max_line_bytes=..., max_header_bytes=...)

Create a chunked body reader with parser limits.

Throws `ArgumentError` when either limit is non-positive. The returned reader
converts malformed chunk syntax and trailer overflows into `ParseError` or
`ProtocolError`.
"""
function ChunkedBody(io::I; max_line_bytes::Integer=_HTTP1_DEFAULT_MAX_LINE_BYTES, max_header_bytes::Integer=_HTTP1_DEFAULT_MAX_HEADER_BYTES) where {I<:IO}
    max_line_bytes <= 0 && throw(ArgumentError("max_line_bytes must be > 0"))
    max_header_bytes <= 0 && throw(ArgumentError("max_header_bytes must be > 0"))
    return ChunkedBody(io, 0, false, Headers(), Int(max_line_bytes), Int(max_header_bytes), false)
end

"""
    EOFBody(io)

Create an EOF-terminated body reader.
"""
function EOFBody(io::I) where {I<:IO}
    return EOFBody(io, false)
end

function body_closed(body::FixedLengthBody)::Bool
    return @atomic :acquire body.closed
end

function body_closed(body::ChunkedBody)::Bool
    return @atomic :acquire body.closed
end

function body_closed(body::EOFBody)::Bool
    return @atomic :acquire body.closed
end

function body_close!(body::FixedLengthBody)
    @atomic :release body.closed = true
    return nothing
end

function body_close!(body::ChunkedBody)
    @atomic :release body.closed = true
    return nothing
end

function body_close!(body::EOFBody)
    @atomic :release body.closed = true
    return nothing
end

"""
    trailers(body)

Return parsed trailer headers for a chunked body; empty headers for other body
types.

The returned `Headers` object is copied so callers can inspect or mutate it
without racing the body reader.
"""
function trailers(body::ChunkedBody)::Headers
    return copy(body.trailers)
end

function trailers(::AbstractBody)::Headers
    return Headers()
end

@inline function _read_u8(io::IO)::UInt8
    try
        return read(io, UInt8)
    catch err
        err isa EOFError && throw(ParseError("unexpected EOF while reading HTTP/1 data"))
        rethrow(err)
    end
end

function _readline_crlf(io::IO, max_line_bytes::Integer)::String
    max_line_bytes <= 0 && throw(ArgumentError("max_line_bytes must be > 0"))
    bytes = UInt8[]
    while true
        b = _read_u8(io)
        push!(bytes, b)
        length(bytes) > max_line_bytes && throw(ProtocolError("HTTP/1 line exceeds configured max_line_bytes", _PROTOCOL_ERROR_LINE_TOO_LONG))
        n = length(bytes)
        if n >= 2 && bytes[n-1] == 0x0d && bytes[n] == 0x0a
            resize!(bytes, n - 2)
            return String(bytes)
        end
    end
end

"""
    _upcoming_header_keys(io) -> Int

Approximate number of header keys available in the current buffered chunk.
Specialized readers can override this to enable better preallocation.
"""
function _upcoming_header_keys(io::IO)::Int
    _ = io
    return 0
end

function _read_headers(io::IO, max_line_bytes::Integer, max_header_bytes::Integer)::Headers
    max_header_bytes <= 0 && throw(ArgumentError("max_header_bytes must be > 0"))
    headers = Headers(_upcoming_header_keys(io))
    consumed = 0
    while true
        line = _readline_crlf(io, max_line_bytes)
        consumed += ncodeunits(line) + 2
        consumed > max_header_bytes && throw(ProtocolError("HTTP/1 headers exceed configured max_header_bytes", _PROTOCOL_ERROR_HEADERS_TOO_LARGE))
        isempty(line) && return headers
        sep = findfirst(':', line)
        sep === nothing && throw(ParseError("malformed HTTP/1 header line (missing ':'): $(repr(line))"))
        key = String(SubString(line, firstindex(line), prevind(line, sep)))
        key == _trim_http_ows(key) || throw(ParseError("malformed HTTP/1 header line (whitespace before ':'): $(repr(line))"))
        _valid_header_field_name(key) || throw(ParseError("invalid HTTP/1 header field name: $(repr(key))"))
        value = _trim_http_ows(SubString(line, nextind(line, sep), lastindex(line)))
        normalized = _normalize_header_field_value(value)
        normalized === nothing && throw(ParseError("invalid HTTP/1 header field value for $(repr(key))"))
        canon_key = canonical_header_key(key)
        if canon_key == "Content-Length" || canon_key == "Transfer-Encoding" || canon_key == "Host"
            push!(headers, canon_key => normalized)
        else
            appendheader(headers, canon_key, normalized)
        end
    end
end

function _parse_http_version(version::AbstractString)::Tuple{UInt8,UInt8}
    startswith(version, "HTTP/") || throw(ParseError("invalid HTTP version token: $(repr(version))"))
    parts = split(String(SubString(version, 6)), '.'; limit=2)
    length(parts) == 2 || throw(ParseError("invalid HTTP version token: $(repr(version))"))
    major = try
        parse(Int, parts[1])
    catch
        throw(ParseError("invalid HTTP major version: $(repr(version))"))
    end
    minor = try
        parse(Int, parts[2])
    catch
        throw(ParseError("invalid HTTP minor version: $(repr(version))"))
    end
    (major < 0 || major > typemax(UInt8)) && throw(ParseError("invalid HTTP major version: $(repr(version))"))
    (minor < 0 || minor > typemax(UInt8)) && throw(ParseError("invalid HTTP minor version: $(repr(version))"))
    return UInt8(major), UInt8(minor)
end

function _parse_int64_decimal_header_value(value::AbstractString, kind::AbstractString)::Int64
    trimmed = _trim_http_ows(value)
    isempty(trimmed) && throw(ParseError("empty $kind header value"))
    limit = UInt64(typemax(Int64))
    total = UInt64(0)
    @inbounds for b in codeunits(trimmed)
        0x30 <= b <= 0x39 || throw(ParseError("invalid $kind header value: $(repr(value))"))
        digit = UInt64(b - 0x30)
        total > ((limit - digit) ÷ UInt64(10)) && throw(ParseError("invalid $kind header value: $(repr(value))"))
        total = total * UInt64(10) + digit
    end
    return Int64(total)
end

function _parse_content_length(hdrs::Headers)::Int64
    values = headers(hdrs, "Content-Length")
    isempty(values) && return Int64(-1)
    parsed = Int64(-1)
    canonical = ""
    for value in values
        trimmed = _trim_http_ows(value)
        n = _parse_int64_decimal_header_value(value, "Content-Length")
        if parsed == Int64(-1)
            parsed = n
            canonical = trimmed
            continue
        end
        parsed == n || throw(ProtocolError("mismatched Content-Length header values"))
    end
    length(values) == 1 && values[1] == canonical || begin
        removeheader(hdrs, "Content-Length")
        setheader(hdrs, "Content-Length", canonical)
    end
    return parsed
end

function _parse_transfer_encoding!(hdrs::Headers, proto_major::UInt8, proto_minor::UInt8)::Bool
    values = headers(hdrs, "Transfer-Encoding")
    isempty(values) && return false
    if proto_major < UInt8(1) || (proto_major == UInt8(1) && proto_minor < UInt8(1))
        # RFC 9112 §6.1: an HTTP/1.0 message must not use Transfer-Encoding; a
        # recipient that receives one has faulty framing. The old behavior
        # silently dropped the header and fell back to Content-Length while
        # leaving a keep-alive connection open, so a reverse proxy that framed
        # the body as chunked could leave the trailing chunked bytes on the
        # reused connection for HTTP.jl to parse as a smuggled pipelined request
        # (ANT-2026-YD5QTQDZ). Reject instead: this surfaces as a 400 and the
        # server closes the connection (Response close=true), so no ambiguous
        # bytes remain on the transport.
        throw(ProtocolError("Transfer-Encoding is not allowed in HTTP/1.0 messages"))
    end
    length(values) == 1 || throw(ProtocolError("too many Transfer-Encoding header values"))
    raw = _trim_http_ows(values[1])
    _ascii_equal_fold(raw, "chunked") || throw(ProtocolError("unsupported transfer encoding"))
    setheader(hdrs, "Transfer-Encoding", "chunked")
    return true
end

function _validate_incoming_trailers!(trailers::Headers)::Nothing
    for (key, _) in trailers
        _valid_trailer_header_name(key) || throw(ParseError("invalid HTTP trailer field name: $(repr(key))"))
    end
    return nothing
end

function _validate_request_target!(method::String, target::String)::Nothing
    _string_contains_ctl_byte(target) && throw(ParseError("invalid HTTP target: $(repr(target))"))
    if method == "CONNECT" && !startswith(target, "/")
        _valid_host_header(target) || throw(ParseError("invalid HTTP CONNECT target: $(repr(target))"))
        return nothing
    end
    target == "*" && return nothing
    startswith(target, "/") && return nothing
    try
        _parse_http_url(target)
        return nothing
    catch
        throw(ParseError("invalid HTTP target: $(repr(target))"))
    end
end

# Client-side guard for the HTTP/1 request start line. The method and target
# flow from caller-constructed `Request` objects (often built by interpolating
# user-controlled URL components) straight onto the wire via `print`, so we must
# reject CR/LF and other control bytes here before serialization. Without this an
# attacker who influences the URL path/query/method could embed `\r\n` to inject
# headers or smuggle a pipelined request on a pooled keep-alive connection. The
# server read path already enforces this via `_validate_request_target!`; this is
# the symmetric check for the client write path (the HTTP/2 client validates
# `:path`/`:method` analogously). `host`, when present, is the authority used in
# absolute-form/proxy-forward start lines and must be control-byte-free as well.
function _validate_request_start_line!(method::String, target::String, host::Union{Nothing,AbstractString}=nothing)::Nothing
    # An HTTP method is an RFC 7230 token; `_valid_header_field_name` enforces
    # exactly that grammar (and so excludes spaces, CR, LF and other CTLs).
    _valid_header_field_name(method) || throw(ParseError("invalid HTTP method: $(repr(method))"))
    _validate_request_target!(method, target)
    if host !== nothing
        _string_contains_ctl_byte(host) && throw(ParseError("invalid HTTP request host: $(repr(host))"))
    end
    return nothing
end

function _validate_request_host!(hdrs::Headers, method::String, proto_major::UInt8, proto_minor::UInt8)::Union{Nothing,String}
    host_values = headers(hdrs, "Host")
    if (proto_major > UInt8(1) || (proto_major == UInt8(1) && proto_minor >= UInt8(1))) &&
       isempty(host_values) &&
       method != "CONNECT"
        throw(ProtocolError("missing required Host header"))
    end
    length(host_values) > 1 && throw(ProtocolError("too many Host headers"))
    isempty(host_values) && return nothing
    host = host_values[1]
    _valid_host_header(host) || throw(ProtocolError("malformed Host header"))
    return host
end

function _should_close_connection(headers::Headers, proto_major::UInt8, proto_minor::UInt8)::Bool
    if proto_major == UInt8(1) && proto_minor == UInt8(0)
        return !headercontains(headers, "Connection", "keep-alive")
    end
    return headercontains(headers, "Connection", "close")
end

function _body_allowed_for_status(status::Integer)::Bool
    status < 100 && return true
    (100 <= status < 200) && return false
    status == 204 && return false
    status == 304 && return false
    return true
end

function _read_exact!(io::IO, dst::Vector{UInt8}, nbytes::Integer)::Int
    nbytes < 0 && throw(ArgumentError("nbytes must be >= 0"))
    nbytes == 0 && return 0
    nbytes <= length(dst) || throw(ArgumentError("nbytes must be <= destination length"))
    try
        n = readbytes!(io, dst, Int(nbytes))
        return n
    catch err
        err isa EOFError && throw(ParseError("unexpected EOF while reading HTTP/1 body"))
        rethrow(err)
    end
end

function _consume_crlf(io::IO)
    b1 = _read_u8(io)
    b2 = _read_u8(io)
    (b1 == 0x0d && b2 == 0x0a) || throw(ParseError("expected CRLF terminator in chunked body"))
    return nothing
end

function _parse_chunk_size(line::AbstractString)::Int64
    # RFC 9112 §7.1: chunk = chunk-size [ chunk-ext ] CRLF, where
    #   chunk-size = 1*HEXDIG. The chunk-size token must be one or more ASCII
    # hex digits with no sign, no "0x" prefix, and no surrounding whitespace.
    # We split off any chunk extension at the first ';' and then validate the
    # remaining token byte-by-byte instead of using Base.parse(Int64,...;base=16),
    # which silently tolerates '+'/'-', a "0x" prefix, and isspace padding
    # (including a trailing bare CR). Accepting those forms lets HTTP.jl disagree
    # with an RFC-strict front-end proxy about where the chunked body ends, which
    # enables HTTP request smuggling (ANT-2026-SRPX7DN1). This mirrors the strict
    # decimal parser used for Content-Length (_parse_int64_decimal_header_value).
    semi = findfirst(';', line)
    token = semi === nothing ? line : SubString(line, firstindex(line), prevind(line, semi))
    units = codeunits(token)
    isempty(units) && throw(ParseError("empty chunk size"))
    limit = UInt64(typemax(Int64))
    total = UInt64(0)
    @inbounds for b in units
        if 0x30 <= b <= 0x39          # '0'-'9'
            digit = UInt64(b - 0x30)
        elseif 0x41 <= b <= 0x46      # 'A'-'F'
            digit = UInt64(b - 0x41 + 0x0a)
        elseif 0x61 <= b <= 0x66      # 'a'-'f'
            digit = UInt64(b - 0x61 + 0x0a)
        else
            throw(ParseError("invalid chunk size: $(repr(line))"))
        end
        # Guard against overflow past Int64 range (also keeps the result >= 0).
        total > ((limit - digit) >> 4) && throw(ParseError("chunk size too large: $(repr(line))"))
        total = (total << 4) + digit
    end
    return Int64(total)
end

function _read_next_chunk!(body::ChunkedBody)
    body.done && return nothing
    # Chunked framing is a tiny state machine: parse the next size line, switch
    # into payload-reading mode, and after a zero-sized chunk parse trailers
    # instead of more body bytes.
    line = _readline_crlf(body.io, body.max_line_bytes)
    size = _parse_chunk_size(line)
    if size == 0
        # Terminal chunk: trailing header block is parsed as trailers.
        parsed_trailers = _read_headers(body.io, body.max_line_bytes, body.max_header_bytes)
        _validate_incoming_trailers!(parsed_trailers)
        empty!(body.trailers)
        for (key, value) in parsed_trailers
            appendheader(body.trailers, key, value)
        end
        body.done = true
        body.chunk_remaining = 0
        return nothing
    end
    body.chunk_remaining = size
    return nothing
end

function body_read!(body::FixedLengthBody, dst::Vector{UInt8})::Int
    body_closed(body) && return 0
    isempty(dst) && return 0
    body.remaining <= 0 && return 0
    to_read = min(Int64(length(dst)), body.remaining)
    n = _read_exact!(body.io, dst, to_read)
    n == to_read || throw(ParseError("truncated fixed-length HTTP/1 body"))
    body.remaining -= n
    return n
end

function body_read!(body::EOFBody, dst::Vector{UInt8})::Int
    body_closed(body) && return 0
    isempty(dst) && return 0
    try
        return readbytes!(body.io, dst, length(dst))
    catch err
        err isa EOFError && return 0
        rethrow(err)
    end
end

function body_read!(body::ChunkedBody, dst::Vector{UInt8})::Int
    body_closed(body) && return 0
    isempty(dst) && return 0
    body.done && return 0
    body.chunk_remaining == 0 && _read_next_chunk!(body)
    body.done && return 0
    to_read = min(Int64(length(dst)), body.chunk_remaining)
    n = _read_exact!(body.io, dst, to_read)
    n == to_read || throw(ParseError("truncated chunked HTTP/1 body"))
    body.chunk_remaining -= n
    if body.chunk_remaining == 0
        _consume_crlf(body.io)
    end
    return n
end

function _write_start_line!(io::IO, request::Request, wire_target::Union{Nothing,AbstractString}=nothing)
    target = wire_target === nothing ? request.target : String(wire_target)
    # Reject CR/LF/CTL in the method or target before they reach the socket.
    _validate_request_start_line!(request.method, target)
    print(io, request.method, ' ', target, " HTTP/", Int(request.proto_major), '.', Int(request.proto_minor), "\r\n")
    return nothing
end

function _status_text(status::Integer)::String
    status == 100 && return "Continue"
    status == 101 && return "Switching Protocols"
    status == 102 && return "Processing"
    status == 103 && return "Early Hints"
    status == 200 && return "OK"
    status == 201 && return "Created"
    status == 202 && return "Accepted"
    status == 203 && return "Non-Authoritative Information"
    status == 204 && return "No Content"
    status == 205 && return "Reset Content"
    status == 206 && return "Partial Content"
    status == 207 && return "Multi-Status"
    status == 208 && return "Already Reported"
    status == 226 && return "IM Used"
    status == 300 && return "Multiple Choices"
    status == 301 && return "Moved Permanently"
    status == 302 && return "Found"
    status == 303 && return "See Other"
    status == 304 && return "Not Modified"
    status == 305 && return "Use Proxy"
    status == 307 && return "Temporary Redirect"
    status == 308 && return "Permanent Redirect"
    status == 400 && return "Bad Request"
    status == 401 && return "Unauthorized"
    status == 402 && return "Payment Required"
    status == 403 && return "Forbidden"
    status == 404 && return "Not Found"
    status == 405 && return "Method Not Allowed"
    status == 406 && return "Not Acceptable"
    status == 407 && return "Proxy Authentication Required"
    status == 408 && return "Request Timeout"
    status == 409 && return "Conflict"
    status == 410 && return "Gone"
    status == 411 && return "Length Required"
    status == 412 && return "Precondition Failed"
    status == 413 && return "Content Too Large"
    status == 414 && return "URI Too Long"
    status == 415 && return "Unsupported Media Type"
    status == 416 && return "Range Not Satisfiable"
    status == 417 && return "Expectation Failed"
    status == 418 && return "I'm a teapot"
    status == 421 && return "Misdirected Request"
    status == 422 && return "Unprocessable Entity"
    status == 423 && return "Locked"
    status == 424 && return "Failed Dependency"
    status == 425 && return "Too Early"
    status == 426 && return "Upgrade Required"
    status == 428 && return "Precondition Required"
    status == 429 && return "Too Many Requests"
    status == 431 && return "Request Header Fields Too Large"
    status == 451 && return "Unavailable For Legal Reasons"
    status == 500 && return "Internal Server Error"
    status == 501 && return "Not Implemented"
    status == 502 && return "Bad Gateway"
    status == 503 && return "Service Unavailable"
    status == 504 && return "Gateway Timeout"
    status == 505 && return "HTTP Version Not Supported"
    status == 506 && return "Variant Also Negotiates"
    status == 507 && return "Insufficient Storage"
    status == 508 && return "Loop Detected"
    status == 510 && return "Not Extended"
    status == 511 && return "Network Authentication Required"
    return ""
end

@inline function _response_reason_phrase(response::Response)::String
    reason = isempty(response.reason) ? _status_text(response.status) : response.reason
    _string_contains_ctl_byte(reason) && throw(ProtocolError("invalid HTTP response reason phrase: $(repr(reason))"))
    return reason
end

@inline function _write_status_line!(io::IO, response::Response)::Nothing
    reason = _response_reason_phrase(response)
    print(io, "HTTP/", Int(response.proto_major), '.', Int(response.proto_minor), ' ', response.status, ' ', reason, "\r\n")
    return nothing
end

@inline function _append_status_line!(buf::IOBuffer, response::Response)::Nothing
    reason = _response_reason_phrase(response)
    print(buf, "HTTP/", Int(response.proto_major), '.', Int(response.proto_minor), ' ', response.status, ' ', reason, "\r\n")
    return nothing
end

function _append_headers!(buf::IOBuffer, hdrs::Headers)
    for (key, value) in hdrs
        print(buf, key, ": ", value, "\r\n")
    end
    return nothing
end

function _write_headers!(io::IO, hdrs::Headers)
    _normalize_outgoing_headers!(hdrs)
    for (key, value) in hdrs
        print(io, key, ": ", value, "\r\n")
    end
    return nothing
end

function _validate_declared_trailer_headers!(hdrs::Headers)::Nothing
    for value in headers(hdrs, "Trailer")
        for item in split(value, ',')
            trailer_name = _trim_http_ows(item)
            isempty(trailer_name) && throw(ProtocolError("invalid HTTP Trailer header value"))
            _valid_trailer_header_name(trailer_name) || throw(ProtocolError("invalid HTTP trailer field name: $(repr(trailer_name))"))
        end
    end
    return nothing
end

function _normalize_outgoing_headers!(headers::Headers)::Nothing
    entries = headers.entries
    @inbounds for i in eachindex(entries)
        key, value = entries[i]
        _valid_header_field_name(key) || throw(ProtocolError("invalid HTTP header field name: $(repr(key))"))
        normalized = _normalize_header_field_value(value)
        normalized === nothing && throw(ProtocolError("invalid HTTP header field value for $(repr(key))"))
        normalized == value || (entries[i] = key => normalized)
    end
    _validate_declared_trailer_headers!(headers)
    return nothing
end

function _normalize_outgoing_trailers!(trailers::Headers)::Nothing
    entries = trailers.entries
    @inbounds for i in eachindex(entries)
        key, value = entries[i]
        _valid_trailer_header_name(key) || throw(ProtocolError("invalid HTTP trailer field name: $(repr(key))"))
        normalized = _normalize_header_field_value(value)
        normalized === nothing && throw(ProtocolError("invalid HTTP trailer field value for $(repr(key))"))
        normalized == value || (entries[i] = key => normalized)
    end
    return nothing
end

function _prepare_trailer_header!(headers::Headers, trailer_values::Headers)::Headers
    isempty(trailer_values) && return Headers()
    prepared_trailers = copy(trailer_values)
    _normalize_outgoing_trailers!(prepared_trailers)
    hasheader(headers, "Trailer") && return prepared_trailers
    names = header_keys(prepared_trailers)
    isempty(names) && return prepared_trailers
    setheader(headers, "Trailer", join(names, ", "))
    return prepared_trailers
end

function _write_exact_body!(io::IO, body::AbstractBody, expected_len::Int64)
    expected_len < 0 && throw(ArgumentError("expected_len must be >= 0"))
    expected_len == 0 && return nothing
    remaining = expected_len
    while remaining > 0
        to_read = Int(min(Int64(16 * 1024), remaining))
        buf = Vector{UInt8}(undef, to_read)
        n = body_read!(body, buf)
        n > 0 || throw(ProtocolError("body ended before expected Content-Length bytes were written"))
        write(io, n == length(buf) ? buf : @view(buf[1:n]))
        remaining -= n
    end
    return nothing
end

function _write_exact_body!(io::IO, body::AbstractString, expected_len::Int64)
    expected_len < 0 && throw(ArgumentError("expected_len must be >= 0"))
    actual_len = Int64(ncodeunits(body))
    actual_len == expected_len || throw(ProtocolError("body bytes did not match expected Content-Length"))
    actual_len == 0 && return nothing
    n = write(io, body)
    n == expected_len || throw(ProtocolError("transport short write"))
    return nothing
end

function _write_exact_body!(io::IO, body::AbstractVector{UInt8}, expected_len::Int64)
    expected_len < 0 && throw(ArgumentError("expected_len must be >= 0"))
    actual_len = Int64(length(body))
    actual_len == expected_len || throw(ProtocolError("body bytes did not match expected Content-Length"))
    actual_len == 0 && return nothing
    n = write(io, body)
    n == expected_len || throw(ProtocolError("transport short write"))
    return nothing
end

function _write_exact_body!(::IO, body, expected_len::Int64)
    expected_len < 0 && throw(ArgumentError("expected_len must be >= 0"))
    expected_len == 0 && return nothing
    throw(ProtocolError("unsupported HTTP/1 response body type $(typeof(body))"))
end

function _write_exact_bytes_body!(stream, body::BytesBody, expected_len::Int64)
    expected_len < 0 && throw(ArgumentError("expected_len must be >= 0"))
    expected_len == 0 && return nothing
    # `body` is usually abstract here and `stream` is deliberately untyped;
    # the Int asserts keep the arithmetic/comparisons concretely inferred so
    # this method carries no invalidation-prone `>=(::Any, ::Int)` edges
    len = length(body.data)::Int
    available = (len - body.next_index) + 1
    available >= expected_len || throw(ProtocolError("body ended before expected Content-Length bytes were written"))
    stop_index = body.next_index + Int(expected_len) - 1
    chunk = if body.next_index == 1 && stop_index == len
        body.data
    else
        view(body.data, body.next_index:stop_index)
    end
    n = Int(write(stream, chunk))
    n == expected_len || throw(ProtocolError("transport short write"))
    body.next_index = stop_index + 1
    return nothing
end

function _write_chunked_body!(io::IO, body::AbstractBody, trailer_values::Headers)
    buf = Vector{UInt8}(undef, 16 * 1024)
    while true
        n = body_read!(body, buf)
        n == 0 && break
        print(io, string(n, base=16), "\r\n")
        write(io, @view(buf[1:n]))
        write(io, "\r\n")
    end
    write(io, "0\r\n")
    _write_headers!(io, trailer_values)
    write(io, "\r\n")
    return nothing
end

function _write_chunked_body!(io::IO, body::AbstractString, trailer_values::Headers)
    if !isempty(body)
        n = ncodeunits(body)
        print(io, string(n, base=16), "\r\n")
        write(io, body)
        write(io, "\r\n")
    end
    write(io, "0\r\n")
    _write_headers!(io, trailer_values)
    write(io, "\r\n")
    return nothing
end

function _write_chunked_body!(io::IO, body::AbstractVector{UInt8}, trailer_values::Headers)
    if !isempty(body)
        print(io, string(length(body), base=16), "\r\n")
        write(io, body)
        write(io, "\r\n")
    end
    write(io, "0\r\n")
    _write_headers!(io, trailer_values)
    write(io, "\r\n")
    return nothing
end

function _write_chunked_body!(::IO, body, ::Headers)
    throw(ProtocolError("unsupported HTTP/1 response body type $(typeof(body))"))
end

function _request_has_body(request::Request)::Bool
    request.body isa EmptyBody && return false
    request.content_length == 0 && return false
    return true
end

function _prepare_request_headers_for_write(
    request::Request,
    proxy_authorization::Union{Nothing,AbstractString}=nothing,
)::Tuple{Headers,Bool}
    headers = copy(request.headers)
    if proxy_authorization !== nothing && !hasheader(headers, "Proxy-Authorization")
        setheader(headers, "Proxy-Authorization", String(proxy_authorization))
    end
    has_host = hasheader(headers, "Host")
    if !has_host && request.host !== nothing
        setheader(headers, "Host", request.host::String)
    end
    request_close = request.close || _should_close_connection(headers, request.proto_major, request.proto_minor)
    request_close && setheader(headers, "Connection", "close")
    use_chunked = _parse_transfer_encoding!(headers, request.proto_major, request.proto_minor)
    if !use_chunked
        if request.content_length >= 0
            setheader(headers, "Content-Length", string(request.content_length))
        elseif _request_has_body(request)
            use_chunked = true
            setheader(headers, "Transfer-Encoding", "chunked")
            removeheader(headers, "Content-Length")
        else
            setheader(headers, "Content-Length", "0")
        end
    else
        removeheader(headers, "Content-Length")
    end
    return headers, use_chunked
end

function _append_start_line!(buf::IOBuffer, request::Request, wire_target::Union{Nothing,AbstractString}=nothing)
    target = wire_target === nothing ? request.target : String(wire_target)
    # Reject CR/LF/CTL in the method or target before they reach the socket.
    _validate_request_start_line!(request.method, target)
    print(buf, request.method, ' ', target, " HTTP/", Int(request.proto_major), '.', Int(request.proto_minor), "\r\n")
    return nothing
end

function _write_request_head!(
    io::IO,
    request::Request,
    wire_target::Union{Nothing,AbstractString}=nothing,
    proxy_authorization::Union{Nothing,AbstractString}=nothing,
)::Tuple{Bool,Headers}
    headers, use_chunked = _prepare_request_headers_for_write(request, proxy_authorization)
    trailer_values = use_chunked ? _prepare_trailer_header!(headers, request.trailers) : Headers()
    _normalize_outgoing_headers!(headers)
    head_buf = IOBuffer()
    _append_start_line!(head_buf, request, wire_target)
    _append_headers!(head_buf, headers)
    print(head_buf, "\r\n")
    write(io, take!(head_buf))
    return use_chunked, trailer_values
end

# @nospecialize + concrete-first isa chain: called with widened responses from the
# server write path; abstract-narrowed isempty calls are dynamic under `juliac --trim`
function _response_has_body(@nospecialize(response::Response))::Bool
    _body_allowed_for_status(response.status) || return false
    body = response.body
    body === nothing && return false
    body isa EmptyBody && return false
    if body isa String
        isempty(body) && return false
    elseif body isa SubString{String}
        isempty(body) && return false
    elseif body isa Vector{UInt8}
        isempty(body) && return false
    elseif body isa AbstractString
        isempty(body::AbstractString) && return false
    elseif body isa AbstractVector{UInt8}
        isempty(body::AbstractVector{UInt8}) && return false
    end
    response.content_length == 0 && return false
    return true
end

"""
    write_request!(io, request)

Serialize an HTTP/1 request to `io`, including body framing.

Behavior:
- injects `Host` from `request.host` when missing
- normalizes connection-close signaling
- chooses between `Content-Length` and chunked transfer-coding
- serializes trailers only for chunked bodies

Returns `nothing`. May throw `ProtocolError` for inconsistent framing or
propagate exceptions from `io` and the request body.
"""
function write_request!(
    io::IO,
    request::Request{B};
    wire_target::Union{Nothing,AbstractString}=nothing,
    proxy_authorization::Union{Nothing,AbstractString}=nothing,
) where {B<:AbstractBody}
    use_chunked, trailer_values = _write_request_head!(io, request, wire_target, proxy_authorization)
    if use_chunked
        _write_chunked_body!(io, request.body, trailer_values)
        return nothing
    end
    request.content_length < 0 && return nothing
    body = request.body
    if body isa BytesBody
        _write_exact_bytes_body!(io, body::BytesBody, request.content_length)
    else
        _write_exact_body!(io, body, request.content_length)
    end
    return nothing
end

"""
    write_response!(io, response)

Serialize an HTTP/1 response to `io`, including body framing.

Body suppression rules for status codes like `1xx`, `204`, and `304` are
enforced here so callers can hand the function a regular `Response` object and
let the serializer apply wire-level HTTP/1 rules.
"""
# @nospecialize: compiled once for any Response{B}; the body write below dispatches
# through an explicit isa chain (see _write_all_response! for why)
function write_response!(io::IO, @nospecialize(response::Response))
    headers = copy(response.headers)
    response_close = response.close || _should_close_connection(headers, response.proto_major, response.proto_minor)
    response_close && setheader(headers, "Connection", "close")
    status_allows_body = _body_allowed_for_status(response.status)
    response_to_head = response.request !== nothing && (response.request::Request).method == "HEAD"
    allows_body = status_allows_body && !response_to_head
    use_chunked = allows_body && _parse_transfer_encoding!(headers, response.proto_major, response.proto_minor)
    if !status_allows_body
        removeheader(headers, "Content-Length")
        removeheader(headers, "Transfer-Encoding")
    elseif response_to_head
        removeheader(headers, "Transfer-Encoding")
        if response.content_length >= 0
            setheader(headers, "Content-Length", string(response.content_length))
        elseif !_response_has_body(response)
            setheader(headers, "Content-Length", "0")
        end
    elseif !use_chunked
        if response.content_length >= 0
            setheader(headers, "Content-Length", string(response.content_length))
        elseif _response_has_body(response)
            use_chunked = true
            setheader(headers, "Transfer-Encoding", "chunked")
            removeheader(headers, "Content-Length")
        else
            setheader(headers, "Content-Length", "0")
        end
    else
        removeheader(headers, "Content-Length")
    end
    trailer_values = use_chunked ? _prepare_trailer_header!(headers, response.trailers) : Headers()
    _normalize_outgoing_headers!(headers)
    # Buffer the entire response head (status line + all header lines + blank
    # CRLF) into a single IOBuffer and write it to the transport in one
    # syscall. The transport's `write` does not buffer internally, so emitting
    # the head field-by-field via `print` translates to a write syscall per
    # argument (~20 per typical response).
    head_buf = IOBuffer()
    _append_status_line!(head_buf, response)
    _append_headers!(head_buf, headers)
    print(head_buf, "\r\n")
    write(io, take!(head_buf))
    allows_body || return nothing
    if use_chunked
        # concrete-first isa chain (see the exact-body chain below)
        let cbody = response.body
            if cbody isa String
                _write_chunked_body!(io, cbody, trailer_values)
            elseif cbody isa SubString{String}
                _write_chunked_body!(io, cbody, trailer_values)
            elseif cbody isa Vector{UInt8}
                _write_chunked_body!(io, cbody, trailer_values)
            elseif cbody isa AbstractBody
                _write_chunked_body!(io, cbody, trailer_values)
            else
                throw(ProtocolError("unsupported HTTP/1 chunked response body type"))
            end
        end
        return nothing
    end
    response.content_length < 0 && return nothing
    body = response.body
    # explicit isa chain over the body shapes, concrete types first: with the
    # response nospecialized, `body` is abstract here, and a bare multi-method call
    # would be dynamic dispatch — unresolvable under `juliac --trim`
    if body isa BytesBody{Vector{UInt8}}
        _write_exact_bytes_body!(io, body, response.content_length)
    elseif body isa BytesBody
        _write_exact_bytes_body!(io, body, response.content_length)
    elseif body isa String
        _write_exact_body!(io, body, response.content_length)
    elseif body isa SubString{String}
        _write_exact_body!(io, body, response.content_length)
    elseif body isa Vector{UInt8}
        _write_exact_body!(io, body, response.content_length)
    elseif body isa AbstractBody
        _write_exact_body!(io, body, response.content_length)
    else
        throw(ProtocolError("unsupported HTTP/1 response body type"))
    end
    return nothing
end

function _parse_request_line(line::AbstractString)::Tuple{String,String,UInt8,UInt8}
    first_space = findfirst(isequal(' '), line)
    first_space === nothing && throw(ParseError("malformed HTTP/1 request line: $(repr(line))"))
    second_space = findnext(isequal(' '), line, nextind(line, first_space))
    second_space === nothing && throw(ParseError("malformed HTTP/1 request line: $(repr(line))"))
    method = String(SubString(line, firstindex(line), prevind(line, first_space)))
    target = String(SubString(line, nextind(line, first_space), prevind(line, second_space)))
    version = String(SubString(line, nextind(line, second_space), lastindex(line)))
    isempty(method) && throw(ParseError("empty HTTP method in request line"))
    isempty(target) && throw(ParseError("empty HTTP target in request line"))
    _valid_header_field_name(method) || throw(ParseError("invalid HTTP method in request line: $(repr(method))"))
    _validate_request_target!(method, target)
    major, minor = _parse_http_version(version)
    return method, target, major, minor
end

function _parse_status_line(line::AbstractString)::Tuple{UInt8,UInt8,Int,String}
    first_space = findfirst(isequal(' '), line)
    first_space === nothing && throw(ParseError("malformed HTTP/1 status line: $(repr(line))"))
    version = String(SubString(line, firstindex(line), prevind(line, first_space)))
    major, minor = _parse_http_version(version)
    rest_start = nextind(line, first_space)
    rest_start > lastindex(line) && throw(ParseError("malformed HTTP/1 status line: missing status code"))
    second_space = findnext(isequal(' '), line, rest_start)
    code_token = if second_space === nothing
        SubString(line, rest_start, lastindex(line))
    else
        SubString(line, rest_start, prevind(line, second_space))
    end
    status = try
        parse(Int, code_token)
    catch
        throw(ParseError("invalid HTTP status code in status line: $(repr(line))"))
    end
    status < 0 && throw(ParseError("invalid HTTP status code in status line: $(repr(line))"))
    if second_space === nothing || second_space == lastindex(line)
        reason = ""
    else
        reason = String(SubString(line, nextind(line, second_space), lastindex(line)))
    end
    return major, minor, status, reason
end

"""
    read_request(io; max_line_bytes=..., max_header_bytes=...)

Parse one HTTP/1 request from `io`.

Returns a `Request` whose body is one of `EmptyBody`, `FixedLengthBody`, or
`ChunkedBody` depending on the incoming framing headers.

Throws:
- `ArgumentError` for invalid parser limits
- `ParseError` for malformed syntax or truncated framed bodies
- `ProtocolError` for invalid semantic combinations such as conflicting length
  metadata
- any exception propagated by the underlying `IO`
"""
function read_request(io::IO; max_line_bytes::Integer=_HTTP1_DEFAULT_MAX_LINE_BYTES, max_header_bytes::Integer=_HTTP1_DEFAULT_MAX_HEADER_BYTES)
    line = _readline_crlf(io, max_line_bytes)
    method, target, proto_major, proto_minor = _parse_request_line(line)
    headers = _read_headers(io, max_line_bytes, max_header_bytes)
    chunked = _parse_transfer_encoding!(headers, proto_major, proto_minor)
    # A request that carries BOTH Transfer-Encoding and Content-Length has
    # ambiguous framing (RFC 9112 §6.1/§6.3): a front-end proxy may frame by one
    # header while HTTP.jl frames by the other, leaving trailing bytes on a
    # reused keep-alive connection that get parsed as a smuggled request
    # (ANT-2026-YD5QTQDZ). Reject such requests outright (surfaced as 400 with
    # the connection closed) instead of silently preferring Transfer-Encoding.
    if chunked && hasheader(headers, "Content-Length")
        throw(ProtocolError("request must not include both Transfer-Encoding and Content-Length"))
    end
    content_length = _parse_content_length(headers)
    chunked && removeheader(headers, "Content-Length")
    content_length = chunked ? Int64(-1) : content_length
    host = _validate_request_host!(headers, method, proto_major, proto_minor)
    close = _should_close_connection(headers, proto_major, proto_minor)
    if chunked
        body = ChunkedBody(io; max_line_bytes=Int(max_line_bytes), max_header_bytes=Int(max_header_bytes))
        return _request_nocopy(
            method,
            target,
            headers,
            body.trailers,
            body,
            host,
            Int64(-1),
            proto_major,
            proto_minor,
            close,
            RequestContext(),
        )
    end
    if content_length > 0
        body = FixedLengthBody(io, content_length)
        return _request_nocopy(
            method,
            target,
            headers,
            Headers(),
            body,
            host,
            content_length,
            proto_major,
            proto_minor,
            close,
            RequestContext(),
        )
    end
    return _request_nocopy(
        method,
        target,
        headers,
        Headers(),
        EmptyBody(),
        host,
        Int64(0),
        proto_major,
        proto_minor,
        close,
        RequestContext(),
    )
end

@inline function _incoming_response_from_parts(
    status::Int,
    reason::String,
    headers::Headers,
    trailers::Headers,
    body::B,
    content_length::Int64,
    proto_major::UInt8,
    proto_minor::UInt8,
    close::Bool,
    request::Union{Nothing,Request},
)::_IncomingResponse{B} where {B<:AbstractBody}
    return _IncomingResponse(
        _IncomingResponseHead(
            status,
            reason,
            headers,
            trailers,
            content_length,
            proto_major,
            proto_minor,
            close,
            request,
            nothing,
            nothing,
            0,
        ),
        body,
    )
end

@inline function _public_response_from_parts(
    status::Int,
    reason::String,
    headers::Headers,
    trailers::Headers,
    body::B,
    content_length::Int64,
    proto_major::UInt8,
    proto_minor::UInt8,
    close::Bool,
    request::Union{Nothing,Request},
)::Response{B} where {B<:AbstractBody}
    return _response_nocopy_exact(
        status,
        reason,
        headers,
        trailers,
        body,
        content_length,
        proto_major,
        proto_minor,
        close,
        request,
        nothing,
        nothing,
        0,
    )
end

function _read_response_common(
    build::F,
    io::IO,
    request::Union{Nothing,Request}=nothing,
    max_line_bytes::Integer=_HTTP1_DEFAULT_MAX_LINE_BYTES,
    max_header_bytes::Integer=_HTTP1_DEFAULT_MAX_HEADER_BYTES,
) where {F}
    line = _readline_crlf(io, max_line_bytes)
    proto_major, proto_minor, status, reason = _parse_status_line(line)
    headers = _read_headers(io, max_line_bytes, max_header_bytes)
    chunked = _parse_transfer_encoding!(headers, proto_major, proto_minor)
    content_length = _parse_content_length(headers)
    chunked && removeheader(headers, "Content-Length")
    content_length = chunked ? Int64(-1) : content_length
    close = _should_close_connection(headers, proto_major, proto_minor)
    request_is_head = request !== nothing && request.method == "HEAD"
    request_is_connect_tunnel = request !== nothing && request.method == "CONNECT" && status >= 200 && status < 300
    if !_body_allowed_for_status(status) || request_is_head || request_is_connect_tunnel
        return build(
            status,
            reason,
            headers,
            Headers(),
            EmptyBody(),
            Int64(0),
            proto_major,
            proto_minor,
            close,
            request,
        )
    end
    if chunked
        body = ChunkedBody(io; max_line_bytes=Int(max_line_bytes), max_header_bytes=Int(max_header_bytes))
        return build(
            status,
            reason,
            headers,
            body.trailers,
            body,
            Int64(-1),
            proto_major,
            proto_minor,
            close,
            request,
        )
    end
    if content_length > 0
        body = FixedLengthBody(io, content_length)
        return build(
            status,
            reason,
            headers,
            Headers(),
            body,
            content_length,
            proto_major,
            proto_minor,
            close,
            request,
        )
    end
    if content_length == 0
        return build(
            status,
            reason,
            headers,
            Headers(),
            EmptyBody(),
            Int64(0),
            proto_major,
            proto_minor,
            close,
            request,
        )
    end
    body = EOFBody(io)
    return build(
        status,
        reason,
        headers,
        Headers(),
        body,
        Int64(-1),
        proto_major,
        proto_minor,
        close,
        request,
    )
end

"""
    _read_incoming_response(io, request=nothing, max_line_bytes=..., max_header_bytes=...)

Parse one HTTP/1 response from `io` into the internal incoming-response form.

`request` is optional but allows HEAD/no-body response handling parity.
Returns an `_IncomingResponse` whose `rawbody` is one of `EmptyBody`,
`FixedLengthBody`, `ChunkedBody`, or `EOFBody` depending on the status code and
framing headers. Exception behavior mirrors `read_request`.
"""
function _read_incoming_response(
    io::IO,
    request::Union{Nothing,Request}=nothing,
    max_line_bytes::Integer=_HTTP1_DEFAULT_MAX_LINE_BYTES,
    max_header_bytes::Integer=_HTTP1_DEFAULT_MAX_HEADER_BYTES,
)
    return _read_response_common(_incoming_response_from_parts, io, request, max_line_bytes, max_header_bytes)
end

"""
    _read_response(io, request=nothing, max_line_bytes=..., max_header_bytes=...)

Parse one HTTP/1 response from `io`.
`request` is optional but allows HEAD/no-body response handling parity.

Returns a `Response` whose body is one of `EmptyBody`, `FixedLengthBody`,
`ChunkedBody`, or `EOFBody` depending on the status code and framing headers.
Exception behavior mirrors `read_request`.
"""
function _read_response(
    io::IO,
    request::Union{Nothing,Request}=nothing,
    max_line_bytes::Integer=_HTTP1_DEFAULT_MAX_LINE_BYTES,
    max_header_bytes::Integer=_HTTP1_DEFAULT_MAX_HEADER_BYTES,
)
    return _read_response_common(_public_response_from_parts, io, request, max_line_bytes, max_header_bytes)
end
