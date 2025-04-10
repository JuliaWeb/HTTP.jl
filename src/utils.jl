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
        aws_uri_init_parse(uri_ref, allocator, url_ref)
    end
    return uri_ref[]
end

isbytes(x) = x isa AbstractVector{UInt8} || x isa AbstractString

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
