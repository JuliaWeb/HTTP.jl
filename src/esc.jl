const escaped_regex = r"%([0-9a-fA-F]{2})"

# Escaping
const control_array = vcat(map(UInt8, 0:parse(Int,"1f",16)))
const control = String(control_array)*"\x7f"
const space = String(" ")
const delims = String("%<>\"")
const unwise   = String("(){}|\\^`")

const reserved = String(",;/?:@&=+\$![]'*#")
# Strings to be escaped
# (Delims goes first so '%' gets escaped first.)
const unescaped = delims * reserved * control * space * unwise
const unescaped_form = delims * reserved * control * unwise


function unescape(str)
    r = UInt8[]
    l = length(str)
    i = 1
    while i <= l
        c = str[i]
        i += 1
        if c == '%'
            c = parse(UInt8, str[i:i+1], 16)
            i += 2
        end
        push!(r, c)
    end
   return String(r)
end
unescape_form(str) = unescape(replace(str, "+", " "))

hex_string(x) = string('%', uppercase(hex(x,2)))

# Escapes chars (in second string); also escapes all non-ASCII chars.
function escape_with(str, use)
    str = String(str)
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
