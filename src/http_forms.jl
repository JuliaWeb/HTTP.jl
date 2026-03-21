export Form
export Multipart
export content_type
export parse_multipart_form

using UUIDs

"""
    Form(parts; boundary=_default_form_boundary()) <: IO

Streaming multipart/form-data request body assembled from `name => value`
pairs.

Values may be ordinary data or `IO` objects. Use [`content_type`](@ref) to
populate the corresponding `Content-Type` request header.
"""
mutable struct Form <: IO
    data::Vector{IO}
    index::Int
    mark::Int
    boundary::String
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

function _default_form_boundary()::String
    return replace(string(UUIDs.uuid4()), '-' => "")
end

function Form(d; boundary=_default_form_boundary())
    bcharsnospace = raw"\w'\(\)\+,-\./:=\?"
    boundary_re = Regex("^[$bcharsnospace ]{0,69}[$bcharsnospace]\$")
    @assert match(boundary_re, boundary) !== nothing
    @assert eltype(d) <: Pair
    data = IO[]
    io = IOBuffer()
    for (i, (k, v)) in enumerate(d)
        write(io, (i == 1 ? "" : "\r\n") * "--" * boundary * "\r\n")
        write(io, "Content-Disposition: form-data; name=\"$k\"")
        if isa(v, IO)
            writemultipartheader(io, v)
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
    return Form(data, 1, -1, boundary)
end

function writemultipartheader(io::IOBuffer, stream::IOStream)
    write(io, "; filename=\"$(basename(stream.name[7:end-1]))\"\r\n")
    write(io, "Content-Type: $(sniff(stream))\r\n\r\n")
    return nothing
end

function writemultipartheader(io::IOBuffer, stream::IO)
    write(io, "\r\n\r\n")
    return nothing
end

"""
    Multipart(filename, data, contenttype="", contenttransferencoding="", name="") <: IO

One parsed or programmatically constructed multipart body part.
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

function writemultipartheader(io::IOBuffer, part::Multipart)
    if part.filename === nothing
        write(io, "\r\n")
    else
        write(io, "; filename=\"$(part.filename)\"\r\n")
    end
    detected = part.contenttype == "" ? sniff(part.data) : part.contenttype
    write(io, "Content-Type: $(detected)\r\n")
    write(io, part.contenttransferencoding == "" ? "\r\n" : "Content-Transfer-Encoding: $(part.contenttransferencoding)\r\n\r\n")
    return nothing
end

"""
    content_type(form) -> String

Return the `multipart/form-data` content type header for `form`, including its
generated boundary.
"""
function content_type(form::Form)::String
    return "multipart/form-data; boundary=$(form.boundary)"
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

function parse_multipart_chunk(chunk)
    _, end_index = find_header_boundary(chunk)
    ind = end_index
    header = unsafe_string(pointer(chunk), ind)
    content = view(chunk, end_index+1:lastindex(chunk))
    disposition_match = match(r"^[Cc]ontent-[Dd]isposition:[ \t]*form-data;[ \t]*(.*)\r\n"mx, header)
    disposition_match === nothing && return nothing
    content_disposition = SubString(disposition_match.match, sizeof("Content-Disposition: form-data;") + 1)
    name = nothing
    filename = nothing
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
    content_type_match = match(r"(?i)Content-Type: (\S*[^;\s])", header)
    detected = content_type_match === nothing ? "text/plain" : content_type_match.captures[1]
    return Multipart(filename, IOBuffer(content), detected, "", name)
end

function parse_multipart_body(body::AbstractVector{UInt8}, boundary::AbstractString)::Vector{Multipart}
    multiparts = Multipart[]
    idxs = find_multipart_boundaries(body, collect(codeunits(boundary)))
    length(idxs) > 1 || return multiparts
    for i in 1:(length(idxs)-1)
        chunk = view(body, idxs[i][2]+1:idxs[i+1][1]-1)
        multipart = parse_multipart_chunk(chunk)
        multipart === nothing || push!(multiparts, multipart)
    end
    return multiparts
end

"""
    parse_multipart_form(content_type_header, body) -> Union{Vector{Multipart}, Nothing}

Parse a `multipart/form-data` payload using the boundary from
`content_type_header`.

Returns `nothing` when either input is missing or the content type is not a
multipart form body.
"""
function parse_multipart_form(
    content_type_header::Union{String,Nothing},
    body::Union{AbstractVector{UInt8},Nothing},
)::Union{Vector{Multipart},Nothing}
    (content_type_header === nothing || body === nothing) && return nothing
    matched = match(r"multipart/form-data; boundary=(.*)$", content_type_header)
    matched === nothing && return nothing
    boundary_delimiter = matched[1]
    length(boundary_delimiter) > 70 && error("boundary delimiter must not be greater than 70 characters")
    return parse_multipart_body(body, boundary_delimiter)
end
