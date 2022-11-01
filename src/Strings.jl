module Strings

export HTTPVersion, escapehtml, tocameldash, iso8859_1_to_utf8, ascii_lc_isequal

using ..IOExtras

# A `Base.VersionNumber` is a SemVer spec, whereas a HTTP versions is just 2 digits,
# This allows us to use a smaller type and more importantly write a simple parse method
# that avoid allocations.
"""
    HTTPVersion(major, minor)

The HTTP version number consists of two digits separated by a
"." (period or decimal point). The first digit (`major` version)
indicates the HTTP messaging syntax, whereas the second digit (`minor`
version) indicates the highest minor version within that major
version to which the sender is conformant and able to understand for
future communication.

See [RFC7230 2.6](https://tools.ietf.org/html/rfc7230#section-2.6)
"""
struct HTTPVersion
    major::UInt8
    minor::UInt8
end

HTTPVersion(major::Integer) = HTTPVersion(major, 0x00)
HTTPVersion(v::AbstractString) = parse(HTTPVersion, v)
HTTPVersion(v::VersionNumber) = convert(HTTPVersion, v)
# Lossy conversion. We ignore patch/prerelease/build parts even if non-zero/non-empty,
# because we don't want to add overhead for a case that should never be relevant.
Base.convert(::Type{HTTPVersion}, v::VersionNumber) = HTTPVersion(v.major, v.minor)
Base.VersionNumber(v::HTTPVersion) = VersionNumber(v.major, v.minor)

Base.show(io::IO, v::HTTPVersion) = print(io, "HTTPVersion(\"", string(v.major), ".", string(v.minor), "\")")

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

# We only support single-digits for major and minor versions
# - we can parse 0.9 but not 0.10
# - we can parse 9.0 but not 10.0
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
    tocameldash(s::String)

Ensure the first character and characters that follow a '-' are uppercase.
"""
function tocameldash(s::String)
    toUpper = UInt8('A') - UInt8('a')
    v = Vector{UInt8}(bytes(s))
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
Convert ASCII (RFC20) character `c` to lower case.
"""
ascii_lc(c::UInt8) = c in UInt8('A'):UInt8('Z') ? c + 0x20 : c

"""
Case insensitive ASCII character comparison.
"""
ascii_lc_isequal(a::UInt8, b::UInt8) = ascii_lc(a) == ascii_lc(b)

"""
    HTTP.ascii_lc_isequal(a::String, b::String)

Case insensitive ASCII string comparison.
"""
function ascii_lc_isequal(a, b)
    acu = codeunits(a)
    bcu = codeunits(b)
    len = length(acu)
    len != length(bcu) && return false
    for i = 1:len
        @inbounds !ascii_lc_isequal(acu[i], bcu[i]) && return false
    end
    return true
end

end # module Strings
