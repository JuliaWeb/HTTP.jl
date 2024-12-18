module Forms

export Form, Multipart, content_type, parse_multipart_form

import ..sniff

# Form request body
mutable struct Form <: IO
    data::Vector{IO}
    index::Int
    mark::Int
    boundary::String
end

Form(f::Form) = f
Base.eof(f::Form) = f.index > length(f.data)
Base.isopen(f::Form) = false
Base.close(f::Form) = nothing
Base.length(f::Form) = sum(x->isa(x, IOStream) ? filesize(x) - position(x) : bytesavailable(x), f.data)

function Base.mark(f::Form)
    foreach(mark, f.data)
    f.mark = f.index
    return
end

function Base.reset(f::Form)
    foreach(reset, f.data)
    f.index = f.mark
    f.mark = -1
    return
end

function Base.unmark(f::Form)
    foreach(unmark, f.data)
    f.mark = -1
    return
end

function Base.position(f::Form)
    index = f.index
    foreach(mark, f.data)
    return index
end
function Base.seek(f::Form, pos)
    f.index = pos
    foreach(reset, f.data)
    return
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

"""
    HTTP.Form(data; boundary=string(rand(UInt128), base=16))

Construct a request body for multipart/form-data encoding from `data`.

`data` must iterate key-value pairs (e.g. `AbstractDict` or `Vector{Pair}`) where the key/value of the
iterator is the key/value of each mutipart boundary chunk.
Files and other large data arguments can be provided as values as IO arguments: either an `IOStream`
such as returned via `open(file)`, or an `IOBuffer` for in-memory data.

For complete control over a multipart chunk's details, an
[`HTTP.Multipart`](@ref) type is provided to support setting the `filename`, `Content-Type`,
and `Content-Transfer-Encoding`.

# Examples
```julia
data = Dict(
    "text" => "text data",
    # filename (cat.png) and content-type (image/png) inferred from the IOStream
    "file1" => open("cat.png"),
    # manully controlled chunk
    "file2" => HTTP.Multipart("dog.jpeg", open("mydog.jpg"), "image/jpeg"),
)
body = HTTP.Form(data)
headers = []
HTTP.post(url, headers, body)
```
"""
function Form(d; boundary=string(rand(UInt128), base=16))
    # https://www.w3.org/Protocols/rfc1341/7_2_Multipart.html
    bcharsnospace = raw"\w'\(\)\+,-\./:=\?"
    boundary_re = Regex("^[$bcharsnospace ]{0,69}[$bcharsnospace]\$")
    @assert match(boundary_re, boundary) !== nothing
    @assert eltype(d) <: Pair
    data = IO[]
    io = IOBuffer()
    len = length(d)
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
            write(io, v)
        end
    end
    # write final boundary
    write(io, "\r\n--" * boundary * "--" * "\r\n")
    seekstart(io)
    push!(data, io)
    return Form(data, 1, -1, boundary)
end

function writemultipartheader(io::IOBuffer, i::IOStream)
    write(io, "; filename=\"$(basename(i.name[7:end-1]))\"\r\n")
    write(io, "Content-Type: $(sniff(i))\r\n\r\n")
    return
end
function writemultipartheader(io::IOBuffer, i::IO)
    write(io, "\r\n\r\n")
    return
end

"""
    HTTP.Multipart(filename::String, data::IO, content_type=HTTP.sniff(data), content_transfer_encoding="")

A type to represent a single multipart upload chunk for a file. This type would be used as the value in a
key-value pair when constructing a [`HTTP.Form`](@ref) for a request body (see example below).
The `data` argument must be an `IO` type such as `IOStream`, or `IOBuffer`.
The `content_type` and `content_transfer_encoding` arguments allow manual setting of these multipart headers.
`Content-Type` will default to the result of the `HTTP.sniff(data)` mimetype detection algorithm, whereas
`Content-Transfer-Encoding` will be left out if not specified.

# Examples
```julia
body = HTTP.Form(Dict(
    "key" => HTTP.Multipart("File.txt", open("MyFile.txt"), "text/plain"),
))
headers = []
HTTP.post(url, headers, body)
```

# Extended help

Filename SHOULD be included when the Multipart represents the contents of a file
[RFC7578 4.2](https://tools.ietf.org/html/rfc7578#section-4.2)

Content-Disposition set to "form-data" MUST be included with each Multipart.
An additional "name" parameter MUST be included
An optional "filename" parameter SHOULD be included if the contents of a file are sent
This will be formatted such as:
  Content-Disposition: form-data; name="user"; filename="myfile.txt"
[RFC7578 4.2](https://tools.ietf.org/html/rfc7578#section-4.2)

Content-Type for each Multipart is optional, but SHOULD be included if the contents
of a file are sent.
[RFC7578 4.4](https://tools.ietf.org/html/rfc7578#section-4.4)

Content-Transfer-Encoding for each Multipart is deprecated
[RFC7578 4.7](https://tools.ietf.org/html/rfc7578#section-4.7)

Other Content- header fields MUST be ignored
[RFC7578 4.8](https://tools.ietf.org/html/rfc7578#section-4.8)
"""
mutable struct Multipart{T <: IO} <: IO
    filename::Union{String, Nothing}
    data::T
    contenttype::String
    contenttransferencoding::String
    name::String
end

function Multipart(f::Union{AbstractString, Nothing}, data::T, ct::AbstractString="", cte::AbstractString="", name::AbstractString="") where {T<:IO}
    f = f !== nothing ? String(f) : nothing
    return Multipart{T}(f, data, String(ct), String(cte), String(name))
end

function Base.show(io::IO, m::Multipart{T}) where {T}
    items = ["data=::$T", "contenttype=\"$(m.contenttype)\"", "contenttransferencoding=\"$(m.contenttransferencoding)\")"]
    m.filename === nothing || pushfirst!(items, "filename=\"$(m.filename)\"")
    print(io, "HTTP.Multipart($(join(items, ", ")))")
end

Base.bytesavailable(m::Multipart{T}) where {T} = isa(m.data, IOStream) ? filesize(m.data) - position(m.data) : bytesavailable(m.data)
Base.eof(m::Multipart{T}) where {T} = eof(m.data)
Base.read(m::Multipart{T}, n::Integer) where {T} = read(m.data, n)
Base.read(m::Multipart{T}) where {T} = read(m.data)
Base.mark(m::Multipart{T}) where {T} = mark(m.data)
Base.reset(m::Multipart{T}) where {T} = reset(m.data)
Base.seekstart(m::Multipart{T}) where {T} = seekstart(m.data)

function writemultipartheader(io::IOBuffer, i::Multipart)
    if i.filename === nothing
        write(io, "\r\n")
    else
        write(io, "; filename=\"$(i.filename)\"\r\n")
    end
    contenttype = i.contenttype == "" ? sniff(i.data) : i.contenttype
    write(io, "Content-Type: $(contenttype)\r\n")
    write(io, i.contenttransferencoding == "" ? "\r\n" : "Content-Transfer-Encoding: $(i.contenttransferencoding)\r\n\r\n")
    return
end

content_type(f::Form) = "multipart/form-data; boundary=$(f.boundary)"

const CR_BYTE = 0x0d # \r
const LF_BYTE = 0x0a # \n
const DASH_BYTE = 0x2d # -
const HTAB_BYTE = 0x09 # \t
const SPACE_BYTE = 0x20
const SEMICOLON_BYTE = UInt8(';')
const CRLFCRLF = (CR_BYTE, LF_BYTE, CR_BYTE, LF_BYTE)

"compare byte buffer `a` from index `i` to index `j` with `b` and check if they are byte-equal"
function byte_buffers_eq(a, i, j, b)
    l = 1
    @inbounds for k = i:j
        a[k] == b[l] || return false
        l += 1
    end
    return true
end

"""
    find_multipart_boundary(bytes, boundaryDelimiter; start::Int=1)

Find the first and last index of the next boundary delimiting a part, and if
the discovered boundary is the terminating boundary.
"""
function find_multipart_boundary(bytes::AbstractVector{UInt8}, boundaryDelimiter::AbstractVector{UInt8}, start::Int=1)
    # The boundary delimiter line is prepended with two '-' characters
    # The boundary delimiter line starts on a new line, so must be preceded by a \r\n.
    # The boundary delimiter line ends with \r\n, and can have "optional linear whitespace" between
    # the end of the boundary delimiter, and the \r\n.
    # The last boundary delimiter line has an additional '--' at the end of the boundary delimiter
    # [RFC2046 5.1.1](https://tools.ietf.org/html/rfc2046#section-5.1.1)
    i = start
    end_index = i + length(boundaryDelimiter) + 1
    while end_index <= length(bytes)
        if bytes[i] == DASH_BYTE && bytes[i + 1] == DASH_BYTE && byte_buffers_eq(bytes, i + 2, end_index, boundaryDelimiter)
            # boundary delimiter line start on a new line ...
            if i > 1
                (i == 2 || bytes[i-2] != CR_BYTE || bytes[i-1] != LF_BYTE) && error("boundary delimiter found, but it was not the start of a line")
                # the CRLF preceding the boundary delimiter is "conceptually attached
                # to the boundary", so account for this with the index
                i -= 2
            end
            # need to check if there are enough characters for the CRLF or for two dashes
            end_index < length(bytes)-1 || error("boundary delimiter found, but did not end with new line")
            is_terminating_delimiter = bytes[end_index+1] == DASH_BYTE && bytes[end_index+2] == DASH_BYTE
            is_terminating_delimiter && (end_index += 2)
            # ... there can be arbitrary SP and HTAB space between the boundary delimiter ...
            while end_index < length(bytes) && (bytes[end_index+1] in (HTAB_BYTE, SPACE_BYTE))
                end_index += 1
            end
            # ... and ends with a new line
            newlineEnd = end_index < length(bytes)-1 &&
                            bytes[end_index+1] == CR_BYTE &&
                            bytes[end_index+2] == LF_BYTE
            if !newlineEnd
                error("boundary delimiter found, but did not end with new line")
            end
            end_index += 2
            return (is_terminating_delimiter, i, end_index)
        end
        i += 1
        end_index += 1
    end
    error("boundary delimiter not found")
end

"""
    find_multipart_boundaries(bytes, boundary; start=1)

Find the start and end indexes of all the parts of the multipart object.  Ultimately this method is
looking for the data between the boundary delimiters in the byte array.  A vector containing all
the start/end pairs is returned.
"""
function find_multipart_boundaries(bytes::AbstractVector{UInt8}, boundary::AbstractVector{UInt8}, start=1)
    idxs = Tuple{Int, Int}[]
    while true
        (is_terminating_delimiter, i, end_index) = find_multipart_boundary(bytes, boundary, start)
        push!(idxs, (i, end_index))
        is_terminating_delimiter && break
        start = end_index + 1
    end
    return idxs
end

"""
    find_header_boundary(bytes)

Find the end of the multipart header in the byte array.  Returns a Tuple with the
start index(1) and the end index. Headers are separated from the body by CRLFCRLF.

[RFC2046 5.1](https://tools.ietf.org/html/rfc2046#section-5.1)
[RFC822 3.1](https://tools.ietf.org/html/rfc822#section-3.1)
"""
function find_header_boundary(bytes::AbstractVector{UInt8})
    length(CRLFCRLF) > length(bytes) && return nothing
    l = length(bytes) - length(CRLFCRLF) + 1
    i = 1
    end_index = length(CRLFCRLF)
    while (i <= l)
        byte_buffers_eq(bytes, i, end_index, CRLFCRLF) && return (1, end_index)
        i += 1
        end_index += 1
    end
    error("no delimiter found separating header from multipart body")
end

"""
    parse_multipart_chunk(chunk)

Parse a single multi-part chunk into a Multipart object.  This will decode
the header and extract the contents from the byte array.
"""
function parse_multipart_chunk(chunk)
    _, end_index = find_header_boundary(chunk)
    ind = end_index
    header = unsafe_string(pointer(chunk), ind)
    content = view(chunk, end_index+1:lastindex(chunk))

    # find content disposition
    re = match(r"^[Cc]ontent-[Dd]isposition:[ \t]*form-data;[ \t]*(.*)\r\n"mx, header)
    if re === nothing
        @warn "Content disposition is not specified dropping the chunk." String(chunk)
        return nothing # Specifying content disposition is mandatory
    end
    content_disposition = SubString(re.match, sizeof("Content-Disposition: form-data;")+1)

    name = nothing
    filename = nothing
    while !isempty(content_disposition)
        re_pair = match(r"""^
    [ \t]*([!#$%&'*+\-.^_`|~[:alnum:]]+)[ \t]*=[ \t]*"(.*?)";?
    """x, content_disposition)
        if re_pair !== nothing
            key = re_pair.captures[1]
            value = re_pair.captures[2]
            if key == "name"
                name = value
            elseif key == "filename"
                filename = value
            else
                # do stuff with other content disposition key-value pairs
            end
            content_disposition = SubString(content_disposition, sizeof(re_pair.match)+1)
            continue
        end
        re_flag = match(r"""^
    [ \t]*([!#$%&'*+\-.^_`|~[:alnum:]]+);?
    """x, content_disposition)
        if re_flag !== nothing
            # do stuff with content disposition flags
            content_disposition = SubString(content_disposition, sizeof(re_flag.match)+1)
            continue
        end
        break
    end

    if name === nothing
        @warn "Content disposition is missing the name field. Dropping the chunk." String(chunk)
        return nothing
    end

    re_ct = match(r"(?i)Content-Type: (\S*[^;\s])", header)
    contenttype = re_ct === nothing ? "text/plain" : re_ct.captures[1]
    return Multipart(filename, IOBuffer(content), contenttype, "", name)
end

"""
    parse_multipart_body(body, boundary)::Vector{Multipart}

Parse the multipart body received from the client breaking it into the various
chunks which are returned as an array of Multipart objects.
"""
function parse_multipart_body(body::AbstractVector{UInt8}, boundary::AbstractString)::Vector{Multipart}
    multiparts = Multipart[]
    idxs = find_multipart_boundaries(body, codeunits(boundary))
    length(idxs) > 1 || (return multiparts)

    for i in 1:length(idxs)-1
        chunk = view(body, idxs[i][2]+1:idxs[i+1][1]-1)
        push!(multiparts, parse_multipart_chunk(chunk))
    end
    return multiparts
end


"""
    parse_multipart_form(content_type, body)::Vector{Multipart}

Parse the full mutipart form submission from the client returning and
array of Multipart objects containing all the data.

The order of the multipart form data in the request should be preserved.
[RFC7578 5.2](https://tools.ietf.org/html/rfc7578#section-5.2).

The boundary delimiter MUST NOT appear inside any of the encapsulated parts. Note
that the boundary delimiter does not need to have '-' characters, but a line using
the boundary delimiter will start with '--' and end in \r\n.
[RFC2046 5.1](https://tools.ietf.org/html/rfc2046#section-5.1.1)
"""
function parse_multipart_form(content_type::Union{String, Nothing}, body::Union{AbstractVector{UInt8}, Nothing})::Union{Vector{Multipart}, Nothing}
    # parse boundary from Content-Type
    (content_type === nothing || body === nothing) && return nothing
    m = match(r"multipart/form-data; boundary=(.*)$", content_type)
    m === nothing && return nothing
    boundary_delimiter = m[1]
    # [RFC2046 5.1.1](https://tools.ietf.org/html/rfc2046#section-5.1.1)
    length(boundary_delimiter) > 70 && error("boundary delimiter must not be greater than 70 characters")
    return parse_multipart_body(body, boundary_delimiter)
end

end # module