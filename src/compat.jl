if VERSION > v"0.7.0-DEV.2338"
    using Base64
end

@static if VERSION >= v"0.7.0-DEV.2915"
    using Unicode
end

macro uninit(expr)
    if !isdefined(Base, :uninitialized)
        splice!(expr.args, 2)
    end
    return esc(expr)
end

if !isdefined(Base, :pairs)
    pairs(x) = x
end

if VERSION < v"0.7.0-DEV.2575"
    const Dates = Base.Dates
else
    import Dates
end
