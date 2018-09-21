"""
Convert ASCII (RFC20) character `c` to lower case.
"""
ascii_lc(c::UInt8) = c in UInt8('A'):UInt8('Z') ? c + 0x20 : c

"""
Case insensitive ASCII character comparison.
"""
ascii_lc_isequal(a::UInt8, b::UInt8) = ascii_lc(a) == ascii_lc(b)

"""
Case insensitive ASCII string comparison.
"""
ascii_lc_isequal(a, b) = length(a) == length(b) &&
                         all(map(ascii_lc_isequal, codeunits(a), codeunits(b)))
