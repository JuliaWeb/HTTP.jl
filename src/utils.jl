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
    else
        if typeof(expr) != String
            return esc(:($expr))
        end
    end
end