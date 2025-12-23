taskid(t=current_task()) = hex(hash(t) & 0xffff, 4)
taskid(l::ReentrantLock) = islocked(l) ? taskid(lockedby(l)) : ""

macro debug(n::Int, s)
    DEBUG_LEVEL >= n ? :(println("DEBUG: ", taskid(), " ", $(esc(s)))) :
                       :()
end

macro debugshow(n::Int, s)
    DEBUG_LEVEL >= n ? :(println("DEBUG: ", taskid(), " ",
                                 $(sprint(Base.show_unquoted, s)), " = ",
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


@noinline function precondition_error(msg, frame)
    msg = string(sprint(StackTraces.show_spec_linfo,
                        StackTraces.lookup(frame)[2]),
                 " requires ", msg)
    return ArgumentError(msg)
end


"""
    @require precondition [message]
Throw `ArgumentError` if `precondition` is false.
"""
macro require(precondition, msg = string(precondition))
    esc(:(if ! $precondition throw(precondition_error($msg, backtrace()[1])) end))
end


# FIXME
# Should this have a branch-prediction hint? (same for @assert?)
# http://llvm.org/docs/BranchWeightMetadata.html#built-in-expect-instructions

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
