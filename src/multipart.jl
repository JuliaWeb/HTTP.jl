module Forms

export Form, Multipart, content_type

using ..IOExtras, ..Sniff, ..Conditions
import ..HTTP # for doc references

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
IOExtras.nbytes(x::Form) = length(x)

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
    @require match(boundary_re, boundary) !== nothing
    @require eltype(d) <: Pair
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

content_type(f::Form) = "Content-Type" =>
                        "multipart/form-data; boundary=$(f.boundary)"

end # module