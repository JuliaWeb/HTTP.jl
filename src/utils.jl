"""
escapeHTML(i::String)

Returns a string with special HTML characters escaped: &, <, >, ", '
"""
function escapeHTML(i::String)
    # Refer to http://stackoverflow.com/a/7382028/3822752 for spec. links
    o = replace(i, "&", "&amp;")
    o = replace(o, "\"", "&quot;")
    o = replace(o, "'", "&#39;")
    o = replace(o, "<", "&lt;")
    o = replace(o, ">", "&gt;")
    return o
end

"""
@timeout secs expr then pollint

Start executing `expr`; if it doesn't finish executing in `secs` seconds,
then execute `then`. `pollint` controls the amount of time to wait in between
checking if `expr` has finished executing (short for polling interval).
"""
macro timeout(t, expr, then, pollint=0.01)
    return quote
        tm = Float64($(esc(t)))
        start = time()
        tsk = @async $(esc(expr))
        while !istaskdone(tsk) && (time() - start < tm)
            sleep($pollint)
        end
        istaskdone(tsk) || $(esc(then))
        tsk.result
    end
end

"""
    @debug DEBUG expr
    @debug DEBUG "message"

A macro to aid when needing to turn on extremely verbose output for debugging.
Set `const DEBUG = true` in HTTP.jl and re-compile the package to see
debug-level output from the package. When `DEBUG = false`, all `@debug` statements
compile to `nothing`.
"""
macro debug(should, expr)
    if eval(should)
        if typeof(expr) == String
            return esc(:(println("[DEBUG - ", @__FILE__, ":", @__LINE__, "]: ", $expr)))
        else
            return esc(:(println("[DEBUG - ", @__FILE__, ":", @__LINE__, "]: ", $(sprint(Base.show_unquoted, expr)), " = ", $expr)))
        end
    end
end

# parsing utils
lower(c) = Char(UInt32(c) | 0x20)
isurlchar(c) =  c > '\u80' ? true : normal_url_char[Int(c) + 1] # 'A' <= c <= '~' || '$' <= c <= '>' || c == '\f' || c == '\t'
const MARKS = Set{Char}(['-', '_', '.', '!', '~', '*', '\'', '(', ')'])
ismark(c) = c in MARKS
isalpha(c) = 'a' <= lower(c) <= 'z'
isnum(c) = '0' <= c <= '9'
isalphanum(c) = isalpha(c) || isnum(c)
const USERINFOCHARS = Set{Char}(['%', ';', ':', '&', '=', '+', '$', ','])
isuserinfochar(c) = isalphanum(c) || ismark(c) || c in USERINFOCHARS
ishex(c) =  isnum(c) || ('a' <= lower(c) <= 'f')
const HOSTCHARS = Set{Char}(['.', '-', '_', '~'])
ishostchar(c) = isalphanum(c) || c in HOSTCHARS
isheaderchar(c) = c == CR || c == LF || c == Char(9) || (c > Char(31) && c != Char(127))

macro shifted(meth, i, char)
    return esc(:(Int32($meth) << Int32(16) | Int32($i) << Int32(8) | Int32($char)))
end

macro errorif(cond, err)
    return esc(quote
        $cond && @err($err)
    end)
end

macro err(e)
    return esc(quote
        errno = $e
        @goto error
    end)
end

macro strictcheck(cond)
    return esc(:(strict && @errorif($cond, HPE_STRICT)))
end
