function _precompile_2()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    precompile(Core.Inference.getindex, (Tuple{UInt8, Array{Any, 1}}, Int64,))
    precompile(Core.Type, (Type{Expr}, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any, Any,))
    precompile(Core.Inference.getindex, (Tuple{Float64, Array{Any, 1}}, Int64,))
end
