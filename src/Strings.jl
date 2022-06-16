module Strings

export escapehtml, tocameldash, iso8859_1_to_utf8, ascii_lc_isequal

using ..IOExtras

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
