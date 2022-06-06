
module Conditions

export @require, @ensure, precondition_error, postcondition_error

import ..DEBUG_LEVEL

# Get the calling function. See https://github.com/JuliaLang/julia/issues/6733
# (The macro form @__FUNCTION__ is hard to escape correctly, so just us a function.)
function _funcname_expr()
    return :($(esc(Expr(:isdefined, Symbol("#self#")))) ? nameof($(esc(Symbol("#self#")))) : nothing)
end

@noinline function precondition_error(msg, calling_funcname)
    calling_funcname = calling_funcname === nothing ? "unknown" : calling_funcname
    return ArgumentError("$calling_funcname() requires $msg")
end


"""
    @require precondition [message]
Throw `ArgumentError` if `precondition` is false.
"""
macro require(condition, msg = "`$condition`")
    :(if ! $(esc(condition)) throw(precondition_error($(esc(msg)), $(_funcname_expr()))) end)
end

@noinline function postcondition_error(msg, calling_funcname, ls="", l="", rs="", r="")
    calling_funcname = calling_funcname === nothing ? "unknown" : calling_funcname
    msg = "$calling_funcname() failed to ensure $msg"
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
macro ensure(condition, msg = "`$condition`")

    if DEBUG_LEVEL[] < 0
        return :()
    end

    if iscondition(condition)
        l,r = condition.args[2], condition.args[3]
        ls, rs = string(l), string(r)
        return quote
            if ! $(esc(condition))
                # FIXME double-execution of condition l and r!
                throw(postcondition_error($(esc(msg)), $(_funcname_expr()),
                                          $ls, $(esc(l)), $rs, $(esc(r))))
            end
        end
    end

    :(if ! $(esc(condition)) throw(postcondition_error($(esc(msg)), $(_funcname_expr()))) end)
end

end # module