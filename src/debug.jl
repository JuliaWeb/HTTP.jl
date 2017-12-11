macro debug(n::Int, s)
    DEBUG_LEVEL >= n ? esc(:(println(string("DEBUG: ", $s)))) : :()
end

macro debugshow(n::Int, s)
    DEBUG_LEVEL >= n ? esc(:(print("DEBUG: "); @show $s)) : :()
end

#=
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
=#
