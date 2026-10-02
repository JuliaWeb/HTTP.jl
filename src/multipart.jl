# Form request body
"""
Form(dict::Dict)

A type representing a request body using the multipart/form-data encoding.
The key-value pairs in the Dict argument will constitute the name and value of each multipart boundary chunk.
Files and other large data arguments can be provided as values as IO arguments: either an `IOStream` such as returned via `open(file)`,
an `IOBuffer` for in-memory data, or even an `HTTP.FIFOBuffer`. For complete control over a multipart chunk's details, an
`HTTP.Multipart` type is provided to support setting the `Content-Type`, `filename`, and `Content-Transfer-Encoding` if desired. See `?HTTP.Multipart` for more details.
"""
mutable struct Form <: IO
    data::Vector{IO}
    index::Int
    boundary::String
end

Form(f::Form) = f
Base.eof(f::Form) = f.index > length(f.data)
Base.isopen(f::Form) = false
Base.close(f::Form) = nothing
Base.length(f::Form) = sum(x->isa(x, IOStream) ? filesize(x) - position(x) : nb_available(x), f.data)
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

function Form(d::Dict)
    boundary = hex(rand(UInt128))
    data = IO[]
    io = IOBuffer()
    len = length(d)
    for (i, (k, v)) in enumerate(d)
        write(io, (i == 1 ? "" : "$CRLF") * "--" * boundary * "$CRLF")
        write(io, "Content-Disposition: form-data; name=\"$k\"")
        if isa(v, IO)
            writemultipartheader(io, v)
            seekstart(io)
            push!(data, io)
            push!(data, v)
            io = IOBuffer()
        else
            write(io, "$CRLF$CRLF")
            write(io, escapeuri(v))
        end
        i == len && write(io, "$CRLF--" * boundary * "--" * "$CRLF")
    end
    seekstart(io)
    push!(data, io)
    return Form(data, 1, boundary)
end

function writemultipartheader(io::IOBuffer, i::IOStream)
    write(io, "; filename=\"$(i.name[7:end-1])\"$CRLF")
    write(io, "Content-Type: $(HTTP.sniff(i))$CRLF$CRLF")
    return
    end
    function writemultipartheader(io::IOBuffer, i::IO)
    write(io, "$CRLF$CRLF")
    return
end

"""
Multipart(filename::String, data::IO, content_type=HTTP.sniff(data), content_transfer_encoding="")

A type to represent a single multipart upload chunk for a file. This type would be used as the value in a
key-value pair of a Dict passed to an http request, like `HTTP.post(url; body=Dict("key"=>HTTP.Multipart("MyFile.txt", open("MyFile.txt"))))`.
The `data` argument must be an `IO` type such as `IOStream`, `IOBuffer`, or `HTTP.FIFOBuffer`.
The `content_type` and `content_transfer_encoding` arguments allow the manual setting of these multipart headers. `Content-Type` will default to the result
of the `HTTP.sniff(data)` mimetype detection algorithm, whereas `Content-Transfer-Encoding` will be left out if not specified.
"""
mutable struct Multipart{T <: IO} <: IO
    filename::String
    data::T
    contenttype::String
    contenttransferencoding::String
end
Multipart(f::String, data::T, ct="", cte="") where {T} = Multipart(f, data, ct, cte)
Base.show(io::IO, m::Multipart{T}) where {T} = print(io, "HTTP.Multipart(filename=\"$(m.filename)\", data=::$T, contenttype=\"$(m.contenttype)\", contenttransferencoding=\"$(m.contenttransferencoding)\")")

Base.nb_available(m::Multipart{T}) where {T} = isa(m.data, IOStream) ? filesize(m.data) - position(m.data) : nb_available(m.data)
Base.eof(m::Multipart{T}) where {T} = eof(m.data)
Base.read(m::Multipart{T}, n::Integer) where {T} = read(m.data, n)
Base.read(m::Multipart{T}) where {T} = read(m.data)
Base.mark(m::Multipart{T}) where {T} = mark(m.data)
Base.reset(m::Multipart{T}) where {T} = reset(m.data)

function writemultipartheader(io::IOBuffer, i::Multipart)
    write(io, "; filename=\"$(i.filename)\"$CRLF")
    contenttype = i.contenttype == "" ? HTTP.sniff(i.data) : i.contenttype
    write(io, "Content-Type: $(contenttype)$CRLF")
    write(io, i.contenttransferencoding == "" ? "$CRLF" : "Content-Transfer-Encoding: $(i.contenttransferencoding)$CRLF$CRLF")
    return
end
