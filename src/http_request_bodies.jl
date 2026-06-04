# Request-body normalization helpers shared by the high-level client entrypoints.

struct _NormalizedRequestBody{B<:AbstractBody}
    body::B
    content_length::Int64
    default_content_type::Union{Nothing,String}
    replayable::Bool
end

function _normalized_request_body(
    body::B,
    content_length::Integer;
    default_content_type::Union{Nothing,AbstractString}=nothing,
    replayable::Bool,
) where {B<:AbstractBody}
    return _NormalizedRequestBody{B}(body, Int64(content_length), default_content_type === nothing ? nothing : String(default_content_type), replayable)
end

@inline function _is_unreserved_form_byte(b::UInt8)::Bool
    return (
        (b >= UInt8('A') && b <= UInt8('Z')) ||
        (b >= UInt8('a') && b <= UInt8('z')) ||
        (b >= UInt8('0') && b <= UInt8('9')) ||
        b == UInt8('-') ||
        b == UInt8('.') ||
        b == UInt8('_') ||
        b == UInt8('~')
    )
end

function _percent_encode_form_component(value)::String
    text = string(value)
    encoded = IOBuffer()
    for b in codeunits(text)
        if b == UInt8(' ')
            # application/x-www-form-urlencoded serializes SP as '+' (WHATWG URL
            # standard). A literal '+' is not an unreserved form byte, so it still
            # percent-encodes to %2B below, keeping the round-trip unambiguous.
            write(encoded, UInt8('+'))
        elseif _is_unreserved_form_byte(b)
            write(encoded, b)
        else
            print(encoded, '%')
            nibble1 = uppercase(string((b >> 4) & 0x0f, base=16))
            nibble2 = uppercase(string(b & 0x0f, base=16))
            write(encoded, nibble1)
            write(encoded, nibble2)
        end
    end
    return String(take!(encoded))
end

function _form_urlencode(body_input)::Vector{UInt8}
    encoded = IOBuffer()
    first_pair = true
    for (k, v) in pairs(body_input)
        first_pair || write(encoded, '&')
        first_pair = false
        write(encoded, _percent_encode_form_component(k))
        write(encoded, '=')
        write(encoded, _percent_encode_form_component(v))
    end
    return take!(encoded)
end

function _remaining_bytes_body(body::BytesBody)::Vector{UInt8}
    remaining = (length(body.data) - body.next_index) + 1
    remaining <= 0 && return UInt8[]
    copied = Vector{UInt8}(undef, remaining)
    copyto!(copied, 1, body.data, body.next_index, remaining)
    return copied
end

function _materialize_request_body_bytes(body_input)
    body_input isa EmptyBody && return UInt8[], nothing
    body_input isa BytesBody && return _remaining_bytes_body(body_input::BytesBody), nothing
    if body_input isa AbstractString
        return codeunits(String(body_input)), nothing
    end
    if body_input isa AbstractVector{UInt8}
        return body_input, nothing
    end
    if body_input isa AbstractDict || body_input isa NamedTuple
        return _form_urlencode(body_input), "application/x-www-form-urlencoded"
    end
    if body_input isa Form
        payload = read(Form(body_input))
        return payload, content_type(body_input::Form)
    end
    if body_input isa IO
        return read(body_input), nothing
    end
    throw(ArgumentError("unsupported request body type $(typeof(body_input))"))
end

function _normalize_body_chunk(chunk)
    chunk === nothing && return UInt8[]
    if chunk isa AbstractString
        return codeunits(String(chunk))
    end
    if chunk isa AbstractVector{UInt8}
        return chunk
    end
    if chunk isa AbstractDict || chunk isa NamedTuple || chunk isa Form || chunk isa IO || chunk isa EmptyBody || chunk isa BytesBody
        bytes, _ = _materialize_request_body_bytes(chunk)
        return bytes
    end
    throw(ArgumentError("unsupported iterable request body chunk type $(typeof(chunk)); expected String, Vector{UInt8}, IO, Dict, NamedTuple, Form, or nothing"))
end

function _streaming_io_body(io::IO)
    return CallbackBody(
        dst -> begin
            isempty(dst) && return 0
            return readbytes!(io, dst, length(dst))
        end,
        () -> nothing,
    )
end

function _iterable_body(iterable)
    started = Ref(false)
    state = Ref{Any}(nothing)
    current = Ref{AbstractVector{UInt8}}(UInt8[])
    next_index = Ref(1)
    done = Ref(false)
    return CallbackBody(
        dst -> begin
            done[] && return 0
            isempty(dst) && return 0
            written = 0
            while written < length(dst)
                if next_index[] > length(current[])
                    next_item = if started[]
                        iterate(iterable, state[])
                    else
                        started[] = true
                        iterate(iterable)
                    end
                    if next_item === nothing
                        done[] = true
                        return written
                    end
                    chunk, st = next_item
                    state[] = st
                    current[] = _normalize_body_chunk(chunk)
                    next_index[] = 1
                    isempty(current[]) && continue
                end
                available = (length(current[]) - next_index[]) + 1
                n = min(length(dst) - written, available)
                copyto!(dst, written + 1, current[], next_index[], n)
                next_index[] += n
                written += n
            end
            return written
        end,
        () -> nothing,
    )
end

@inline function _body_replayable(body::AbstractBody)::Bool
    return body isa EmptyBody || body isa BytesBody
end

@inline function _should_buffer_request_io(io::IO)::Bool
    return io isa IOStream || io isa IOBuffer
end

function _buffered_request_body(body_input)
    bytes, default_content_type = _materialize_request_body_bytes(body_input)
    return _normalized_request_body(BytesBody(bytes), length(bytes); default_content_type=default_content_type, replayable=true)
end

function _normalize_body_input(body_input)
    body_input === nothing && return _normalized_request_body(EmptyBody(), 0; replayable=true)
    body_input isa EmptyBody && return _normalized_request_body(EmptyBody(), 0; replayable=true)
    if body_input isa BytesBody
        cloned = _clone_bytes_body(body_input::BytesBody)
        remaining = (length(cloned.data) - cloned.next_index) + 1
        return _normalized_request_body(cloned, max(0, remaining); replayable=true)
    end
    if body_input isa AbstractString ||
       body_input isa AbstractVector{UInt8} ||
       body_input isa AbstractDict ||
       body_input isa NamedTuple ||
       body_input isa Form
        return _buffered_request_body(body_input)
    end
    if body_input isa IO
        if _should_buffer_request_io(body_input::IO)
            return _buffered_request_body(body_input::IO)
        end
        return _normalized_request_body(_streaming_io_body(body_input::IO), -1; replayable=false)
    end
    if !(body_input isa AbstractBody) && Base.isiterable(typeof(body_input))
        return _normalized_request_body(_iterable_body(body_input), -1; replayable=false)
    end
    if body_input isa AbstractBody
        return _normalized_request_body(body_input::AbstractBody, Int64(-1); replayable=_body_replayable(body_input::AbstractBody))
    end
    throw(ArgumentError("unsupported request body type $(typeof(body_input)); expected nothing, String, Vector{UInt8}, IO, Dict, NamedTuple, HTTP.Form, iterable body chunks, or HTTP.AbstractBody"))
end
