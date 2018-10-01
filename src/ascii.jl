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
function ascii_lc_isequal(a, b)
    a = Iterators.Stateful(codeunits(a))
    b = Iterators.Stateful(codeunits(b))
    for (i, j) in zip(a, b)
        if !ascii_lc_isequal(i, j)
            return false
        end
    end
    return isempty(a) && isempty(b)
end
