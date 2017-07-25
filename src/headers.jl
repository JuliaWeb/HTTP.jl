# See https://httpwg.github.io/specs/rfc7230.html#rule.token.separators
const validHeaderBytes = IntSet(Int(c) for c in
   raw"!#$%&'*+-.0123456789ABCDEFGHIJKLMNOPQRSTUWVXYZ^_`abcdefghijklmnopqrstuvwxyz|~"
)

validHeaderChar(c::Char) = isascii(c) && UInt8(c) in validHeaderBytes

function canonicalHeaderKey(s::String)
    # fast path for valid header keys
    upper = true
    for c in s
        if !validHeaderChar(c)
            return s
        end
        if upper && 'a' <= c <= 'z'
            return _chk(s)
        end
        if !upper && 'A' <= c <= 'Z'
            return _chk(s)
        end

        upper = c == '-'
    end

    return s
end

const toUpper = 'A' - 'a'

function _chk(s::String)
    # confirm its fixable before changing anything
    for c in s
        if !validHeaderChar(c)
            return s
        end
    end

    a = copy(Array{UInt8}(s))
    upper = true
    for (i, b) in enumerate(a)
        if upper && UInt8('a') <= b <= UInt8('z')
            b += toUpper
        elseif !upper && UInt8('A') <= b <= UInt8('Z')
            b -= toUpper
        end
        @inbounds a[i] = b
        upper = b == UInt8('-')
    end

    return String(a)
end

"""
Internal type used to enable fast merge, copy, and filter of Headers
"""
immutable AlreadyCanonical
    d::Dict{String,String}
end

"""
    Headers <: Associative{String,String}

A type to represent headers. Keys containing invalid characters are returned as is. Valid keys are canonicalized, uppercasing the first character and characters following a '-' and lowercasing other characters. So, for valid keys, Headers is case-insensitive.
"""
immutable Headers{K<:String,V<:String} <: Associative{String,String}
    d::Dict{K,V}

    function Headers{K,V}() where V where K
        new(Dict{K,V}())
    end
    function Headers{K,V}(kv) where V where K
        d = Dict{K,V}()
        for (k, v) in kv
            ck = canonicalHeaderKey(k)
            if haskey(d, ck)
                error("Key collision -- multiple keys canonize as '$ck'")
            else
                d[ck] = v
            end
        end
        new(d)
    end
    function Headers{K,V}(c::AlreadyCanonical) where V where K
        new(c.d)
    end
end
Headers() = Headers{String,String}()
Headers(x) = Headers{String,String}(x)
Headers(x::Pair...) = Headers{String,String}(x)

Base.convert(::Type{Headers}, x::Associative{String,String}) = Headers(x)

Base.similar(h::Headers{K,V}) where {K,V} = Headers{K,V}()

Base.length(h::Headers) = length(h.d)
Base.start(h::Headers) = start(h.d)
Base.done(h::Headers, args...) = done(h.d, args...)
Base.next(h::Headers, args...) = next(h.d, args...)

Base.getindex(h::Headers, k) = getindex(h.d, canonicalHeaderKey(k))
Base.get(h::Headers, k, d) = Base.get(h.d, canonicalHeaderKey(k), d)
Base.get(d::Base.Callable, h::Headers, k) = Base.get(d, h.d, canonicalHeaderKey(k))
Base.get!(h::Headers, k, d) = get!(h.d, canonicalHeaderKey(k), d)
Base.get!(d::Base.Callable, h::Headers, k) = get!(d, h.d, canonicalHeaderKey(k))
Base.setindex!(h::Headers, v, k) = setindex!(h.d, v, canonicalHeaderKey(k))

Base.pop!(h::Headers, k) = pop!(h.d, canonicalHeaderKey(k))
function Base.delete!(h::Headers, k)
    delete!(h.d, canonicalHeaderKey(k))
    h
end
function Base.filter!(f, h::Headers)
    filter!(f, h.d)
    h
end
function Base.merge!(h::Headers, others::Headers...)
    for other in others
        merge!(h.d, other.d)
    end
    h
end
function Base.merge!(combine::Function, h::Headers, others::Headers...)
    for other in others
        merge!(combine, h.d, other.d)
    end
    h
end
function Base.empty!(h::Headers)
    empty!(h.d)
    h
end

Base.filter(f, h::Headers) = Headers(AlreadyCanonical(filter(f, h.d)))
Base.copy(h::Headers) = Headers(AlreadyCanonical(copy(h.d)))
Base.merge(h::Headers, others::Headers...) = merge!(copy(h), others...)

# Form request body
"""
    Form(dict::Dict)

A type representing a request body using the multipart/form-data encoding.
The key-value pairs in the Dict argument will constitute the name and value of each multipart boundary chunk.
Files and other large data arguments can be provided as values as IO arguments: either an `IOStream` such as returned via `open(file)`,
an `IOBuffer` for in-memory data, or even an `HTTP.FIFOBuffer`. For complete control over a multipart chunk's details, an
`HTTP.Multipart` type is provided to support setting the `Content-Type`, `filename`, and `Content-Transfer-Encoding` if desired. See `?HTTP.Multipart` for more details.
"""
type Form <: IO
    data::Vector{IO}
    index::Int
    boundary::String
end

Form(f::Form) = f
Base.eof(f::Form) = f.index > length(f.data)
Base.length(f::Form) = sum(x->isa(x, IOStream) ? filesize(x) - position(x) : nb_available(x), f.data)

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
            write(io, escape(v))
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
The `content_tyep` and `content_transfer_encoding` arguments allow the manual setting of these multipart headers. `Content-Type` will default to the result
of the `HTTP.sniff(data)` mimetype detection algorithm, whereas `Content-Transfer-Encoding` will be left out if not specified.
"""
type Multipart{T <: IO} <: IO
    filename::String
    data::T
    contenttype::String
    contenttransferencoding::String
end
Multipart{T}(f::String, data::T, ct="", cte="") = Multipart(f, data, ct, cte)
Base.show{T}(io::IO, m::Multipart{T}) = print(io, "HTTP.Multipart(filename=\"$(m.filename)\", data=::$T, contenttype=\"$(m.contenttype)\", contenttransferencoding=\"$(m.contenttransferencoding)\")")

Base.nb_available{T}(m::Multipart{T}) = isa(m.data, IOStream) ? filesize(m.data) - position(m.data) : nb_available(m.data)
Base.eof{T}(m::Multipart{T}) = eof(m.data)
Base.read{T}(m::Multipart{T}, n::Integer) = read(m.data, n)
Base.read{T}(m::Multipart{T}) = read(m.data)
Base.mark{T}(m::Multipart{T}) = mark(m.data)
Base.reset{T}(m::Multipart{T}) = reset(m.data)

function writemultipartheader(io::IOBuffer, i::Multipart)
    write(io, "; filename=\"$(i.filename)\"$CRLF")
    contenttype = i.contenttype == "" ? HTTP.sniff(i.data) : i.contenttype
    write(io, "Content-Type: $(contenttype)$CRLF")
    write(io, i.contenttransferencoding == "" ? "$CRLF" : "Content-Transfer-Encoding: $(i.contenttransferencoding)$CRLF$CRLF")
    return
end
