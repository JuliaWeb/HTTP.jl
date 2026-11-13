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

if !isdefined(Base, :Nothing)
    const Nothing = Void
    const Cvoid = Void
end

if VERSION < v"0.7.0-DEV.2575"
    const Dates = Base.Dates
else
    import Dates
end

@static if VERSION >= v"0.7.0-DEV.2915"
    lockedby(l) = l.locked_by
else
    lockedby(l) = get(l.locked_by)
end

Base.String(x::SubArray{UInt8,1}) = String(Vector{UInt8}(x))
