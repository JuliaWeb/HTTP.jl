using ..Dates

taskid(t=current_task()) = compat_string(hash(t) & 0xffff, base=16, pad=4)

debug_header() = string("DEBUG: ", rpad(now(), 24), taskid(), " ")

macro debug(n::Int, s)
    DEBUG_LEVEL >= n ? :(println(debug_header(), $(esc(s)))) :
                       :()
end

macro debugshow(n::Int, s)
    DEBUG_LEVEL >= n ? :(println(debug_header(),
                                 $(sprint(Base.show_unquoted, s)), " = ",
                                 sprint(io->show(io, "text/plain",
                                                 begin value=$(esc(s)) end)))) :
                       :()

end

macro debugshort(n::Int, s)
    DEBUG_LEVEL >= n ? :(println(debug_header(),
                                 sprintcompact($(esc(s))))) :
                       :()
end

printlncompact(x) = println(sprintcompact(x))


@noinline function precondition_error(msg, frame)
    msg = string(#=sprint(StackTraces.show_spec_linfo,
                        StackTrace0.lookup(frame)[2])=# "function",
                 " requires ", msg)
    return ArgumentError(msg)
end


"""
    @require precondition [message]
Throw `ArgumentError` if `precondition` is false.
"""
macro require(condition, msg = string(condition))
    esc(:(if ! $condition throw(precondition_error($msg, backtrace()[1])) end))
end


@noinline function postcondition_error(msg, frame, ls="", l="", rs="", r="")
    msg = string(#= sprint(StackTraces.show_spec_linfo,
                        StackTraces.lookup(frame)[2]) =# "function",
                 " failed to ensure ", msg)
    if ls != ""
        msg = string(msg, "\n", ls, " = ", sprint(show, l),
                          "\n", rs, " = ", sprint(show, r))
    end
    return AssertionError(msg)
end


# Copied from stdlib/Test/src/Test.jl:get_test_result()
iscondition(ex) = isa(ex, Expr) &&
                  ex.head == :call &&
                  length(ex.args) == 3 &&
                  first(string(ex.args[1])) != '.' &&
                  (!isa(ex.args[2], Expr) || ex.args[2].head != :...) &&
                  (!isa(ex.args[3], Expr) || ex.args[3].head != :...) &&
                  (ex.args[1] === :(==) ||
                       Base.operator_precedence(ex.args[1]) ==
                           Base.operator_precedence(:(==)))


"""
    @ensure postcondition [message]
Throw `ArgumentError` if `postcondition` is false.
"""
macro ensure(condition, msg = string(condition))

    if DEBUG_LEVEL < 0
        return :()
    end

    if iscondition(condition)
        l,r = condition.args[2], condition.args[3]
        ls, rs = string(l), string(r)
        return esc(quote
            if ! $condition
                # FIXME double-execution of condition l and r!
                throw(postcondition_error($msg, backtrace()[1],
                                          $ls, $l, $rs, $r))
            end
        end)
    end

    esc(:(if ! $condition throw(postcondition_error($msg, backtrace()[1])) end))
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
