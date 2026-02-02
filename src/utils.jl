export bytes, isbytes, nbytes, nobytes,
    escapehtml, tocameldash, iso8859_1_to_utf8, ascii_lc_isequal

const HTTP2_DEFAULT_WINDOW_SIZE = 65535
const HTTP2_MAX_WINDOW_SIZE = 0x7fffffff
const AWS_HTTP2_SETTINGS_MAX_CONCURRENT_STREAMS = AwsHTTP.Http2SettingsId.MAX_CONCURRENT_STREAMS
const AWS_HTTP2_SETTINGS_INITIAL_WINDOW_SIZE = AwsHTTP.Http2SettingsId.INITIAL_WINDOW_SIZE
const AWS_HTTP2_SETTINGS_COUNT = Int(AwsHTTP.HTTP2_SETTINGS_END_RANGE - AwsHTTP.HTTP2_SETTINGS_BEGIN_RANGE)
const _H2_CHANNEL_SUPPORTED = AwsHTTP.H2Connection <: AwsIO.AbstractChannelHandler

function _normalize_alpn_list(alpn_list::Union{String, Nothing})
    alpn_list === nothing && return nothing
    isempty(alpn_list) && return alpn_list
    _H2_CHANNEL_SUPPORTED && return alpn_list
    parts = split(alpn_list, ';'; keepempty = false)
    filtered = [p for p in parts if lowercase(p) != "h2"]
    isempty(filtered) && return "http/1.1"
    return join(filtered, ';')
end

@inline function _alpn_includes_h2(alpn_list::Union{String, Nothing})::Bool
    alpn_list === nothing && return false
    for part in split(alpn_list, ';'; keepempty = false)
        lowercase(part) == "h2" && return true
    end
    return false
end

function _should_use_nw_tls(alpn_list::Union{String, Nothing})::Bool
    @static if Sys.isapple()
        return _use_nw_sockets() && _alpn_includes_h2(alpn_list)
    else
        return false
    end
end

function _use_nw_sockets()::Bool
    @static if Sys.isapple()
        AwsIO._tls_set_use_secitem_from_env()
        return AwsIO._NW_SHIM_LIB != "" && AwsIO.is_using_secitem()
    else
        return false
    end
end

function _tls_alpn_list(tls_opts)
    tls_opts === nothing && return nothing
    if hasproperty(tls_opts, :alpn_list) && tls_opts.alpn_list !== nothing
        return tls_opts.alpn_list
    end
    if hasproperty(tls_opts, :ctx) && tls_opts.ctx !== nothing
        return tls_opts.ctx.options.alpn_list
    end
    return nothing
end

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

function parseuri(url, query)
    if url isa AbstractString
        url_str = String(url) * (query === nothing ? "" : ("?" * URIs.escapeuri(query)))
    elseif url isa URI
        url_str = string(url)
    else
        throw(ArgumentError("url must be an AbstractString or URI"))
    end
    return URIs.URI(url_str)
end

# compatibility: 3-arg version for callers that still pass allocator
parseuri(url, query, _allocator) = parseuri(url, query)

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

# URI accessor helpers that work on URIs.URI
scheme(uri::URI) = uri.scheme
userinfo(uri::URI) = uri.userinfo
host(uri::URI) = uri.host
function port(uri::URI)
    p = uri.port
    if p === nothing || isempty(p)
        return UInt32(0)
    end
    return UInt32(parse(Int, p))
end
path(uri::URI) = uri.path
query(uri::URI) = uri.query

function resource(uri::URI)
    p = uri.path
    q = uri.query
    r = isempty(p) ? "/" : p
    return isempty(q) ? r : string(r, "?", q)
end

const URI_SCHEME_HTTPS = "https"
const URI_SCHEME_WSS = "wss"
ishttps(sch::AbstractString) = lowercase(sch) == URI_SCHEME_HTTPS
iswss(sch::AbstractString) = lowercase(sch) == URI_SCHEME_WSS
function getport(uri::URI)
    p = port(uri)
    return p != 0 ? p : (ishttps(scheme(uri)) || iswss(scheme(uri))) ? UInt32(443) : UInt32(80)
end

makeuri(u::URI) = u

struct AWSError <: Exception
    msg::String
end

function _resolve_error_str(error_code::Integer)
    ec = Int(error_code)
    # AwsHTTP has its own String-based error table for HTTP-range codes
    if ec >= AwsHTTP.ERROR_HTTP_UNKNOWN && ec <= AwsHTTP.ERROR_HTTP_END_RANGE
        return AwsHTTP.http_error_str(ec)
    end
    # AwsIO.error_str returns Ptr{UInt8}; convert to String
    return unsafe_string(AwsIO.error_str(ec))
end

aws_error() = AWSError(_resolve_error_str(AwsIO.last_error()))
aws_error(error_code) = AWSError(_resolve_error_str(error_code))
aws_throw_error() = throw(aws_error())

# Simple Future type for async callback coordination.
# Replaces LibAwsCommon.Future. Supports notify/wait pattern:
#   notify(f, value::T) -> success
#   notify(f, err::Exception) -> error
#   wait(f) -> returns T or throws Exception
mutable struct Future{T}
    const notify_cond::Threads.Condition
    @atomic set::Int8 # 0=pending, 1=success, 2=error
    result::Union{Exception, T}
    Future{T}() where {T} = new{T}(Threads.Condition(), 0)
end

Future() = Future{Nothing}()

function Base.wait(f::Future{T}) where {T}
    set = @atomic f.set
    set == 1 && return f.result::T
    set == 2 && throw(f.result::Exception)
    lock(f.notify_cond)
    try
        set = f.set
        set == 1 && return f.result::T
        set == 2 && throw(f.result::Exception)
        wait(f.notify_cond)
    finally
        unlock(f.notify_cond)
    end
    f.set == 1 && return f.result::T
    throw(f.result::Exception)
end

function Base.notify(f::Future{T}, result::T) where {T}
    lock(f.notify_cond)
    try
        f.set != 0 && return
        f.result = result
        @atomic f.set = 1
        notify(f.notify_cond)
    finally
        unlock(f.notify_cond)
    end
    return
end

function Base.notify(f::Future, err::Exception)
    lock(f.notify_cond)
    try
        f.set != 0 && return
        f.result = err
        @atomic f.set = 2
        notify(f.notify_cond)
    finally
        unlock(f.notify_cond)
    end
    return
end

struct BufferOnResponseBody{T <: AbstractVector{UInt8}}
    buffer::T
    pos::Ref{Int}
end

function (f::BufferOnResponseBody)(resp, buf)
    len = length(buf)
    pos = f.pos[]
    copyto!(f.buffer, pos, buf, 1, len)
    f.pos[] = pos + len
    return len
end

struct IOOnResponseBody{T <: IO}
    io::T
end

function (f::IOOnResponseBody)(resp, buf)
    write(f.io, buf)
    return length(buf)
end
