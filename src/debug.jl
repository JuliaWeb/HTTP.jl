taskid(t=current_task()) = hex(hash(t) & 0xffff, 4)
taskid(l::ReentrantLock) = islocked(l) ? taskid(lockedby(l)) : ""

macro debug(n::Int, s)
    DEBUG_LEVEL >= n ? :(println("DEBUG: ", taskid(), " ", $(esc(s)))) :
                       :()
end

macro debugshow(n::Int, s)
    DEBUG_LEVEL >= n ? :(println("DEBUG: ", taskid(), " ",
                                 $(sprint(show_unquoted, s)), " = ",
                                 sprint(io->show(io, "text/plain",
                                                 begin value=$(esc(s)) end)))) :
                       :()

end

macro debugshort(n::Int, s)
    DEBUG_LEVEL >= n ? :(println("DEBUG: ", taskid(), " ",
                                 sprint(showcompact, $(esc(s))))) :
                       :()
end

printlncompact(x) = println(sprint(showcompact, x))

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
