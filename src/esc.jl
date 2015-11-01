const escaped_regex = r"%([0-9a-fA-F]{2})"

# Escaping
const control_array = vcat(map(UInt8, 0:parse(Int,"1f",16)))
const control = utf8(ascii(control_array)*"\x7f")
const space = utf8(" ")
const delims = utf8("%<>\"")
const unwise   = utf8("{}|\\^`")

const reserved = utf8(",;/?:@&=+\$![]'*#")
# Strings to be escaped
# (Delims goes first so '%' gets escaped first.)
const unescaped = delims * reserved * control * space * unwise
const unescaped_form = delims * reserved * control * unwise


function unescape(str)
    # def _unescape(str, regex) str.gsub(regex){ $1.hex.chr } end
    for m in eachmatch(escaped_regex, str)
        for capture in m.captures
            rep = string(Char(parse(Int, capture, 16)))
            str = replace(str, "%"*capture, rep)
        end
    end
    return str
end
unescape_form(str) = unescape(replace(str, "+", " "))

hex_string(x) = hex(x, 2) |>
                uppercase |>
                x->"%$x"

# Escapes chars (in second string); also escapes all non-ASCII chars.
function escape_with(str, use)
    str = bytestring(str)
    out = IOBuffer()
    chars = Set(use)
    i = start(str)
    e = endof(str)
    while i <= e
        i_next = nextind(str, i)
        if i_next == i + 1
            _char = str[i]
            if _char in chars
                write(out, hex_string(Int(_char)))
            else
                write(out, _char)
            end
        else
            while i < i_next
                write(out, hex_string(str.data[i]))
                i += 1
            end
        end
        i = i_next
    end
    takebuf_string(out)
end

escape(str) = escape_with(str, unescaped)
escape_form(str) = replace(escape_with(str, unescaped_form), " ", "+")
