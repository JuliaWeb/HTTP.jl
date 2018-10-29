"""
`StackBuffers` are backed by `NTuple{N,UInt8}` to avoid heap allocation.

See: https://github.com/JuliaArrays/StaticArrays.jl/blob/master/src/MArray.jl
"""
module StackBuffers 

export StackBuffer


mutable struct StackBuffer{N}
    data::NTuple{N,UInt8}
    StackBuffer{N}() where N = new()
end

StackBuffer(N) = StackBuffer{N}()


Base.length(::StackBuffer{N}) where N = N

Base.pointer(b::StackBuffer, i=1) =
    Base.unsafe_convert(Ptr{UInt8}, pointer_from_objref(b)) - 1 + i


Base.read!(io, b::StackBuffer{N}) where N = (unsafe_read(io, pointer(b), N); b)


Base.@propagate_inbounds Base.getindex(b::StackBuffer, i) = getindex(b.data, i)

Base.unsafe_store(b::StackBuffer, i, v::T) where T =
    unsafe_store(Ptr{T}(pointer(b, i)), v)


end # module StackBuffers
