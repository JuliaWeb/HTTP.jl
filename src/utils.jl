sprintcompact(x) = sprint(show, x; context=:compact => true)


macro src()
    esc(quote
        (__module__,
         __source__.file == nothing ? "?" : String(__source__.file),
         __source__.line)
    end)
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
