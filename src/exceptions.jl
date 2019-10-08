struct LayerNotFoundException <: Exception
    var::String
end

function Base.showerror(io::IO, e::LayerNotFoundException)
    println(io, typeof(e), ": ", e.var)
end
