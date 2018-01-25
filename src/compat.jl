@static if VERSION >= v"0.7.0-DEV.2915"

    using Base64
    using Distributed
    import Dates

    compat_search(s::AbstractString, c::Char) = compat_findfirst(equalto(c), s)
    compat_search(a...) = (r = search(a...); r === nothing ? 0 : r)
    compat_findfirst(a...) = (r = findfirst(a...); r === nothing ? 0 : r)
    compat_findprev(A::String, v, i::Integer) = compat_findprev(equalto(v), A, i)
    compat_findprev(a...) = (r = findprev(a...); r === nothing ? 0 : r)
    compat_findnext(A::String, v, i::Integer) = compat_findnext(equalto(v), A, i)
    compat_findnext(a...) = (r = findnext(a...); r === nothing ? 0 : r)
    compat_parse(s, T; base::Int=10) = Base.parse(s, T; base=base)

else # Julia v0.6

    eval(:(module Base64 end))
    const Dates = Base.Dates
    const Distributed = Base.Distributed

    const compat_search = search
    const compat_findfirst = findfirst
    const compat_findprev = findprev
    const compat_findnext = findnext
    compat_parse(s, T; base::Int=10) = Base.parse(s, T, base)

    pairs(x) = [k => v for (k,v) in x]

    Base.SubString(s) = SubString(s, 1)

    macro debug(s) DEBUG_LEVEL > 0 ? :(("D- ", $(esc(s)))) : :() end
    macro info(s)  DEBUG_LEVEL >= 0 ? :(println("I- ", $(esc(s)))) : :() end
    macro warn(s)  DEBUG_LEVEL >= 0 ? :(println("W- ", $(esc(s)))) : :() end
    macro error(m, args...)
        args = [:(print("|  "); @show $a) for a in args]
        esc(:(println("E- ", $m); $(args...); nothing))
    end
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

@static if !isdefined(Base, :bytesavailable)
    const bytesavailable = nb_available
else
    import Base: bytesavailable
    bytesavailable(ssl::MbedTLS.SSLContext) = nb_available(ssl)
end

@static if VERSION < v"0.7.0-DEV.2005"
    using Base.Test
else
    using Test
end

if !isdefined(Base, :isnumeric)
    const isnumeric = isnumber
end
