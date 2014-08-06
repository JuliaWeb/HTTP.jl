const escaped_regex = r"%([0-9a-fA-F]{2})"

# Escaping
const control_array = convert(Array{Uint8,1}, [vec(0:(parseint("1f", 16)))])
const control = utf8(ascii(control_array)*"\x7f")
const space = utf8(" ")
const delims = utf8("%<>\"")
const unwise   = utf8("{}|\\^`")
const nonascii_array = convert(Array{Uint8,1}, [vec(parseint("80", 16):(parseint("ff", 16)))])

const reserved = utf8(",;/?:@&=+\$![]'*#")
# Strings to be escaped
# (Delims goes first so '%' gets escaped first.)
const unescaped = delims * reserved * control * space * unwise
const unescaped_form = delims * reserved * control * unwise


function unescape(str)
    # def _unescape(str, regex) str.gsub(regex){ $1.hex.chr } end
    for m in eachmatch(escaped_regex, str)
        for capture in m.captures
            rep = string(char(parseint(capture, 16)))
            str = replace(str, "%"*capture, rep)
        end
    end
    return str
end
unescape_form(str) = unescape(replace(str, "+", " "))


# Escapes chars (in second string); also escapes all non-ASCII chars.
function escape_with(str, use)
    chars = split(use, "")
      
    for c in chars
        _char = c[1] # Character string as Char
        h = uppercase(hex(int(_char)))
        if length(h) < 2
            h = "0"*h
        end
        str = replace(str, c, "%" * h)
    end
      
    for i in nonascii_array
        str = replace(str, char(i), "%" * uppercase(hex(i)))
    end
      
    return str
end
    
escape(str) = escape_with(str, unescaped)
escape_form(str) = replace(escape_with(str, unescaped_form), " ", "+")

