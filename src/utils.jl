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


macro log(stmt)
    # "[HTTP]: Connecting to remote host..."
    return esc(:(verbose && (write(logger, "[HTTP - $(rpad(Dates.now(), 23, ' '))]: $($stmt)\n"); flush(logger))))
end

macro catcherr(etype, expr)
    esc(quote
        try
            $expr
        catch e
            isa(e, $etype) ? e : rethrow(e)
        end
    end)
end
