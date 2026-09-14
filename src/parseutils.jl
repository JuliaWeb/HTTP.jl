# parsing utils
macro anyeq(var, vals...)
    ret = e = Expr(:||)
    for (i, v) in enumerate(vals)
        x = :($var == $v)
        push!(e.args, x)
        i >= length(vals) - 1 && continue
        ne = Expr(:||)
        push!(e.args, ne)
        e = ne
    end
    return esc(ret)
end

@inline lower(c) = Char(UInt32(c) | 0x20)
@inline isurlchar(c) =  c > '\u80' ? true : normal_url_char[Int(c) + 1]
@inline ismark(c) = @anyeq(c, '-', '_', '.', '!', '~', '*', '\'', '(', ')')
@inline isalpha(c) = 'a' <= lower(c) <= 'z'
@inline isnum(c) = '0' <= c <= '9'
@inline isalphanum(c) = isalpha(c) || isnum(c)
@inline isuserinfochar(c) = isalphanum(c) || ismark(c) || @anyeq(c, '%', ';', ':', '&', '=', '+', '$', ',')
@inline ishex(c) =  isnum(c) || ('a' <= lower(c) <= 'f')
@inline ishostchar(c) = isalphanum(c) || @anyeq(c, '.', '-', '_', '~')
@inline isheaderchar(c) = c == CR || c == LF || c == Char(9) || (c > Char(31) && c != Char(127))

"""
    escapelines(string)

Escape `string` and insert '\n' after escaped newline characters.
"""

function escapelines(s)
    s = Base.escape_string(s)
    s = replace(s, "\\n", "\\n\n    ")
    return string("    ", strip(s))
end
