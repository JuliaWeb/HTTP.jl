export Form
export Multipart
export content_type
export parse_multipart_form
export parse_multipart
export parse_multipart_mixed

# Batch is public but not exported (Julia 1.11+)
if VERSION >= v"1.11.0-DEV.469"
    eval(Meta.parse("public Batch"))
end

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
        type == :mixed || write(io, "Content-Disposition: form-data; name=\"$k\"")
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
        write(io, "; filename=\"$(basename(stream.name[7:end-1]))\"\r\n")
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

"""
    Form(parts::Vector{<:Multipart}; boundary=_default_form_boundary())

Create a multipart/mixed Form from a vector of Multipart objects.
"""
function Form(v::Vector{<:Multipart}; boundary=_default_form_boundary())
    return Form(Pair[i => m for (i, m) in enumerate(v)]; boundary=boundary, type=:mixed)
end

"""
    Batch(parts::Vector{<:Multipart}; boundary=_default_form_boundary()) -> Form
    Batch(parts; boundary=_default_form_boundary()) -> Form

Create a multipart/mixed batch request body. This is a convenience constructor
for creating a Form with `type=:mixed`, commonly used for batch API requests
(e.g., SharePoint batch operations, GraphQL batch queries).

# Arguments
- `parts`: Either a `Vector{<:Multipart}` or key-value pairs
- `boundary`: Optional custom boundary string (auto-generated by default)

# Returns
A `Form` object with `type=:mixed` that can be used as a request body.

# Examples
```julia
# Create batch from Multipart objects
parts = [
    Multipart(nothing, IOBuffer("request1"), "application/http"),
    Multipart(nothing, IOBuffer("request2"), "application/http"),
]
batch = Batch(parts)

# Use with HTTP request
response = HTTP.post(url, ["Content-Type" => content_type(batch)], batch)

# Create batch with explicit key-value pairs
batch = Batch(Dict("req1" => data1, "req2" => data2))
```

See also: [`Form`](@ref), [`Multipart`](@ref), [`content_type`](@ref)
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
        write(io, "; filename=\"$(part.filename)\"\r\n")
    end
    detected = part.contenttype == "" ? sniff(part.data) : part.contenttype
    write(io, "Content-Type: $(detected)\r\n")
    write(io, part.contenttransferencoding == "" ? "\r\n" : "Content-Transfer-Encoding: $(part.contenttransferencoding)\r\n\r\n")
    return nothing
end

"""
    content_type(form) -> String

Return the multipart content type header for `form`, including its
generated boundary. The type will be `multipart/form-data` for `:formdata` type
and `multipart/mixed` for `:mixed` type.
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
    ind = end_index
    header = unsafe_string(pointer(chunk), ind)
    content = view(chunk, end_index+1:lastindex(chunk))

    # find content disposition
    disposition_match = match(r"^[Cc]ontent-[Dd]isposition:[ \t]*form-data;[ \t]*(.*)\r\n"mx, header)
    content_disposition_available = disposition_match !== nothing

    if !content_disposition_available && require_contentdisposition
        return nothing  # Content disposition is mandatory for form-data
    end

    name = nothing
    filename = nothing
    if content_disposition_available
        content_disposition = SubString(disposition_match.match, sizeof("Content-Disposition: form-data;") + 1)
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

    content_type_match = match(r"(?i)Content-Type: (\S*[^;\s])", header)
    detected = content_type_match === nothing ? "text/plain" : content_type_match.captures[1]
    return Multipart(filename, IOBuffer(content), detected, "", name === nothing ? "" : name)
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
    parse_multipart_form(request) -> Union{Vector{Multipart}, Nothing}

Parse a `multipart/form-data` payload using the boundary from
`content_type_header`.

The `Request` overload reads the `Content-Type` header and request body bytes
out of the incoming request — use it from inside an [`HTTP.serve!`](@ref)
handler to inspect file uploads and form fields without re-implementing the
header/body extraction.

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

function parse_multipart_form(request::Request)::Union{Vector{Multipart},Nothing}
    ct = header(request, "Content-Type")
    isempty(ct) && return nothing
    bytes = _request_body_bytes(request.body)
    bytes === nothing && return nothing
    return parse_multipart_form(ct, bytes)
end

@inline _request_body_bytes(::EmptyBody) = nothing
@inline _request_body_bytes(body::BytesBody) =
    body.next_index > length(body.data) ? UInt8[] :
    @view body.data[body.next_index:end]
@inline _request_body_bytes(::AbstractBody) = nothing

"""
    parse_multipart(content_type_header, body, required_type=nothing) -> Union{Vector{Multipart}, Nothing}
    parse_multipart(request, required_type=nothing) -> Union{Vector{Multipart}, Nothing}

Parse a multipart payload (either `multipart/form-data` or `multipart/mixed`) using the
boundary from `content_type_header`.

If `required_type` is specified (e.g., `:formdata` or `:mixed`), only that type will be parsed.
If `required_type` is `nothing`, any multipart type will be parsed.

Returns `nothing` when either input is missing, the content type is not a multipart type,
or the type doesn't match `required_type` if specified.
"""
function parse_multipart(
    content_type_header::Union{String,Nothing},
    body::Union{AbstractVector{UInt8},Nothing},
    required_type::Union{Symbol,Nothing}=nothing,
)::Union{Vector{Multipart},Nothing}
    (content_type_header === nothing || body === nothing) && return nothing

    # parse multipart type and boundary from Content-Type
    matched = match(r"multipart/([^;]*); boundary=(.*)$", content_type_header)
    matched === nothing && return nothing

    type = Symbol(replace(matched[1], '-' => ""))
    boundary_delimiter = matched[2]
    required_type !== nothing && required_type != type && return nothing

    # RFC2046 5.1.1: boundary must not be greater than 70 characters
    length(boundary_delimiter) > 70 && error("boundary delimiter must not be greater than 70 characters")

    return parse_multipart_body(body, boundary_delimiter; require_contentdisposition=(type == :formdata))
end

function parse_multipart(request::Request, required_type::Union{Symbol,Nothing}=nothing)::Union{Vector{Multipart},Nothing}
    ct = header(request, "Content-Type")
    isempty(ct) && return nothing
    bytes = _request_body_bytes(request.body)
    bytes === nothing && return nothing
    return parse_multipart(ct, bytes, required_type)
end

"""
    parse_multipart_mixed(content_type_header, body) -> Union{Vector{Multipart}, Nothing}
    parse_multipart_mixed(request) -> Union{Vector{Multipart}, Nothing}

Parse a `multipart/mixed` payload using the boundary from `content_type_header`.

Returns `nothing` when either input is missing or the content type is not `multipart/mixed`.
"""
parse_multipart_mixed(content_type_header::Union{String,Nothing}, body::Union{AbstractVector{UInt8},Nothing}) =
    parse_multipart(content_type_header, body, :mixed)

parse_multipart_mixed(request::Request) = parse_multipart(request, :mixed)
