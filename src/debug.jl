taskid(t=current_task()) = string(hash(t) & 0xffff, base=16, pad=4)

debug_header() = string("DEBUG: ", rpad(Dates.now(), 24), taskid(), " ")

macro debug(n::Int, s)
    DEBUG_LEVEL[] >= n ? :(println(debug_header(), $(esc(s)))) :
                         :()
end

macro debugshow(n::Int, s)
    DEBUG_LEVEL[] >= n ? :(println(debug_header(),
                                   $(sprint(Base.show_unquoted, s)), " = ",
                                   sprint(io->show(io, "text/plain",
                                                   begin value=$(esc(s)) end)))) :
                         :()

end

macro debugshort(n::Int, s)
    DEBUG_LEVEL[] >= n ? :(println(debug_header(),
                                   sprintcompact($(esc(s))))) :
                         :()
end

sprintcompact(x) = sprint(show, x; context=:compact => true)
printlncompact(x) = println(sprintcompact(x))


function method_name(bt)
    for f in bt
        for i in StackTraces.lookup(f)
            n = sprint(StackTraces.show_spec_linfo, i)
            if n != "macro expansion"
                return n
            end
        end
    end
    return "unknown method"
end

@noinline function precondition_error(msg, bt)
    msg = string(method_name(bt), " requires ", msg)
    return ArgumentError(msg)
end


"""
    @require precondition [message]
Throw `ArgumentError` if `precondition` is false.
"""
macro require(condition, msg = string(condition))
    esc(:(if ! $condition throw(precondition_error($msg, backtrace())) end))
end


@noinline function postcondition_error(msg, bt, ls="", l="", rs="", r="")
    msg = string(method_name(bt), " failed to ensure ", msg)
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

    if DEBUG_LEVEL[] < 0
        return :()
    end

    if iscondition(condition)
        l,r = condition.args[2], condition.args[3]
        ls, rs = string(l), string(r)
        return esc(quote
            if ! $condition
                # FIXME double-execution of condition l and r!
                throw(postcondition_error($msg, backtrace(),
                                          $ls, $l, $rs, $r))
            end
        end)
    end

    esc(:(if ! $condition throw(postcondition_error($msg, backtrace())) end))
end
