@static if VERSION >= v"0.7.0-DEV.2915"

    using Base64
    import Dates

else # Julia v0.6

    eval(:(module Base64 end))
    const Dates = Base.Dates

    pairs(x) = [k => v for (k,v) in x]

    Base.SubString(s) = SubString(s, 1)

    macro debug(s) DEBUG_LEVEL > 0 ? :(("D- ", $(esc(s)))) : :() end
    macro info(s)  DEBUG_LEVEL > 0 ? :(println("I- ", $(esc(s)))) : :() end
    macro warn(s)  DEBUG_LEVEL > 0 ? :(println("W- ", $(esc(s)))) : :() end
    macro error(s, a...) DEBUG_LEVEL > 0 ? :(println("E- ", $(esc((s, a...))))) : :() end
end

macro uninit(expr)
    if !isdefined(Base, :uninitialized)
        splice!(expr.args, 2)
    end
    return esc(expr)
end

if !isdefined(Base, :Nothing)
    const Nothing = Void
    const Cvoid = Void
end

# https://github.com/JuliaLang/julia/pull/25535
Base.String(x::SubArray{UInt8,1}) = String(Vector{UInt8}(x))
