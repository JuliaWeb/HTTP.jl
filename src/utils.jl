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

macro retry(expr)
    :(@retry 2 $(esc(expr)))
end

macro retry(N, expr)
    :(@retryif Any $N $(esc(expr)))
end

macro retryif(cond, expr)
    :(@retryif $(esc(cond)) 2 $(esc(expr)))
end

macro retryif(cond, N, expr)
    quote
        local __r__
        for i = 1:$N
            try
                __r__ = $(esc(expr))
                break
            catch e
                typeof(e) <: $(esc(cond)) || rethrow(e)
                i == $N && rethrow(e)
                sleep(0.1)
            end
        end
        __r__
    end
end

"""
@timeout secs expr then pollint

Start executing `expr`; if it doesn't finish executing in `secs` seconds,
then execute `then`. `pollint` controls the amount of time to wait in between
checking if `expr` has finished executing (short for polling interval).
"""
macro timeout(t, expr, then, pollint=0.01)
    return quote
        if $(esc(t)) == Inf
            $(esc(expr))
        else
            tm = Float64($(esc(t)))
            start = time()
            tsk = @async $(esc(expr))
            yield()
            while !istaskdone(tsk) && (time() - start < tm)
                sleep($pollint)
            end
            istaskdone(tsk) || $(esc(then))
            wait(tsk)
        end
    end
end

macro src()
    @static if VERSION >= v"0.7-" && length(:(@test).args) == 2
        esc(quote
            (__module__,
             __source__.file == nothing ? "?" : String(__source__.file),
             __source__.line)
        end)
    else
        esc(quote
            (current_module(),
             (p = Base.source_path(); p == nothing ? "REPL" : p),
             Int(unsafe_load(cglobal(:jl_lineno, Cint))))
        end)
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
    m, f, l = @src()
    if typeof(expr) == String
        e = esc(:(println("[DEBUG - ", $m, '.', $f, ":", $(rpad(l, 5, ' ')), "]: ", $(escape_string(expr)))))
    else
        e = esc(:(println("[DEBUG - ", $m, '.', $f, ":", $(rpad(l, 5, ' ')), "]: ", $(sprint(Base.show_unquoted, expr)), " = ", escape_string(string($expr)))))
    end
    return quote
        @static if $should
            $e 
        end
    end
end

macro log(stmt)
    # "[HTTP]: Connecting to remote host..."
    return esc(:(verbose && (write(logger, "[HTTP - $(rpad(now(), 23, ' '))]: $($stmt)\n"); flush(logger))))
end

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

@inline islower(b::UInt8) = UInt8('a') <= b <= UInt8('z')
@inline isupper(b::UInt8) = UInt8('A') <= b <= UInt8('Z')
@inline lower(c::UInt8) = c | 0x20
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

macro shifted(meth, i, char)
    return esc(:(Int($meth) << Int(16) | Int($i) << Int(8) | Int($char)))
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

# ensure the first character and subsequent characters that follow a '-' are uppercase
function tocameldash!(s::String)
    const toUpper = UInt8('A') - UInt8('a')
    bytes = Vector{UInt8}(s)
    upper = true
    for i = 1:length(bytes)
        @inbounds b = bytes[i]
        if upper
            islower(b) && (bytes[i] = b + toUpper)
        else
            isupper(b) && (bytes[i] = lower(b))
        end
        upper = b == UInt8('-')
    end
    return s
end

canonicalizeheaders{T}(h::T) = T(tocameldash!(k) => v for (k,v) in h)

iso8859_1_to_utf8(str::String) = iso8859_1_to_utf8(Vector{UInt8}(str))
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

macro lock(l, expr)
    esc(quote
        lock($l)
        try
            $expr
        catch
            rethrow()
        finally
            unlock($l)
        end
    end)
end
