export bytes, isbytes, nbytes, nobytes,
    escapehtml, tocameldash, iso8859_1_to_utf8, ascii_lc_isequal

const HTTP2_DEFAULT_WINDOW_SIZE = 65535
const HTTP2_MAX_WINDOW_SIZE = 0x7fffffff

"""
    HTTPVersion(major, minor)

The HTTP version number consists of two digits separated by a ".". The first
digit (`major`) indicates the HTTP messaging syntax, whereas the second digit
(`minor`) indicates the highest minor version within that major version to which
the sender is conformant and able to understand for future communication.
"""
struct HTTPVersion
    major::UInt8
    minor::UInt8
end

HTTPVersion(major::Integer) = HTTPVersion(major, 0x00)
HTTPVersion(v::AbstractString) = parse(HTTPVersion, v)
HTTPVersion(v::VersionNumber) = convert(HTTPVersion, v)
Base.convert(::Type{HTTPVersion}, v::VersionNumber) = HTTPVersion(v.major, v.minor)
Base.VersionNumber(v::HTTPVersion) = VersionNumber(v.major, v.minor)

Base.show(io::IO, v::HTTPVersion) = print(io, "HTTPVersion(\"", string(v.major), ".", string(v.minor), "\")")
Base.write(io::IO, v::HTTPVersion) = write(io, "HTTP/", string(v.major), ".", string(v.minor))

Base.:(==)(va::VersionNumber, vb::HTTPVersion) = va == VersionNumber(vb)
Base.:(==)(va::HTTPVersion, vb::VersionNumber) = VersionNumber(va) == vb
Base.isless(va::VersionNumber, vb::HTTPVersion) = isless(va, VersionNumber(vb))
Base.isless(va::HTTPVersion, vb::VersionNumber) = isless(VersionNumber(va), vb)
function Base.isless(va::HTTPVersion, vb::HTTPVersion)
    va.major < vb.major && return true
    va.major > vb.major && return false
    va.minor < vb.minor && return true
    return false
end

function Base.parse(::Type{HTTPVersion}, v::AbstractString)
    ver = tryparse(HTTPVersion, v)
    ver === nothing && throw(ArgumentError("invalid HTTP version string: $(repr(v))"))
    return ver
end

# We only support single-digits for major and minor versions.
function Base.tryparse(::Type{HTTPVersion}, v::AbstractString)
    isempty(v) && return nothing
    len = ncodeunits(v)

    i = firstindex(v)
    d1 = v[i]
    if isdigit(d1)
        major = parse(UInt8, d1)
    else
        return nothing
    end

    i = nextind(v, i)
    i > len && return HTTPVersion(major)
    dot = v[i]
    dot == '.' || return nothing

    i = nextind(v, i)
    i > len && return HTTPVersion(major)
    d2 = v[i]
    if isdigit(d2)
        minor = parse(UInt8, d2)
    else
        return nothing
    end
    return HTTPVersion(major, minor)
end

"""
    escapehtml(i::String)

Returns a string with special HTML characters escaped: &, <, >, ", '
"""
function escapehtml(i::AbstractString)
    # Refer to http://stackoverflow.com/a/7382028/3822752 for spec. links
    o = replace(i, "&" =>"&amp;")
    o = replace(o, "\""=>"&quot;")
    o = replace(o, "'" =>"&#39;")
    o = replace(o, "<" =>"&lt;")
    o = replace(o, ">" =>"&gt;")
    return o
end

"""
    iso8859_1_to_utf8(bytes::AbstractVector{UInt8})

Convert from ISO8859_1 to UTF8.
"""
function iso8859_1_to_utf8(bytes::AbstractVector{UInt8})
    io = IOBuffer()
    for b in bytes
        if b < 0x80
            write(io, b)
        else
            write(io, 0xc0 | (b >> 6))
            write(io, 0x80 | (b & 0x3f))
        end
    end
    return String(take!(io))
end

"""
    tocameldash(s::String)

Ensure the first character and characters that follow a '-' are uppercase.
"""
function tocameldash(s::String)
    toUpper = UInt8('A') - UInt8('a')
    v = Vector{UInt8}(codeunits(s))
    upper = true
    for i = 1:length(v)
        @inbounds b = v[i]
        if upper
            islower(b) && (v[i] = b + toUpper)
        else
            isupper(b) && (v[i] = lower(b))
        end
        upper = b == UInt8('-')
    end
    return String(v)
end

tocameldash(s::AbstractString) = tocameldash(String(s))

@inline islower(b::UInt8) = UInt8('a') <= b <= UInt8('z')
@inline isupper(b::UInt8) = UInt8('A') <= b <= UInt8('Z')
@inline lower(c::UInt8) = c | 0x20

"""
    ascii_lc_isequal(a, b)

Case insensitive ASCII string comparison.
"""
function ascii_lc_isequal(a, b)
    acu = codeunits(a)
    bcu = codeunits(b)
    len = length(acu)
    len != length(bcu) && return false
    for i = 1:len
        @inbounds (acu[i] in UInt8('A'):UInt8('Z') ? acu[i] + 0x20 : acu[i]) ==
            (bcu[i] in UInt8('A'):UInt8('Z') ? bcu[i] + 0x20 : bcu[i]) || return false
    end
    return true
end

function parseuri(url, query, allocator)
    uri_ref = Ref{aws_uri}()
    if url isa AbstractString
        url_str = String(url) * (query === nothing ? "" : ("?" * URIs.escapeuri(query)))
    elseif url isa URI
        url_str = string(url)
    else
        throw(ArgumentError("url must be an AbstractString or URI"))
    end
    GC.@preserve url_str begin
        url_ref = Ref(aws_byte_cursor(sizeof(url_str), pointer(url_str)))
        aws_uri_init_parse(uri_ref, allocator, url_ref) != 0 && aws_throw_error()
    end
    return uri_ref[]
end

"""
    bytes(x)

If `x` is "castable" to an `AbstractVector{UInt8}`, then an
`AbstractVector{UInt8}` is returned; otherwise `x` is returned.
"""
function bytes end
bytes(s::AbstractVector{UInt8}) = s
bytes(s::AbstractString) = codeunits(s)
bytes(x) = x

isbytes(x) = x isa AbstractVector{UInt8} || x isa AbstractString

"""
    nbytes(x) -> Int

Length in bytes of `x` if `x` is `isbytes(x)`.
"""
function nbytes end
nbytes(x) = nothing
nbytes(x::AbstractVector{UInt8}) = length(x)
nbytes(x::AbstractString) = sizeof(x)
nbytes(x::Vector{T}) where T <: AbstractString = sum(sizeof, x)
nbytes(x::Vector{T}) where T <: AbstractVector{UInt8} = sum(length, x)
nbytes(x::IOBuffer) = bytesavailable(x)
nbytes(x::Vector{IOBuffer}) = sum(bytesavailable, x)

const nobytes = view(UInt8[], 1:0)

str(bc::aws_byte_cursor) = bc.ptr == C_NULL || bc.len == 0 ? "" : unsafe_string(bc.ptr, bc.len)

function print_uri(io, uri::aws_uri)
    print(io, "scheme: ", str(uri.scheme), "\n")
    print(io, "userinfo: ", str(uri.userinfo), "\n")
    print(io, "host_name: ", str(uri.host_name), "\n")
    print(io, "port: ", Int(uri.port), "\n")
    print(io, "path: ", str(uri.path), "\n")
    print(io, "query: ", str(uri.query_string), "\n")
    return
end

scheme(uri::aws_uri) = str(uri.scheme)
userinfo(uri::aws_uri) = str(uri.userinfo)
host(uri::aws_uri) = str(uri.host_name)
port(uri::aws_uri) = uri.port
path(uri::aws_uri) = str(uri.path)
query(uri::aws_uri) = str(uri.query_string)

function resource(uri::aws_uri)
    ref = Ref(uri)
    GC.@preserve ref begin
        bc = aws_uri_path_and_query(ref)
        path = str(unsafe_load(bc))
        return isempty(path) ? "/" : path
    end
end

const URI_SCHEME_HTTPS = "https"
const URI_SCHEME_WSS = "wss"
ishttps(sch) = aws_byte_cursor_eq_c_str_ignore_case(sch, URI_SCHEME_HTTPS)
iswss(sch) = aws_byte_cursor_eq_c_str_ignore_case(sch, URI_SCHEME_WSS)
function getport(uri::aws_uri)
    sch = Ref(uri.scheme)
    GC.@preserve sch begin
        return UInt32(uri.port != 0 ? uri.port : (ishttps(sch) || iswss(sch)) ? 443 : 80)
    end
end

function makeuri(u::aws_uri)
    return URIs.URI(
        scheme=str(u.scheme),
        userinfo=isempty(str(u.userinfo)) ? URIs.absent : str(u.userinfo),
        host=str(u.host_name),
        port=u.port == 0 ? URIs.absent : u.port,
        path=isempty(str(u.path)) ? URIs.absent : str(u.path),
        query=isempty(str(u.query_string)) ? URIs.absent : str(u.query_string),
    )
end

struct AWSError <: Exception
    msg::String
end

aws_error() = AWSError(unsafe_string(aws_error_debug_str(aws_last_error())))
aws_error(error_code) = AWSError(unsafe_string(aws_error_str(error_code)))
aws_throw_error() = throw(aws_error())

struct BufferOnResponseBody{T <: AbstractVector{UInt8}}
    buffer::T
    pos::Ptr{Int}
end

function (f::BufferOnResponseBody)(resp, buf)
    len = length(buf)
    pos = unsafe_load(f.pos)
    copyto!(f.buffer, pos, buf, 1, len)
    unsafe_store!(f.pos, pos + len)
    return len
end

struct IOOnResponseBody{T <: IO}
    io::T
end

function (f::IOOnResponseBody)(resp, buf)
    write(f.io, buf)
    return length(buf)
end
