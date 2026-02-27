# HTTP/1.1 Encoder - State machine encoder for requests and responses
# Port of aws-c-http/source/h1_encoder.c, h1_encoder.h

# ─── HTTP string validation (port of strutil.c) ───

# RFC 7230 §3.2.6: token = 1*tchar
# tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." /
#          "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA
const _HTTP_TOKEN_CHARS = let s = falses(256)
    for c in UInt8[UInt8('!'), UInt8('#'), UInt8('$'), UInt8('%'), UInt8('&'), UInt8('\''),
                   UInt8('*'), UInt8('+'), UInt8('-'), UInt8('.'), UInt8('^'), UInt8('_'),
                   UInt8('`'), UInt8('|'), UInt8('~')]
        s[c + 1] = true
    end
    for c in UInt8('0'):UInt8('9'); s[c + 1] = true; end
    for c in UInt8('A'):UInt8('Z'); s[c + 1] = true; end
    for c in UInt8('a'):UInt8('z'); s[c + 1] = true; end
    Tuple(s)
end

"""
    is_http_token(s) -> Bool

Validate that `s` is a valid HTTP token per RFC 7230 §3.2.6.
Must be non-empty and contain only tchar characters.
"""
function is_http_token(s::AbstractString)::Bool
    isempty(s) && return false
    for c in codeunits(String(s))
        c > 0xff && return false
        @inbounds _HTTP_TOKEN_CHARS[c + 1] || return false
    end
    return true
end

# RFC 7230 §3.2: field-content = field-vchar [ 1*(SP/HTAB) field-vchar ]
# field-vchar = VCHAR / obs-text
# VCHAR = 0x21-0x7E, obs-text = 0x80-0xFF
# Also allows SP (0x20) and HTAB (0x09) in the middle
const _HTTP_FIELD_CONTENT_CHARS = let s = falses(256)
    s[UInt8('\t') + 1] = true  # HTAB
    s[UInt8(' ') + 1] = true   # SP
    for c in 0x21:0x7e; s[c + 1] = true; end  # VCHAR
    for c in 0x80:0xff; s[c + 1] = true; end  # obs-text
    Tuple(s)
end

"""
    is_http_field_value(s) -> Bool

Validate that `s` is a valid HTTP field-value per RFC 7230 §3.2.
Empty string is valid. First and last characters must not be whitespace.
All characters must be VCHAR, obs-text, SP, or HTAB.
"""
function is_http_field_value(s::AbstractString)::Bool
    isempty(s) && return true
    cu = codeunits(String(s))
    # first and last char cannot be whitespace
    first_c = cu[1]
    last_c = cu[end]
    (first_c == UInt8(' ') || first_c == UInt8('\t')) && return false
    (last_c == UInt8(' ') || last_c == UInt8('\t')) && return false
    for c in cu
        c > 0xff && return false
        @inbounds _HTTP_FIELD_CONTENT_CHARS[c + 1] || return false
    end
    return true
end

"""
    is_http_request_target(s) -> Bool

Validate that `s` is a valid HTTP request-target per RFC 7230 §5.3.
Must be non-empty and contain only visible ASCII (> 0x20).
"""
function is_http_request_target(s::AbstractString)::Bool
    isempty(s) && return false
    for c in codeunits(String(s))
        c <= UInt8(' ') && return false
    end
    return true
end

# ─── Encoder state enum ───

@enumx H1EncoderState::UInt8 begin
    INIT = 0
    HEAD = 1
    UNCHUNKED_BODY_STREAM = 2
    CHUNKED_BODY_STREAM = 3
    CHUNKED_BODY_STREAM_LAST_CHUNK = 4
    CHUNK_NEXT = 5
    CHUNK_LINE = 6
    CHUNK_BODY = 7
    CHUNK_END = 8
    CHUNK_TRAILER = 9
    DONE = 10
end

# ─── Chunk extension ───

struct H1ChunkExtension
    key::String
    value::String
end

# ─── H1 Chunk ───

mutable struct H1Chunk
    # late-init: starts as IO, set to nothing on destroy
    data::Any            # input stream (IO or nothing)
    data_size::UInt64
    on_complete::Any      # (stream, error_code) -> Nothing
    chunk_line::Memory{UInt8}  # pre-encoded "SIZE[;ext=val]\r\n"
end

"""
    h1_chunk_new(data, data_size; extensions=H1ChunkExtension[], on_complete=nothing) -> H1Chunk

Create a new chunk for the manual chunked encoding API.
Pre-encodes the chunk-line header (hex size + extensions + CRLF).
"""
function h1_chunk_new(
    data, data_size::Integer;
    extensions::Vector{H1ChunkExtension}=H1ChunkExtension[],
    on_complete=nothing
)::H1Chunk
    chunk_line = UInt8[]
    # Write hex size (uppercase, no padding)
    append!(chunk_line, codeunits(uppercase(string(UInt64(data_size), base=16))))
    # Write extensions
    for ext in extensions
        push!(chunk_line, UInt8(';'))
        append!(chunk_line, codeunits(ext.key))
        push!(chunk_line, UInt8('='))
        append!(chunk_line, codeunits(ext.value))
    end
    # CRLF
    push!(chunk_line, UInt8('\r'), UInt8('\n'))
    chunk_mem = Memory{UInt8}(undef, length(chunk_line))
    copyto!(chunk_mem, 1, chunk_line, 1, length(chunk_line))
    return H1Chunk(data, UInt64(data_size), on_complete, chunk_mem)
end

function h1_chunk_destroy!(chunk::H1Chunk)
    chunk.data = nothing
    return nothing
end

function h1_chunk_complete_and_destroy!(chunk::H1Chunk, error_code::Int)
    cb = chunk.on_complete
    data = chunk.data
    h1_chunk_destroy!(chunk)
    if cb !== nothing
        cb(data, error_code)
    end
    return nothing
end

# ─── H1 Trailer ───

mutable struct H1Trailer
    trailer_data::Memory{UInt8}  # pre-encoded trailing headers + "\r\n"
end

# Forbidden trailing header names (RFC 7230 §4.1.2)
const _FORBIDDEN_TRAILER_HEADERS = Set([
    HttpHeaderName.TRANSFER_ENCODING,
    HttpHeaderName.CONTENT_LENGTH,
    HttpHeaderName.HOST,
    HttpHeaderName.EXPECT,
    HttpHeaderName.CACHE_CONTROL,
    HttpHeaderName.MAX_FORWARDS,
    HttpHeaderName.PRAGMA,
    HttpHeaderName.RANGE,
    HttpHeaderName.TE,
    HttpHeaderName.CONTENT_ENCODING,
    HttpHeaderName.CONTENT_TYPE,
    HttpHeaderName.CONTENT_RANGE,
    HttpHeaderName.TRAILER,
    HttpHeaderName.WWW_AUTHENTICATE,
    HttpHeaderName.AUTHORIZATION,
    HttpHeaderName.PROXY_AUTHENTICATE,
    HttpHeaderName.PROXY_AUTHORIZATION,
    HttpHeaderName.SET_COOKIE,
    HttpHeaderName.COOKIE,
    HttpHeaderName.AGE,
    HttpHeaderName.EXPIRES,
    HttpHeaderName.DATE,
    HttpHeaderName.LOCATION,
    HttpHeaderName.RETRY_AFTER,
    HttpHeaderName.VARY,
    HttpHeaderName.WARNING,
])

"""
    h1_trailer_new(headers::HttpHeaders) -> Union{H1Trailer, Nothing}

Create a trailer from headers. Validates that no forbidden headers are present.
Returns `nothing` on validation failure.
"""
function h1_trailer_new(headers::HttpHeaders)::Union{H1Trailer, Nothing}
    buf = UInt8[]
    n = http_headers_count(headers)
    for i in 0:(n - 1)
        h = http_headers_get_index(headers, i)
        h === nothing && continue

        # Validate name is a token
        if !is_http_token(h.name)
            raise_error(ERROR_HTTP_INVALID_HEADER_NAME)
            return nothing
        end
        # Validate value
        trimmed_val = trim_http_whitespace(h.value)
        if !is_http_field_value(trimmed_val)
            raise_error(ERROR_HTTP_INVALID_HEADER_VALUE)
            return nothing
        end
        # Check forbidden trailer names
        name_enum = http_str_to_header_name(h.name)
        if name_enum in _FORBIDDEN_TRAILER_HEADERS
            raise_error(ERROR_HTTP_INVALID_HEADER_FIELD)
            return nothing
        end

        # "name: value\r\n"
        append!(buf, codeunits(h.name))
        push!(buf, UInt8(':'), UInt8(' '))
        append!(buf, codeunits(h.value))
        push!(buf, UInt8('\r'), UInt8('\n'))
    end
    # Final CRLF
    push!(buf, UInt8('\r'), UInt8('\n'))
    trailer_mem = Memory{UInt8}(undef, length(buf))
    copyto!(trailer_mem, 1, buf, 1, length(buf))
    return H1Trailer(trailer_mem)
end

function h1_trailer_destroy!(trailer::H1Trailer)
    trailer.trailer_data = Memory{UInt8}(undef, 0)
    return nothing
end

# ─── H1 Encoder Message ───

mutable struct H1EncoderMessage
    outgoing_head_buf::Memory{UInt8}      # pre-encoded request/status line + headers
    body::Any                              # input stream for unchunked body
    pending_chunk_list::Vector{H1Chunk}    # queue of chunks for manual chunked API
    trailer::Union{H1Trailer, Nothing}
    content_length::UInt64
    has_connection_close_header::Bool
    has_chunked_encoding_header::Bool
    is_switching_protocols::Bool
end

function H1EncoderMessage()
    return H1EncoderMessage(Memory{UInt8}(undef, 0), nothing, H1Chunk[], nothing, UInt64(0), false, false, false)
end

# Internal: scan outgoing headers for validation and metadata extraction
function _scan_outgoing_headers!(
    encoder_message::H1EncoderMessage,
    message::HttpMessage,
    body_headers_ignored::Bool,
    body_headers_forbidden::Bool
)::Tuple{Int, Int}  # (status, header_lines_len)

    total = 0
    has_body_stream = http_message_get_body_stream(message) !== nothing
    has_content_length_header = false
    has_transfer_encoding_header = false

    n = http_message_get_header_count(message)
    for i in 0:(n - 1)
        h = http_message_get_header(message, i)
        h === nothing && continue

        # Validate header name is a token (RFC 7230 §3.2)
        if !is_http_token(h.name)
            return (raise_error(ERROR_HTTP_INVALID_HEADER_NAME), 0)
        end

        # Validate header value (trim whitespace first, per OWS rule)
        trimmed_val = trim_http_whitespace(h.value)
        if !is_http_field_value(trimmed_val)
            return (raise_error(ERROR_HTTP_INVALID_HEADER_VALUE), 0)
        end

        name_enum = http_str_to_header_name(h.name)

        if name_enum == HttpHeaderName.CONNECTION
            if lowercase(trimmed_val) == "close"
                encoder_message.has_connection_close_header = true
            end
        elseif name_enum == HttpHeaderName.CONTENT_LENGTH
            has_content_length_header = true
            cl = tryparse(UInt64, trimmed_val)
            if cl === nothing
                return (raise_error(ERROR_HTTP_INVALID_HEADER_VALUE), 0)
            end
            encoder_message.content_length = cl
        elseif name_enum == HttpHeaderName.TRANSFER_ENCODING
            has_transfer_encoding_header = true
            if isempty(trimmed_val)
                return (raise_error(ERROR_HTTP_INVALID_HEADER_VALUE), 0)
            end
            for part in eachsplit(trimmed_val, ',')
                t = strip(c -> c == ' ' || c == '\t', part)
                if isempty(t)
                    return (raise_error(ERROR_HTTP_INVALID_HEADER_VALUE), 0)
                end
                # If we already saw "chunked", then another encoding after it is invalid
                if encoder_message.has_chunked_encoding_header
                    return (raise_error(ERROR_HTTP_INVALID_HEADER_VALUE), 0)
                end
                if lowercase(String(t)) == "chunked"
                    encoder_message.has_chunked_encoding_header = true
                end
            end
        end

        # "name: value\r\n" = name.len + value.len + 4
        total += ncodeunits(h.name) + ncodeunits(h.value) + 4
    end

    # Transfer-Encoding present but doesn't include "chunked"
    if !encoder_message.has_chunked_encoding_header && has_transfer_encoding_header
        return (raise_error(ERROR_HTTP_INVALID_HEADER_VALUE), 0)
    end

    # Cannot have both Content-Length and Transfer-Encoding (RFC 7230)
    if encoder_message.has_chunked_encoding_header && has_content_length_header
        return (raise_error(ERROR_HTTP_INVALID_HEADER_FIELD), 0)
    end

    # Some responses forbid body headers entirely
    if body_headers_forbidden && (encoder_message.content_length > 0 || has_transfer_encoding_header)
        return (raise_error(ERROR_HTTP_INVALID_HEADER_FIELD), 0)
    end

    if body_headers_ignored
        encoder_message.content_length = UInt64(0)
        encoder_message.has_chunked_encoding_header = false
    end

    # Content-Length > 0 but no body stream
    if encoder_message.content_length > 0 && !has_body_stream
        return (raise_error(ERROR_HTTP_MISSING_BODY_STREAM), 0)
    end

    return (OP_SUCCESS, total)
end

# Internal: write all headers to buffer in "name: value\r\n" format
function _write_headers!(buf::Vector{UInt8}, headers::HttpHeaders)
    n = http_headers_count(headers)
    for i in 0:(n - 1)
        h = http_headers_get_index(headers, i)
        h === nothing && continue
        append!(buf, codeunits(h.name))
        push!(buf, UInt8(':'), UInt8(' '))
        append!(buf, codeunits(h.value))
        push!(buf, UInt8('\r'), UInt8('\n'))
    end
end

"""
    h1_encoder_message_init_from_request!(msg::H1EncoderMessage, request::HttpMessage) -> Int

Validate and pre-encode a request message for H1 encoding.
Pre-encodes "METHOD PATH HTTP/1.1\\r\\n" + headers + "\\r\\n" into outgoing_head_buf.
"""
function h1_encoder_message_init_from_request!(
    msg::H1EncoderMessage,
    request::HttpMessage;
    pending_chunk_list::Vector{H1Chunk}=H1Chunk[]
)::Int
    msg.body = http_message_get_body_stream(request)
    msg.pending_chunk_list = pending_chunk_list

    # Validate method
    method = http_message_get_request_method(request)
    if method === nothing
        raise_error(ERROR_HTTP_INVALID_METHOD)
        return _encoder_message_error_cleanup!(msg)
    end
    if !is_http_token(method)
        raise_error(ERROR_HTTP_INVALID_METHOD)
        return _encoder_message_error_cleanup!(msg)
    end

    # Validate path
    path = http_message_get_request_path(request)
    if path === nothing
        raise_error(ERROR_HTTP_INVALID_PATH)
        return _encoder_message_error_cleanup!(msg)
    end
    if !is_http_request_target(path)
        raise_error(ERROR_HTTP_INVALID_PATH)
        return _encoder_message_error_cleanup!(msg)
    end

    # Scan headers
    status, header_lines_len = _scan_outgoing_headers!(msg, request, false, false)
    if status != OP_SUCCESS
        return _encoder_message_error_cleanup!(msg)
    end

    version_str = "HTTP/1.1"

    # Pre-encode head: "METHOD PATH HTTP/1.1\r\n" + headers + "\r\n"
    request_line_len = ncodeunits(method) + 1 + ncodeunits(path) + 1 + ncodeunits(version_str) + 2
    total = request_line_len + header_lines_len + 2  # +2 for final CRLF

    buf = sizehint!(UInt8[], total)
    append!(buf, codeunits(method))
    push!(buf, UInt8(' '))
    append!(buf, codeunits(path))
    push!(buf, UInt8(' '))
    append!(buf, codeunits(version_str))
    push!(buf, UInt8('\r'), UInt8('\n'))

    _write_headers!(buf, http_message_get_headers(request))

    push!(buf, UInt8('\r'), UInt8('\n'))

    head_mem = Memory{UInt8}(undef, length(buf))
    copyto!(head_mem, 1, buf, 1, length(buf))
    msg.outgoing_head_buf = head_mem
    return OP_SUCCESS
end

function _encoder_message_error_cleanup!(msg::H1EncoderMessage)::Int
    h1_encoder_message_clean_up!(msg)
    return OP_ERR
end

"""
    h1_encoder_message_init_from_response!(msg::H1EncoderMessage, response::HttpMessage; body_headers_ignored=false) -> Int

Validate and pre-encode a response message for H1 encoding.
Pre-encodes "HTTP/1.1 STATUS REASON\\r\\n" + headers + "\\r\\n" into outgoing_head_buf.
"""
function h1_encoder_message_init_from_response!(
    msg::H1EncoderMessage,
    response::HttpMessage;
    body_headers_ignored::Bool=false,
    pending_chunk_list::Vector{H1Chunk}=H1Chunk[]
)::Int
    msg.body = http_message_get_body_stream(response)
    msg.pending_chunk_list = pending_chunk_list

    # Validate status
    status_int = http_message_get_response_status(response)
    if status_int === nothing
        return raise_error(ERROR_HTTP_INVALID_STATUS_CODE)
    end

    status_code_str = lpad(string(status_int), 3, '0')
    status_text = http_status_text(status_int)

    msg.is_switching_protocols = (status_int == HTTP_STATUS_CODE_101_SWITCHING_PROTOCOLS)

    # Body handling: 304 ignores body headers, 204 and 1xx forbid them
    body_headers_ignored = body_headers_ignored || (status_int == HTTP_STATUS_CODE_304_NOT_MODIFIED)
    body_headers_forbidden = (status_int == HTTP_STATUS_CODE_204_NO_CONTENT) || (div(status_int, 100) == 1)

    status, header_lines_len = _scan_outgoing_headers!(msg, response, body_headers_ignored, body_headers_forbidden)
    if status != OP_SUCCESS
        return _encoder_message_error_cleanup!(msg)
    end

    version_str = "HTTP/1.1"

    # Pre-encode head: "HTTP/1.1 STATUS REASON\r\n" + headers + "\r\n"
    response_line_len = ncodeunits(version_str) + 1 + ncodeunits(status_code_str) + 1 + ncodeunits(status_text) + 2
    total = response_line_len + header_lines_len + 2

    buf = sizehint!(UInt8[], total)
    append!(buf, codeunits(version_str))
    push!(buf, UInt8(' '))
    append!(buf, codeunits(status_code_str))
    push!(buf, UInt8(' '))
    append!(buf, codeunits(status_text))
    push!(buf, UInt8('\r'), UInt8('\n'))

    _write_headers!(buf, http_message_get_headers(response))

    push!(buf, UInt8('\r'), UInt8('\n'))

    head_mem = Memory{UInt8}(undef, length(buf))
    copyto!(head_mem, 1, buf, 1, length(buf))
    msg.outgoing_head_buf = head_mem
    return OP_SUCCESS
end

"""
    h1_encoder_message_clean_up!(msg::H1EncoderMessage)

Clean up encoder message resources.
"""
function h1_encoder_message_clean_up!(msg::H1EncoderMessage)
    msg.body = nothing
    msg.outgoing_head_buf = Memory{UInt8}(undef, 0)
    if msg.trailer !== nothing
        h1_trailer_destroy!(msg.trailer)
        msg.trailer = nothing
    end
    empty!(msg.pending_chunk_list)
    msg.content_length = UInt64(0)
    msg.has_connection_close_header = false
    msg.has_chunked_encoding_header = false
    msg.is_switching_protocols = false
    return nothing
end

# ─── H1 Encoder (state machine) ───

mutable struct H1Encoder
    state::H1EncoderState.T
    message::Union{H1EncoderMessage, Nothing}
    progress_bytes::UInt64
    current_chunk::Union{H1Chunk, Nothing}
    chunk_count::UInt64
    current_stream::Any  # for logging/callbacks context
end

"""
    h1_encoder_init() -> H1Encoder

Create a new H1 encoder in INIT state.
"""
function h1_encoder_init()::H1Encoder
    return H1Encoder(H1EncoderState.INIT, nothing, UInt64(0), nothing, UInt64(0), nothing)
end

"""
    h1_encoder_clean_up!(encoder::H1Encoder)

Reset encoder to initial state.
"""
function h1_encoder_clean_up!(encoder::H1Encoder)
    encoder.state = H1EncoderState.INIT
    encoder.message = nothing
    encoder.progress_bytes = UInt64(0)
    encoder.current_chunk = nothing
    encoder.chunk_count = UInt64(0)
    encoder.current_stream = nothing
    return nothing
end

"""
    h1_encoder_start_message!(encoder, message; stream=nothing) -> Int

Begin encoding a message. Returns OP_ERR if a message is already in progress.
"""
function h1_encoder_start_message!(encoder::H1Encoder, message::H1EncoderMessage; stream=nothing)::Int
    if encoder.message !== nothing
        return raise_error(ERROR_INVALID_STATE)
    end
    encoder.message = message
    encoder.current_stream = stream
    _switch_state!(encoder, H1EncoderState.INIT)
    return OP_SUCCESS
end

# Internal: switch state and reset progress
function _switch_state!(encoder::H1Encoder, new_state::H1EncoderState.T)
    encoder.state = new_state
    encoder.progress_bytes = UInt64(0)
    return nothing
end

# Internal: encode bytes from a pre-encoded buffer, tracking progress
# Returns true when entire source has been written
function _encode_buf!(encoder::H1Encoder, dst::IOBuffer, src::AbstractVector{UInt8})::Bool
    remaining = length(src) - encoder.progress_bytes
    remaining <= 0 && return true
    avail = dst.maxsize - position(dst)
    avail <= 0 && return false
    to_write = min(remaining, avail)
    start = Int(encoder.progress_bytes) + 1
    unsafe_write(dst, pointer(src, start), to_write)
    encoder.progress_bytes += to_write
    return encoder.progress_bytes >= length(src)
end

# Internal: read from input stream into dst buffer, tracking progress against expected length
# Returns (error::Int, done::Bool)
function _encode_stream!(encoder::H1Encoder, dst::IOBuffer, stream, total_length::UInt64)::Tuple{Int, Bool}
    avail = dst.maxsize - position(dst)
    avail <= 0 && return (OP_SUCCESS, false)

    # Read from stream into dst
    before_pos = position(dst)
    try
        buf = Vector{UInt8}(undef, avail)
        n = readbytes!(stream, buf, avail)
        if n > 0
            unsafe_write(dst, pointer(buf), n)
        end
    catch
        return (OP_ERR, false)
    end
    bytes_read = position(dst) - before_pos
    encoder.progress_bytes += bytes_read

    # Check we haven't exceeded expected length
    if encoder.progress_bytes > total_length
        raise_error(ERROR_HTTP_OUTGOING_STREAM_LENGTH_INCORRECT)
        return (OP_ERR, false)
    end

    if encoder.progress_bytes == total_length
        return (OP_SUCCESS, true)
    end

    # Check for premature EOF
    if bytes_read == 0 && eof(stream)
        if encoder.progress_bytes < total_length
            raise_error(ERROR_HTTP_OUTGOING_STREAM_LENGTH_INCORRECT)
            return (OP_ERR, false)
        end
    end

    return (OP_SUCCESS, false)
end

# Internal: write CRLF to buffer. Returns true if written.
function _write_crlf!(dst::IOBuffer)::Bool
    if dst.maxsize - position(dst) >= 2
        write(dst, UInt8('\r'))
        write(dst, UInt8('\n'))
        return true
    end
    return false
end

# ─── State functions ───

function _state_fn_init(encoder::H1Encoder, dst::IOBuffer)::Int
    if encoder.message === nothing
        return OP_SUCCESS  # wait for message
    end
    _switch_state!(encoder, H1EncoderState.HEAD)
    return OP_SUCCESS
end

function _state_fn_head(encoder::H1Encoder, dst::IOBuffer)::Int
    msg = encoder.message
    done = _encode_buf!(encoder, dst, msg.outgoing_head_buf)
    if !done
        return OP_SUCCESS  # remain in state
    end

    # Pick next state based on body type
    if msg.body !== nothing && msg.content_length > 0
        _switch_state!(encoder, H1EncoderState.UNCHUNKED_BODY_STREAM)
    elseif msg.body !== nothing && msg.has_chunked_encoding_header
        _switch_state!(encoder, H1EncoderState.CHUNKED_BODY_STREAM)
    elseif msg.body === nothing && msg.has_chunked_encoding_header
        _switch_state!(encoder, H1EncoderState.CHUNK_NEXT)
    else
        _switch_state!(encoder, H1EncoderState.DONE)
    end
    return OP_SUCCESS
end

function _state_fn_unchunked_body_stream(encoder::H1Encoder, dst::IOBuffer)::Int
    msg = encoder.message
    err, done = _encode_stream!(encoder, dst, msg.body, msg.content_length)
    err != OP_SUCCESS && return OP_ERR
    if done
        _switch_state!(encoder, H1EncoderState.DONE)
    end
    return OP_SUCCESS
end

function _state_fn_chunked_body_stream(encoder::H1Encoder, dst::IOBuffer)::Int
    msg = encoder.message
    # Chunked encoding with automatic chunk framing
    # Reserve space for: hex length (8 chars) + CRLF (2) at start, CRLF (2) at end
    padded_hex_len = 8
    chunk_prefix_len = padded_hex_len + 2  # hex + CRLF
    chunk_suffix_len = 2  # CRLF
    dont_bother_threshold = 128

    avail = dst.maxsize - position(dst)
    if avail < dont_bother_threshold
        if position(dst) == 0
            raise_error(ERROR_INVALID_STATE)
            return OP_ERR
        end
        return OP_SUCCESS  # wait for fresh buffer
    end

    # Calculate how much body we can fit
    max_body = avail - chunk_prefix_len - chunk_suffix_len
    max_body = min(max_body, typemax(UInt32))  # fits in 8 hex chars

    # Read body into temp buffer
    body_buf = Vector{UInt8}(undef, max_body)
    body_len = 0
    try
        body_len = readbytes!(msg.body, body_buf, max_body)
    catch
        return OP_ERR
    end

    if body_len > 0
        encoder.chunk_count += 1
        # Write chunk prefix: hex length + CRLF
        hex_str = uppercase(lpad(string(body_len, base=16), padded_hex_len, '0'))
        write(dst, hex_str)
        write(dst, "\r\n")
        # Write body
        unsafe_write(dst, pointer(body_buf), body_len)
        # Write chunk suffix: CRLF
        write(dst, "\r\n")
    end

    # Check if stream ended
    if body_len < max_body
        if eof(msg.body)
            encoder.chunk_count += 1
            _switch_state!(encoder, H1EncoderState.CHUNKED_BODY_STREAM_LAST_CHUNK)
        end
    end

    return OP_SUCCESS
end

function _state_fn_chunked_body_stream_last_chunk(encoder::H1Encoder, dst::IOBuffer)::Int
    # Write "0\r\n" (last chunk marker)
    if dst.maxsize - position(dst) >= 3
        write(dst, "0\r\n")
        _switch_state!(encoder, H1EncoderState.CHUNK_TRAILER)
    end
    return OP_SUCCESS
end

function _state_fn_chunk_next(encoder::H1Encoder, dst::IOBuffer)::Int
    msg = encoder.message
    if isempty(msg.pending_chunk_list)
        return OP_SUCCESS  # wait for more chunks
    end

    # Pop first chunk
    encoder.current_chunk = popfirst!(msg.pending_chunk_list)
    encoder.chunk_count += 1
    _switch_state!(encoder, H1EncoderState.CHUNK_LINE)
    return OP_SUCCESS
end

function _state_fn_chunk_line(encoder::H1Encoder, dst::IOBuffer)::Int
    chunk = encoder.current_chunk
    done = _encode_buf!(encoder, dst, chunk.chunk_line)
    if !done
        return OP_SUCCESS
    end

    if chunk.data_size == 0
        # Final chunk (no body), move to trailer
        _clean_up_current_chunk!(encoder, 0)
        _switch_state!(encoder, H1EncoderState.CHUNK_TRAILER)
    else
        _switch_state!(encoder, H1EncoderState.CHUNK_BODY)
    end
    return OP_SUCCESS
end

function _state_fn_chunk_body(encoder::H1Encoder, dst::IOBuffer)::Int
    chunk = encoder.current_chunk
    err, done = _encode_stream!(encoder, dst, chunk.data, chunk.data_size)
    if err != OP_SUCCESS
        error_code = Reseau.last_error()
        _clean_up_current_chunk!(encoder, error_code)
        raise_error(error_code)
        return OP_ERR
    end
    if done
        _switch_state!(encoder, H1EncoderState.CHUNK_END)
    end
    return OP_SUCCESS
end

function _state_fn_chunk_end(encoder::H1Encoder, dst::IOBuffer)::Int
    done = _write_crlf!(dst)
    if !done
        return OP_SUCCESS
    end
    _clean_up_current_chunk!(encoder, 0)
    _switch_state!(encoder, H1EncoderState.CHUNK_NEXT)
    return OP_SUCCESS
end

function _state_fn_chunk_trailer(encoder::H1Encoder, dst::IOBuffer)::Int
    msg = encoder.message
    if msg.trailer !== nothing
        done = _encode_buf!(encoder, dst, msg.trailer.trailer_data)
    else
        done = _write_crlf!(dst)
    end
    if !done
        return OP_SUCCESS
    end
    _switch_state!(encoder, H1EncoderState.DONE)
    return OP_SUCCESS
end

function _state_fn_done(encoder::H1Encoder, dst::IOBuffer)::Int
    encoder.message = nothing
    _switch_state!(encoder, H1EncoderState.INIT)
    return OP_SUCCESS
end

# Internal: clean up current chunk after encoding
function _clean_up_current_chunk!(encoder::H1Encoder, error_code::Int)
    chunk = encoder.current_chunk
    encoder.current_chunk = nothing
    if chunk !== nothing
        h1_chunk_complete_and_destroy!(chunk, error_code)
    end
    return nothing
end

# State dispatch table
const _ENCODER_STATE_FNS = (
    _state_fn_init,                          # INIT = 0
    _state_fn_head,                          # HEAD = 1
    _state_fn_unchunked_body_stream,         # UNCHUNKED_BODY_STREAM = 2
    _state_fn_chunked_body_stream,           # CHUNKED_BODY_STREAM = 3
    _state_fn_chunked_body_stream_last_chunk,# CHUNKED_BODY_STREAM_LAST_CHUNK = 4
    _state_fn_chunk_next,                    # CHUNK_NEXT = 5
    _state_fn_chunk_line,                    # CHUNK_LINE = 6
    _state_fn_chunk_body,                    # CHUNK_BODY = 7
    _state_fn_chunk_end,                     # CHUNK_END = 8
    _state_fn_chunk_trailer,                 # CHUNK_TRAILER = 9
    _state_fn_done,                          # DONE = 10
)

"""
    h1_encoder_process!(encoder::H1Encoder, dst::IOBuffer) -> Int

Run the encoder state machine, writing encoded bytes to `dst`.
Runs until state stops changing (buffer full, stream stalled, or waiting for chunks).
Returns OP_SUCCESS or OP_ERR.
"""
function h1_encoder_process!(encoder::H1Encoder, dst::IOBuffer)::Int
    if encoder.message === nothing
        raise_error(ERROR_INVALID_STATE)
        return OP_ERR
    end

    # Run state machine until state stops changing
    while true
        prev_state = encoder.state
        state_idx = Int(UInt8(encoder.state)) + 1  # 0-based enum -> 1-based index
        fn = _ENCODER_STATE_FNS[state_idx]
        if fn(encoder, dst) != OP_SUCCESS
            return OP_ERR
        end
        if encoder.state == prev_state
            break
        end
    end

    return OP_SUCCESS
end

"""
    h1_encoder_is_message_in_progress(encoder::H1Encoder) -> Bool

Returns true if a message is currently being encoded.
"""
h1_encoder_is_message_in_progress(encoder::H1Encoder)::Bool = encoder.message !== nothing

"""
    h1_encoder_is_waiting_for_chunks(encoder::H1Encoder) -> Bool

Returns true if encoder is stalled in CHUNK_NEXT with no pending chunks.
"""
function h1_encoder_is_waiting_for_chunks(encoder::H1Encoder)::Bool
    return encoder.state == H1EncoderState.CHUNK_NEXT &&
           encoder.message !== nothing &&
           isempty(encoder.message.pending_chunk_list)
end
