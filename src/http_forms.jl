export Form
export Multipart
export content_type
export parse_multipart_form
export parse_multipart
export parse_multipart_mixed

# Batch is public but not exported (Julia 1.11+)
@static if Base.VERSION >= v"1.11.0-DEV.469"
    Core.eval(@__MODULE__, Expr(:public, :Batch))
end

using UUIDs

"""
    Form(parts; boundary, type=:formdata) <: IO

A multipart request body. `parts` is a collection of `name => value` pairs. An
`IO` value is streamed (an open file is sent with its file name, and a
[`Multipart`](@ref) with its own name and content type); any other value is
sent as `string(value)`. `type = :mixed` builds a `multipart/mixed` body
instead of `multipart/form-data`. A request with a `Form` body gets the
matching `Content-Type` header from [`content_type`](@ref).
"""
mutable struct Form <: IO
    data::Vector{IO}
    index::Int
    mark::Int
    boundary::String
    type::Symbol
end

Form(f::Form) = f

Base.eof(f::Form) = f.index > length(f.data)
Base.isopen(::Form) = false
Base.close(::Form) = nothing
Base.length(f::Form) = sum(io -> isa(io, IOStream) ? filesize(io) - position(io) : bytesavailable(io), f.data)

function Base.mark(f::Form)
    foreach(mark, f.data)
    f.mark = f.index
    return nothing
end

function Base.reset(f::Form)
    foreach(reset, f.data)
    f.index = f.mark
    f.mark = -1
    return nothing
end

function Base.unmark(f::Form)
    foreach(unmark, f.data)
    f.mark = -1
    return nothing
end

function Base.position(f::Form)
    foreach(mark, f.data)
    return f.index
end

function Base.seek(f::Form, pos)
    f.index = pos
    foreach(reset, f.data)
    return nothing
end

Base.readavailable(f::Form) = read(f)

function Base.read(f::Form)
    result = UInt8[]
    for io in f.data
        append!(result, read(io))
    end
    f.index = length(f.data) + 1
    return result
end

function Base.read(f::Form, n::Integer)
    nb = 0
    result = UInt8[]
    while nb < n
        d = read(f.data[f.index], n - nb)
        nb += length(d)
        append!(result, d)
        eof(f.data[f.index]) && (f.index += 1)
        f.index > length(f.data) && break
    end
    return result
end

# Field names and file names go inside a quoted `Content-Disposition`
# parameter. Escape `"`, CR, and LF as browsers do (WHATWG HTML
# multipart/form-data encoding), so a name can't end the parameter or the
# header line.
function _escape_multipart_quoted(value::AbstractString)::String
    raw = String(value)
    any(c -> c == '"' || c == '\r' || c == '\n', raw) || return raw
    return replace(raw, '"' => "%22", '\r' => "%0D", '\n' => "%0A")
end

# Part header values such as a content type are written as is; reject CR/LF,
# which would end the header line.
function _check_multipart_header_value(name::AbstractString, value::AbstractString)::String
    raw = String(value)
    any(c -> c == '\r' || c == '\n', raw) && throw(ArgumentError("multipart part $name must not contain CR or LF: $(repr(raw))"))
    return raw
end

function _default_form_boundary()::String
    return replace(string(UUIDs.uuid4()), '-' => "")
end

function Form(d; boundary=_default_form_boundary(), type::Symbol=:formdata)
    type in (:formdata, :mixed) || throw(ArgumentError("type must be :formdata or :mixed"))
    bcharsnospace = raw"\w'\(\)\+,-\./:=\?"
    boundary_re = Regex("^[$bcharsnospace ]{0,69}[$bcharsnospace]\$")
    match(boundary_re, boundary) !== nothing || throw(ArgumentError("invalid boundary"))
    eltype(d) <: Pair || throw(ArgumentError("data must be a collection of pairs"))
    data = IO[]
    io = IOBuffer()
    for (i, (k, v)) in enumerate(d)
        write(io, (i == 1 ? "" : "\r\n") * "--" * boundary * "\r\n")
        type == :mixed || write(io, "Content-Disposition: form-data; name=\"", _escape_multipart_quoted(string(k)), "\"")
        if isa(v, IO)
            writemultipartheader(io, v, type)
            seekstart(io)
            push!(data, io)
            push!(data, v)
            io = IOBuffer()
        else
            write(io, "\r\n\r\n")
            write(io, string(v))
        end
    end
    write(io, "\r\n--" * boundary * "--" * "\r\n")
    seekstart(io)
    push!(data, io)
    return Form(data, 1, -1, boundary, type)
end

function writemultipartheader(io::IOBuffer, stream::IOStream, type::Symbol=:formdata)
    if type == :mixed
        write(io, "Content-Type: $(sniff(stream))\r\n\r\n")
    else
        write(io, "; filename=\"", _escape_multipart_quoted(basename(stream.name[7:end-1])), "\"\r\n")
        write(io, "Content-Type: $(sniff(stream))\r\n\r\n")
    end
    return nothing
end

function writemultipartheader(io::IOBuffer, stream::IO, type::Symbol=:formdata)
    # :formdata: close the "Content-Disposition: …" line opened by the caller, then blank line
    # :mixed: caller wrote nothing, so only the blank line ending the empty headers section
    write(io, type == :mixed ? "\r\n" : "\r\n\r\n")
    return nothing
end

"""
    Multipart(filename, data, contenttype="", contenttransferencoding="", name="") <: IO

One part of a multipart body, with its content in the `IO` `data`. `filename`
may be `nothing`, and an empty `contenttype` is detected from the data when the
part is sent. The `parse_multipart` functions return `Multipart`s, and
[`Form`](@ref) accepts them as values.
"""
mutable struct Multipart{T<:IO} <: IO
    filename::Union{String,Nothing}
    data::T
    contenttype::String
    contenttransferencoding::String
    name::String
end

function Multipart(
    filename::Union{AbstractString,Nothing},
    data::T,
    contenttype::AbstractString="",
    contenttransferencoding::AbstractString="",
    name::AbstractString="",
) where {T<:IO}
    file = filename === nothing ? nothing : String(filename)
    return Multipart{T}(file, data, String(contenttype), String(contenttransferencoding), String(name))
end

"""
    Form(parts::Vector{<:Multipart}; boundary)

Build a `multipart/mixed` body from `parts`.
"""
function Form(v::Vector{<:Multipart}; boundary=_default_form_boundary())
    return Form(Pair[i => m for (i, m) in enumerate(v)]; boundary=boundary, type=:mixed)
end

"""
    Batch(parts; boundary) -> Form

Build a `multipart/mixed` body, the format of batch APIs such as OData
`\$batch`. `parts` is a vector of [`Multipart`](@ref)s or a collection of
`name => value` pairs, as for [`Form`](@ref) with `type = :mixed`.

```julia
parts = [
    HTTP.Multipart(nothing, IOBuffer("GET /users/1 HTTP/1.1\\r\\n\\r\\n"), "application/http"),
    HTTP.Multipart(nothing, IOBuffer("GET /users/2 HTTP/1.1\\r\\n\\r\\n"), "application/http"),
]
response = HTTP.post(url, [], HTTP.Batch(parts))
```
"""
Batch(v::Vector{<:Multipart}; boundary=_default_form_boundary()) =
    Form(v; boundary=boundary)

Batch(d; boundary=_default_form_boundary()) =
    Form(d; boundary=boundary, type=:mixed)

function Base.show(io::IO, m::Multipart{T}) where {T}
    items = ["data=::$T", "contenttype=\"$(m.contenttype)\"", "contenttransferencoding=\"$(m.contenttransferencoding)\")"]
    m.filename === nothing || pushfirst!(items, "filename=\"$(m.filename)\"")
    print(io, "HTTP.Multipart($(join(items, ", ")))")
    return nothing
end

Base.bytesavailable(m::Multipart{T}) where {T} = isa(m.data, IOStream) ? filesize(m.data) - position(m.data) : bytesavailable(m.data)
Base.eof(m::Multipart{T}) where {T} = eof(m.data)
Base.read(m::Multipart{T}, n::Integer) where {T} = read(m.data, n)
Base.read(m::Multipart{T}) where {T} = read(m.data)
Base.mark(m::Multipart{T}) where {T} = mark(m.data)
Base.reset(m::Multipart{T}) where {T} = reset(m.data)
Base.seekstart(m::Multipart{T}) where {T} = seekstart(m.data)

function writemultipartheader(io::IOBuffer, part::Multipart, type::Symbol=:formdata)
    if type == :mixed
        # don't write a new line for mixed type
    elseif part.filename === nothing
        write(io, "\r\n")
    else
        write(io, "; filename=\"", _escape_multipart_quoted(part.filename), "\"\r\n")
    end
    detected = part.contenttype == "" ? sniff(part.data) : _check_multipart_header_value("content type", part.contenttype)
    write(io, "Content-Type: ", detected, "\r\n")
    if part.contenttransferencoding == ""
        write(io, "\r\n")
    else
        write(io, "Content-Transfer-Encoding: ", _check_multipart_header_value("content transfer encoding", part.contenttransferencoding), "\r\n\r\n")
    end
    return nothing
end

"""
    content_type(form) -> String

Return the `Content-Type` header value for `form`: `multipart/form-data` or
`multipart/mixed`, with the boundary.
"""
function content_type(form::Form)::String
    type_str = form.type == :formdata ? "form-data" : string(form.type)
    return "multipart/$(type_str); boundary=$(form.boundary)"
end

const _CR_BYTE = 0x0d
const _LF_BYTE = 0x0a
const _DASH_BYTE = 0x2d
const _HTAB_BYTE = 0x09
const _SPACE_BYTE = 0x20
const _CRLFCRLF = (_CR_BYTE, _LF_BYTE, _CR_BYTE, _LF_BYTE)

function _byte_buffers_eq(a::AbstractVector{UInt8}, i::Int, j::Int, b)::Bool
    l = 1
    @inbounds for k in i:j
        a[k] == b[l] || return false
        l += 1
    end
    return true
end

function find_multipart_boundary(bytes::AbstractVector{UInt8}, boundary_delimiter::AbstractVector{UInt8}; start::Int=1)
    i = start
    end_index = i + length(boundary_delimiter) + 1
    while end_index <= length(bytes)
        if bytes[i] == _DASH_BYTE && bytes[i+1] == _DASH_BYTE && _byte_buffers_eq(bytes, i + 2, end_index, boundary_delimiter)
            if i > 1
                (i == 2 || bytes[i-2] != _CR_BYTE || bytes[i-1] != _LF_BYTE) && error("boundary delimiter found, but it was not the start of a line")
                i -= 2
            end
            end_index < length(bytes) - 1 || error("boundary delimiter found, but did not end with new line")
            terminating = bytes[end_index+1] == _DASH_BYTE && bytes[end_index+2] == _DASH_BYTE
            terminating && (end_index += 2)
            while end_index < length(bytes) && (bytes[end_index+1] in (_HTAB_BYTE, _SPACE_BYTE))
                end_index += 1
            end
            newline_end = end_index < length(bytes) - 1 &&
                          bytes[end_index+1] == _CR_BYTE &&
                          bytes[end_index+2] == _LF_BYTE
            newline_end || error("boundary delimiter found, but did not end with new line")
            end_index += 2
            return terminating, i, end_index
        end
        i += 1
        end_index += 1
    end
    error("boundary delimiter not found")
end

function find_multipart_boundaries(bytes::AbstractVector{UInt8}, boundary::AbstractVector{UInt8}; start::Int=1)
    idxs = Tuple{Int,Int}[]
    while true
        terminating, i, end_index = find_multipart_boundary(bytes, boundary; start=start)
        push!(idxs, (i, end_index))
        terminating && break
        start = end_index + 1
    end
    return idxs
end

function find_header_boundary(bytes::AbstractVector{UInt8})
    length(_CRLFCRLF) > length(bytes) && return nothing
    l = length(bytes) - length(_CRLFCRLF) + 1
    i = 1
    end_index = length(_CRLFCRLF)
    while i <= l
        _byte_buffers_eq(bytes, i, end_index, _CRLFCRLF) && return 1, end_index
        i += 1
        end_index += 1
    end
    error("no delimiter found separating header from multipart body")
end

function parse_multipart_chunk(chunk; require_contentdisposition::Bool=true)
    _, end_index = find_header_boundary(chunk)
    # Copy by index: `chunk` may be any AbstractVector, not contiguous memory.
    header = String(chunk[1:end_index])
    content = view(chunk, end_index+1:lastindex(chunk))

    # find content disposition
    disposition_match = match(r"^content-disposition:[ \t]*form-data;[ \t]*(.*)\r\n"imx, header)
    content_disposition_available = disposition_match !== nothing

    if !content_disposition_available && require_contentdisposition
        return nothing  # Content disposition is mandatory for form-data
    end

    name = nothing
    filename = nothing
    if content_disposition_available
        content_disposition = something(disposition_match.captures[1])
        while !isempty(content_disposition)
            pair_match = match(r"""^
        [ \t]*([!#$%&'*+\-.^_`|~[:alnum:]]+)[ \t]*=[ \t]*"(.*?)";?
        """x, content_disposition)
            if pair_match !== nothing
                key = pair_match.captures[1]
                value = pair_match.captures[2]
                if key == "name"
                    name = value
                elseif key == "filename"
                    filename = value
                end
                content_disposition = SubString(content_disposition, sizeof(pair_match.match) + 1)
                continue
            end
            flag_match = match(r"""^
        [ \t]*([!#$%&'*+\-.^_`|~[:alnum:]]+);?
        """x, content_disposition)
            flag_match === nothing && break
            content_disposition = SubString(content_disposition, sizeof(flag_match.match) + 1)
        end
        name === nothing && return nothing
    end

    content_type_match = match(r"^content-type:[ \t]*(\S*[^;\s])"im, header)
    detected = content_type_match === nothing ? "text/plain" : content_type_match.captures[1]
    return Multipart(filename, IOBuffer(content), detected, "", name === nothing ? "" : name)
end

# Split a `multipart/*` Content-Type value into its lowercase subtype, such as
# "form-data", and its `boundary` parameter. Parameter names and the media
# type are case-insensitive and the boundary may be a quoted string
# (RFC 2045 §5.1, RFC 2046 §5.1.1). Returns `nothing` for any other media type
# or a value without a boundary.
function _multipart_subtype_and_boundary(content_type::AbstractString)::Union{Nothing,Tuple{String,String}}
    fields = split(content_type, ';')
    media_type = lowercase(strip(fields[1]))
    startswith(media_type, "multipart/") || return nothing
    subtype = String(SubString(media_type, ncodeunits("multipart/") + 1))
    for field in Iterators.drop(fields, 1)
        eq = findfirst(==('='), field)
        eq === nothing && continue
        lowercase(strip(SubString(field, firstindex(field), prevind(field, eq)))) == "boundary" || continue
        value = strip(SubString(field, nextind(field, eq)))
        if length(value) >= 2 && startswith(value, '"') && endswith(value, '"')
            value = replace(SubString(value, nextind(value, firstindex(value)), prevind(value, lastindex(value))), r"\\(.)" => s"\1")
        end
        boundary = String(value)
        # RFC 2046 §5.1.1: 1 to 70 characters.
        1 <= length(boundary) <= 70 || error("multipart boundary must be 1 to 70 characters: $(repr(boundary))")
        return subtype, boundary
    end
    return nothing
end

function parse_multipart_body(body::AbstractVector{UInt8}, boundary::AbstractString; require_contentdisposition::Bool=true)::Vector{Multipart}
    multiparts = Multipart[]
    idxs = find_multipart_boundaries(body, collect(codeunits(boundary)))
    length(idxs) > 1 || return multiparts
    for i in 1:(length(idxs)-1)
        chunk = view(body, idxs[i][2]+1:idxs[i+1][1]-1)
        multipart = parse_multipart_chunk(chunk; require_contentdisposition=require_contentdisposition)
        multipart === nothing || push!(multiparts, multipart)
    end
    return multiparts
end

"""
    parse_multipart_form(content_type_header, body) -> Union{Vector{Multipart}, Nothing}
    parse_multipart_form(message) -> Union{Vector{Multipart}, Nothing}

Parse a `multipart/form-data` body, using the boundary in
`content_type_header`. The `message` form reads the `Content-Type` header and
body of a `Request` or `Response`, such as the request in a `serve!` handler.

Returns `nothing` when the content type is not `multipart/form-data` or there
is no body. Each [`Multipart`](@ref) has the part's `name`, `filename` (or
`nothing`), `contenttype`, and its content as the `IO` `data`.

# Examples
```jldoctest
julia> body = Vector{UInt8}(
           "--boundary\\r\\n" *
           "Content-Disposition: form-data; name=\\"greeting\\"\\r\\n\\r\\n" *
           "hello\\r\\n" *
           "--boundary\\r\\n" *
           "Content-Disposition: form-data; name=\\"file\\"; filename=\\"a.txt\\"\\r\\n" *
           "Content-Type: text/plain\\r\\n\\r\\n" *
           "file contents\\r\\n" *
           "--boundary--\\r\\n");

julia> parts = HTTP.parse_multipart_form("multipart/form-data; boundary=boundary", body);

julia> length(parts)
2

julia> parts[1].name, String(read(parts[1].data))
("greeting", "hello")

julia> parts[2].name, parts[2].filename, parts[2].contenttype
("file", "a.txt", "text/plain")

julia> String(read(parts[2].data))
"file contents"
```

Inside a server handler, pass the request directly:

```julia
HTTP.serve!("127.0.0.1", 8080) do request
    parts = HTTP.parse_multipart_form(request)
    parts === nothing && return HTTP.Response(415, "expected multipart/form-data")
    return HTTP.Response(200, "received \$(length(parts)) part(s)")
end
```
"""
function parse_multipart_form(
    content_type_header::Union{String,Nothing},
    body::Union{AbstractVector{UInt8},Nothing},
)::Union{Vector{Multipart},Nothing}
    (content_type_header === nothing || body === nothing) && return nothing
    parsed = _multipart_subtype_and_boundary(content_type_header)
    (parsed === nothing || parsed[1] != "form-data") && return nothing
    return parse_multipart_body(body, parsed[2])
end

function parse_multipart_form(message::Union{Request,Response})::Union{Vector{Multipart},Nothing}
    ct = header(message, "Content-Type")
    isempty(ct) && return nothing
    bytes = _message_body_bytes(message.body)
    bytes === nothing && return nothing
    return parse_multipart_form(ct, bytes)
end

@inline _message_body_bytes(::EmptyBody) = nothing
@inline _message_body_bytes(body::BytesBody) =
    body.next_index > length(body.data) ? UInt8[] :
    @view body.data[body.next_index:end]
@inline _message_body_bytes(body::AbstractVector{UInt8}) = body
# Server-built responses keep `String` bodies as-is (#1333); parse them in place.
@inline _message_body_bytes(body::AbstractString) = codeunits(body)
@inline _message_body_bytes(::AbstractBody) = nothing

"""
    parse_multipart(content_type_header, body, required_type=nothing) -> Union{Vector{Multipart}, Nothing}
    parse_multipart(message, required_type=nothing) -> Union{Vector{Multipart}, Nothing}

Parse a multipart body of any subtype, such as `multipart/form-data` or
`multipart/mixed`, using the boundary in `content_type_header`. The `message`
form reads the header and body of a `Request` or `Response`.

`required_type` (`:formdata` or `:mixed`) accepts only that subtype. Returns
`nothing` when the content type does not match or there is no body.
"""
function parse_multipart(
    content_type_header::Union{String,Nothing},
    body::Union{AbstractVector{UInt8},Nothing},
    required_type::Union{Symbol,Nothing}=nothing,
)::Union{Vector{Multipart},Nothing}
    (content_type_header === nothing || body === nothing) && return nothing
    parsed = _multipart_subtype_and_boundary(content_type_header)
    parsed === nothing && return nothing
    subtype, boundary_delimiter = parsed
    type = Symbol(replace(subtype, '-' => ""))
    required_type !== nothing && required_type != type && return nothing
    return parse_multipart_body(body, boundary_delimiter; require_contentdisposition=(type == :formdata))
end

function parse_multipart(message::Union{Request,Response}, required_type::Union{Symbol,Nothing}=nothing)::Union{Vector{Multipart},Nothing}
    ct = header(message, "Content-Type")
    isempty(ct) && return nothing
    bytes = _message_body_bytes(message.body)
    bytes === nothing && return nothing
    return parse_multipart(ct, bytes, required_type)
end

"""
    parse_multipart_mixed(content_type_header, body) -> Union{Vector{Multipart}, Nothing}
    parse_multipart_mixed(message) -> Union{Vector{Multipart}, Nothing}

Parse a `multipart/mixed` body; see [`parse_multipart`](@ref).
"""
parse_multipart_mixed(content_type_header::Union{String,Nothing}, body::Union{AbstractVector{UInt8},Nothing}) =
    parse_multipart(content_type_header, body, :mixed)

parse_multipart_mixed(message::Union{Request,Response}) = parse_multipart(message, :mixed)
