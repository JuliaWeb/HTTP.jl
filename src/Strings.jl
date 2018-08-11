module Strings

export escapehtml, tocameldash, iso8859_1_to_utf8

using ..IOExtras 
import ..replace

"""
escapeHTML(i::String)

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
    iso8859_1_to_utf8(bytes)

Convert from ISO8859_1 to UTF8.
"""
function iso8859_1_to_utf8(bytes::Vector{UInt8})
    io = IOBuffer()
    for b in bytes
        if b < 0x80
            write(io, b)
        else
            write(io, 0xc0 | b >> 6)
            write(io, 0x80 | b & 0x3f)
        end
    end
    return String(take!(io))
end

end # module Strings
