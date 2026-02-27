# HTTP/1.1 Decoder - State machine decoder for requests and responses
# Port of aws-c-http/source/h1_decoder.c, h1_decoder.h

# ─── Transfer encoding bitflags (RFC 7230 §4.2) ───

const HTTP_TRANSFER_ENCODING_CHUNKED = 1 << 0
const HTTP_TRANSFER_ENCODING_GZIP = 1 << 1
const HTTP_TRANSFER_ENCODING_DEFLATE = 1 << 2
const HTTP_TRANSFER_ENCODING_DEPRECATED_COMPRESS = 1 << 3

# ─── HTTP reason-phrase validation (RFC 7230 §3.1.2) ───
# reason-phrase = *(HTAB / SP / VCHAR / obs-text)
# Uses same character table as field-content

"""
    is_http_reason_phrase(s) -> Bool

Validate that `s` is a valid HTTP reason-phrase per RFC 7230 §3.1.2.
Empty string is valid. Allows HTAB, SP, VCHAR (0x21-0x7E), and obs-text (0x80-0xFF).
"""
function is_http_reason_phrase(s::AbstractString)::Bool
    for c in codeunits(String(s))
        @inbounds _HTTP_FIELD_CONTENT_CHARS[c + 1] || return false
    end
    return true
end

# ─── Decoded header struct ───

struct H1DecodedHeader
    name::HttpHeaderName.T
    name_data::String
    value_data::String
    data::String
end

# ─── Decoder params ───

struct H1DecoderParams
    scratch_space_initial_size::Int
    is_decoding_requests::Bool
end

# ─── Decoder state enum ───

@enumx H1DecoderState::UInt8 begin
    GETLINE_REQUEST = 0
    GETLINE_RESPONSE = 1
    GETLINE_HEADER = 2
    GETLINE_CHUNK_SIZE = 3
    GETLINE_CHUNK_TERMINATOR = 4
    UNCHUNKED_BODY = 5
    CHUNK = 6
    CONNECTION_CLOSE_BODY = 7
end

# ─── H1 Decoder ───

mutable struct H1Decoder
    scratch_space::Vector{UInt8}
    state::H1DecoderState.T
    transfer_encoding::Int
    content_processed::UInt64
    content_length::UInt64
    chunk_processed::UInt64
    chunk_size::UInt64
    doing_trailers::Bool
    is_done::Bool
    body_headers_ignored::Bool
    body_headers_forbidden::Bool
    content_length_received::Bool
    connection_close_detected::Bool
    header_block::HttpHeaderBlock.T
    stop_processing::Bool
    # late-init: consumer-specific state (for connection-level callbacks)
    context::Union{Nothing, HttpConnection}
    is_decoding_requests::Bool
end

h1_decoder_on_header(::H1Decoder, _)::Int = OP_SUCCESS
h1_decoder_on_body(::H1Decoder, _, ::Bool)::Int = OP_SUCCESS
h1_decoder_on_request(::H1Decoder, _, _, _)::Int = OP_SUCCESS
h1_decoder_on_response(::H1Decoder, _)::Int = OP_SUCCESS
h1_decoder_on_done(_)::Int = OP_SUCCESS

"""
    h1_decoder_new(params::H1DecoderParams) -> H1Decoder

Create a new HTTP/1.1 decoder.
"""
function h1_decoder_new(params::H1DecoderParams)::H1Decoder
    decoder = H1Decoder(
        sizehint!(UInt8[], params.scratch_space_initial_size),
        H1DecoderState.GETLINE_REQUEST,
        0, UInt64(0), UInt64(0), UInt64(0), UInt64(0),
        false, false, false, false, false, false,
        HttpHeaderBlock.MAIN,
        false,
        nothing,
        params.is_decoding_requests,
    )
    _reset_state!(decoder)
    return decoder
end

"""
    h1_decoder_destroy!(decoder::H1Decoder)

Destroy the decoder and free resources.
"""
function h1_decoder_destroy!(decoder::H1Decoder)
    empty!(decoder.scratch_space)
    return nothing
end

# Internal: reset state for processing a new message
function _reset_state!(decoder::H1Decoder)
    if decoder.is_decoding_requests
        _decoder_set_state!(decoder, H1DecoderState.GETLINE_REQUEST)
    else
        _decoder_set_state!(decoder, H1DecoderState.GETLINE_RESPONSE)
    end
    decoder.transfer_encoding = 0
    decoder.content_processed = UInt64(0)
    decoder.content_length = UInt64(0)
    decoder.chunk_processed = UInt64(0)
    decoder.chunk_size = UInt64(0)
    decoder.doing_trailers = false
    decoder.is_done = false
    decoder.body_headers_ignored = false
    decoder.body_headers_forbidden = false
    decoder.content_length_received = false
    decoder.connection_close_detected = false
    decoder.header_block = HttpHeaderBlock.MAIN
    decoder.stop_processing = false
    return nothing
end

# Internal: change state and clear scratch space
function _decoder_set_state!(decoder::H1Decoder, state::H1DecoderState.T)
    empty!(decoder.scratch_space)
    decoder.state = state
    return nothing
end

# Internal: mark message as done, call on_done callback
function _mark_done!(decoder::H1Decoder)::Int
    decoder.is_done = true
    return h1_decoder_on_done(decoder)
end

# ─── CRLF scanning ───

# Scan data[pos:end_pos] for \r\n, checking scratch_space boundary for split \r\n.
# Returns (found_crlf, bytes_to_consume_from_pos).
function _scan_for_crlf(decoder::H1Decoder, data::AbstractVector{UInt8}, pos::Int, end_pos::Int)::Tuple{Bool, Int}
    idx = pos
    while idx <= end_pos
        if data[idx] == UInt8('\n')
            prev_char = if idx == pos
                !isempty(decoder.scratch_space) ? decoder.scratch_space[end] : UInt8(0)
            else
                data[idx - 1]
            end
            if prev_char == UInt8('\r')
                return (true, idx - pos + 1)
            end
        end
        idx += 1
    end
    return (false, end_pos - pos + 1)
end

# ─── State: getline ───

# Accumulate data in scratch_space until CRLF is found, then dispatch to line processor.
function _state_getline!(decoder::H1Decoder, data::AbstractVector{UInt8}, pos::Ref{Int}, end_pos::Int)::Int
    has_prev_data = !isempty(decoder.scratch_space)

    found_crlf, consume_len = _scan_for_crlf(decoder, data, pos[], end_pos)

    consumed_start = pos[]
    consumed_end = consumed_start + consume_len - 1
    pos[] += consume_len

    use_scratch = !found_crlf || has_prev_data
    if use_scratch
        append!(decoder.scratch_space, @view data[consumed_start:consumed_end])
    end

    if found_crlf
        line_bytes = use_scratch ? decoder.scratch_space : @view(data[consumed_start:consumed_end])
        # Convert to String before state change clears scratch_space; strip trailing \r\n
        line_str = String(Vector{UInt8}(@view line_bytes[1:length(line_bytes)-2]))
        return _dispatch_line_processor!(decoder, line_str)
    end

    return OP_SUCCESS
end

# ─── State: unchunked body ───

function _state_unchunked_body!(decoder::H1Decoder, data::AbstractVector{UInt8}, pos::Ref{Int}, end_pos::Int)::Int
    remaining_input = end_pos - pos[] + 1
    remaining_input <= 0 && return OP_SUCCESS

    remaining_content = decoder.content_length - decoder.content_processed
    processed_bytes = min(remaining_content, UInt64(remaining_input))

    decoder.content_processed += processed_bytes
    finished = decoder.content_processed == decoder.content_length

    body_start = pos[]
    body_end = body_start + Int(processed_bytes) - 1
    pos[] += Int(processed_bytes)

    err = h1_decoder_on_body(decoder, @view(data[body_start:body_end]), finished)
    err != OP_SUCCESS && return OP_ERR

    if finished
        err = _mark_done!(decoder)
        err != OP_SUCCESS && return OP_ERR
    end

    return OP_SUCCESS
end

# ─── State: chunk body ───

function _state_chunk!(decoder::H1Decoder, data::AbstractVector{UInt8}, pos::Ref{Int}, end_pos::Int)::Int
    remaining_input = end_pos - pos[] + 1
    remaining_input <= 0 && return OP_SUCCESS

    remaining_chunk = decoder.chunk_size - decoder.chunk_processed
    processed_bytes = min(remaining_chunk, UInt64(remaining_input))

    decoder.chunk_processed += processed_bytes
    finished = decoder.chunk_processed == decoder.chunk_size

    body_start = pos[]
    body_end = body_start + Int(processed_bytes) - 1
    pos[] += Int(processed_bytes)

    err = h1_decoder_on_body(decoder, @view(data[body_start:body_end]), false)
    err != OP_SUCCESS && return OP_ERR

    if finished
        _decoder_set_state!(decoder, H1DecoderState.GETLINE_CHUNK_TERMINATOR)
    end

    return OP_SUCCESS
end

# ─── State: connection-close body (read until EOF) ───

function _state_connection_close_body!(decoder::H1Decoder, data::AbstractVector{UInt8}, pos::Ref{Int}, end_pos::Int)::Int
    remaining_input = end_pos - pos[] + 1
    remaining_input <= 0 && return OP_SUCCESS

    body_start = pos[]
    body_end = end_pos
    pos[] = end_pos + 1
    decoder.content_processed += UInt64(remaining_input)

    # Not finished yet — caller must signal EOF via h1_decoder_signal_eof!
    err = h1_decoder_on_body(decoder, @view(data[body_start:body_end]), false)
    err != OP_SUCCESS && return OP_ERR

    return OP_SUCCESS
end

# ─── State dispatch ───

function _run_state!(decoder::H1Decoder, data::AbstractVector{UInt8}, pos::Ref{Int}, end_pos::Int)::Int
    state = decoder.state
    if state == H1DecoderState.GETLINE_REQUEST ||
       state == H1DecoderState.GETLINE_RESPONSE ||
       state == H1DecoderState.GETLINE_HEADER ||
       state == H1DecoderState.GETLINE_CHUNK_SIZE ||
       state == H1DecoderState.GETLINE_CHUNK_TERMINATOR
        return _state_getline!(decoder, data, pos, end_pos)
    elseif state == H1DecoderState.UNCHUNKED_BODY
        return _state_unchunked_body!(decoder, data, pos, end_pos)
    elseif state == H1DecoderState.CHUNK
        return _state_chunk!(decoder, data, pos, end_pos)
    elseif state == H1DecoderState.CONNECTION_CLOSE_BODY
        return _state_connection_close_body!(decoder, data, pos, end_pos)
    end
    return OP_SUCCESS
end

# ─── Line processor dispatch ───

function _dispatch_line_processor!(decoder::H1Decoder, line::String)::Int
    state = decoder.state
    if state == H1DecoderState.GETLINE_REQUEST
        return _linestate_request!(decoder, line)
    elseif state == H1DecoderState.GETLINE_RESPONSE
        return _linestate_response!(decoder, line)
    elseif state == H1DecoderState.GETLINE_HEADER
        return _linestate_header!(decoder, line)
    elseif state == H1DecoderState.GETLINE_CHUNK_SIZE
        return _linestate_chunk_size!(decoder, line)
    elseif state == H1DecoderState.GETLINE_CHUNK_TERMINATOR
        return _linestate_chunk_terminator!(decoder, line)
    end
    return OP_SUCCESS
end

# ─── Line state: request line ───

function _linestate_request!(decoder::H1Decoder, line::String)::Int
    # METHOD SP URI SP VERSION — exactly 3 parts split by space
    parts = split(line, ' ')
    length(parts) != 3 && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

    method_str = String(parts[1])
    uri_str = String(parts[2])
    version_str = String(parts[3])

    # All parts must be non-empty
    (isempty(method_str) || isempty(uri_str) || isempty(version_str)) &&
        return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

    # Validate method, URI, version
    !is_http_token(method_str) && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)
    !is_http_request_target(uri_str) && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)
    version_str != "HTTP/1.1" && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

    method_enum = http_str_to_method(method_str)
    err = h1_decoder_on_request(decoder, method_enum, method_str, uri_str)
    err != OP_SUCCESS && return OP_ERR

    _decoder_set_state!(decoder, H1DecoderState.GETLINE_HEADER)
    return OP_SUCCESS
end

# ─── Line state: response line ───

function _linestate_response!(decoder::H1Decoder, line::String)::Int
    # VERSION SP STATUS SP PHRASE — phrase may contain spaces
    parts = split(line, ' ', limit=3)
    length(parts) < 3 && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

    version_str = String(parts[1])
    code_str = String(parts[2])
    phrase_str = String(parts[3])

    # Version must be HTTP/1.0 or HTTP/1.1
    (version_str != "HTTP/1.1" && version_str != "HTTP/1.0") &&
        return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

    # Validate reason phrase
    !is_http_reason_phrase(phrase_str) && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

    # Status code must be exactly 3 ASCII digits
    length(code_str) != 3 && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)
    all(isdigit, code_str) || return raise_error(ERROR_HTTP_PROTOCOL_ERROR)
    code_val = tryparse(Int, code_str)
    (code_val === nothing || code_val > 999) && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

    # Body handling rules (RFC 7230 §3.3)
    decoder.body_headers_ignored |= (code_val == HTTP_STATUS_CODE_304_NOT_MODIFIED)
    decoder.body_headers_forbidden = (code_val == HTTP_STATUS_CODE_204_NO_CONTENT) || div(code_val, 100) == 1

    # Informational (1xx) header block
    if code_val >= 100 && code_val < 200
        decoder.header_block = HttpHeaderBlock.INFORMATIONAL
    end

    err = h1_decoder_on_response(decoder, code_val)
    err != OP_SUCCESS && return OP_ERR

    _decoder_set_state!(decoder, H1DecoderState.GETLINE_HEADER)
    return OP_SUCCESS
end

# ─── Line state: header ───

function _linestate_header!(decoder::H1Decoder, line::String)::Int
    # Empty line = end of headers section
    if isempty(line)
        if !decoder.doing_trailers
            if decoder.body_headers_ignored
                return _mark_done!(decoder)
            elseif decoder.transfer_encoding & HTTP_TRANSFER_ENCODING_CHUNKED != 0
                _decoder_set_state!(decoder, H1DecoderState.GETLINE_CHUNK_SIZE)
            elseif decoder.content_length_received && decoder.content_length > 0
                _decoder_set_state!(decoder, H1DecoderState.UNCHUNKED_BODY)
            elseif decoder.content_length_received && decoder.content_length == 0
                # Explicit Content-Length: 0 means no body
                return _mark_done!(decoder)
            elseif !decoder.is_decoding_requests && decoder.connection_close_detected
                # Response with Connection: close and no explicit body length:
                # read body until connection closes (RFC 7230 §3.3.3 rule 7)
                _decoder_set_state!(decoder, H1DecoderState.CONNECTION_CLOSE_BODY)
            else
                return _mark_done!(decoder)
            end
        else
            return _mark_done!(decoder)
        end
        return OP_SUCCESS
    end

    # Parse "Name: Value" — split on first colon
    colon_idx = findfirst(':', line)
    colon_idx === nothing && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

    name_str = SubString(line, 1, colon_idx - 1)
    value_raw = SubString(line, colon_idx + 1)

    # Validate name is HTTP token
    !is_http_token(name_str) && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

    # Trim HTTP whitespace from value, then validate
    trimmed_value = trim_http_whitespace(value_raw)
    !is_http_field_value(trimmed_value) && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

    # Build decoded header
    name_enum = http_str_to_header_name(name_str)
    header = H1DecodedHeader(name_enum, String(name_str), trimmed_value, line)

    # Detect special headers
    if name_enum == HttpHeaderName.CONTENT_LENGTH
        decoder.content_length_received && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)
        decoder.transfer_encoding != 0 && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

        cl = tryparse(UInt64, trimmed_value)
        cl === nothing && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

        (decoder.body_headers_forbidden && cl != 0) && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

        decoder.content_length = cl
        decoder.content_length_received = true

    elseif name_enum == HttpHeaderName.CONNECTION
        if lowercase(trimmed_value) == "close"
            decoder.connection_close_detected = true
        end

    elseif name_enum == HttpHeaderName.TRANSFER_ENCODING
        decoder.content_length_received && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)
        decoder.body_headers_forbidden && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

        # Parse comma-separated transfer codings (RFC 7230 §3.3.1, §4.2)
        for part in eachsplit(trimmed_value, ',')
            coding = strip(c -> c == ' ' || c == '\t', part)

            # Chunked must be last — anything after it is illegal
            (decoder.transfer_encoding & HTTP_TRANSFER_ENCODING_CHUNKED != 0) &&
                return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

            coding_lower = lowercase(String(coding))
            if coding_lower == "chunked"
                decoder.transfer_encoding |= HTTP_TRANSFER_ENCODING_CHUNKED
            elseif coding_lower == "compress" || coding_lower == "x-compress"
                decoder.transfer_encoding |= HTTP_TRANSFER_ENCODING_DEPRECATED_COMPRESS
            elseif coding_lower == "deflate"
                decoder.transfer_encoding |= HTTP_TRANSFER_ENCODING_DEFLATE
            elseif coding_lower == "gzip" || coding_lower == "x-gzip"
                decoder.transfer_encoding |= HTTP_TRANSFER_ENCODING_GZIP
            elseif !isempty(coding)
                return raise_error(ERROR_HTTP_PROTOCOL_ERROR)  # unknown coding
            else
                return raise_error(ERROR_HTTP_PROTOCOL_ERROR)  # blank entry
            end
        end
    end

    # Call on_header callback
    err = h1_decoder_on_header(decoder, header)
    err != OP_SUCCESS && return OP_ERR

    _decoder_set_state!(decoder, H1DecoderState.GETLINE_HEADER)
    return OP_SUCCESS
end

# ─── Line state: chunk size ───

function _linestate_chunk_size!(decoder::H1Decoder, line::String)::Int
    # Split on ';' to separate size from optional extensions
    semi_idx = findfirst(';', line)
    size_str = semi_idx !== nothing ? SubString(line, 1, semi_idx - 1) : line

    # Strict hex validation — no whitespace, no 0x prefix
    isempty(size_str) && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)
    for c in size_str
        ('0' <= c <= '9' || 'a' <= c <= 'f' || 'A' <= c <= 'F') ||
            return raise_error(ERROR_HTTP_PROTOCOL_ERROR)
    end

    chunk_size = tryparse(UInt64, String(size_str), base=16)
    chunk_size === nothing && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)

    decoder.chunk_size = chunk_size
    decoder.chunk_processed = UInt64(0)

    # Zero-size chunk = final chunk
    if chunk_size == 0
        err = h1_decoder_on_body(decoder, UInt8[], true)
        err != OP_SUCCESS && return OP_ERR

        # Expect trailers (or empty line to end message)
        decoder.doing_trailers = true
        _decoder_set_state!(decoder, H1DecoderState.GETLINE_HEADER)
        return OP_SUCCESS
    end

    # Non-zero chunk: read chunk body
    _decoder_set_state!(decoder, H1DecoderState.CHUNK)
    return OP_SUCCESS
end

# ─── Line state: chunk terminator ───

function _linestate_chunk_terminator!(decoder::H1Decoder, line::String)::Int
    # Expect empty line (CRLF already stripped)
    !isempty(line) && return raise_error(ERROR_HTTP_PROTOCOL_ERROR)
    _decoder_set_state!(decoder, H1DecoderState.GETLINE_CHUNK_SIZE)
    return OP_SUCCESS
end

# ─── Main decode function ───

"""
    h1_decode!(decoder::H1Decoder, data::AbstractVector{UInt8}) -> Tuple{Int, Int}

Feed data to the decoder. Returns `(status, bytes_consumed)`.
Callbacks fire as parsing completes. After a complete message, the decoder auto-resets.
On error, returns `(OP_ERR, 0)`.
"""
function h1_decode!(decoder::H1Decoder, data::AbstractVector{UInt8})::Tuple{Int, Int}
    pos = Ref(1)
    end_pos = length(data)

    # Outer loop: after a complete message, reset and continue processing
    # remaining data (e.g., 200 OK after 100 Continue, or pipelined responses).
    while pos[] <= end_pos
        while pos[] <= end_pos && !decoder.is_done
            err = _run_state!(decoder, data, pos, end_pos)
            if err != OP_SUCCESS
                return (OP_ERR, 0)
            end
        end

        if decoder.is_done
            if decoder.stop_processing
                break
            end
            _reset_state!(decoder)
        else
            break  # Need more data
        end
    end

    consumed = pos[] - 1
    return (OP_SUCCESS, consumed)
end

# Convenience: decode from a string
function h1_decode!(decoder::H1Decoder, data::AbstractString)::Tuple{Int, Int}
    return h1_decode!(decoder, Vector{UInt8}(codeunits(String(data))))
end

# ─── Query functions ───

"""Return transfer encoding bitflags (HTTP_TRANSFER_ENCODING_*)."""
h1_decoder_get_encoding_flags(decoder::H1Decoder)::Int = decoder.transfer_encoding

"""Return the parsed Content-Length value."""
h1_decoder_get_content_length(decoder::H1Decoder)::UInt64 = decoder.content_length

"""Return whether body headers are being ignored (HEAD response, 304)."""
h1_decoder_get_body_headers_ignored(decoder::H1Decoder)::Bool = decoder.body_headers_ignored

"""Return the current header block type (MAIN, INFORMATIONAL, TRAILING)."""
h1_decoder_get_header_block(decoder::H1Decoder)::HttpHeaderBlock.T = decoder.header_block

function h1_decoder_set_context!(decoder::H1Decoder, context::Union{Nothing, HttpConnection})::Nothing
    decoder.context = context
    return nothing
end

"""Set whether body headers should be ignored (for HEAD responses)."""
function h1_decoder_set_body_headers_ignored!(decoder::H1Decoder, ignored::Bool)
    decoder.body_headers_ignored = ignored
    return nothing
end

function h1_decoder_stop_processing!(decoder::H1Decoder)::Nothing
    decoder.stop_processing = true
    return nothing
end

"""
    h1_decoder_signal_eof!(decoder::H1Decoder) -> Int

Signal that the connection has closed (EOF). For connection-close body mode,
this fires the final on_body callback with finished=true and marks the message done.
"""
function h1_decoder_signal_eof!(decoder::H1Decoder)::Int
    if decoder.state != H1DecoderState.CONNECTION_CLOSE_BODY
        return raise_error(ERROR_INVALID_STATE)
    end
    err = h1_decoder_on_body(decoder, UInt8[], true)
    err != OP_SUCCESS && return OP_ERR
    return _mark_done!(decoder)
end
