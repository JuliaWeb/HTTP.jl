"""
Iterate over byte-vectors 4-bits at a time.
"""
module Nibbles

"""
    Nibbles.Iterator(v)

Create a nibble-iterator for UInt8-vector `v`.

e.g.
```
julia> ni = Nibbles.Iterator(UInt8[0x12, 0x34])

julia> collect(ni)
4-element Array{Any,1}:
 0x01
 0x02
 0x03
 0x04

julia> ni[1], ni[2], ni[3]
(0x01, 0x02, 0x03)
```
"""
struct Iterator{T <: AbstractVector{UInt8}}
    v::T
end

Iterator() = Iterator(UInt8[])

Base.eltype(::Type{<:Iterator}) = UInt8

Base.length(n::Iterator) = length(n.v) * 2

Base.@propagate_inbounds Base.getindex(n::Iterator, i) = getindex(n, UInt(i))

Base.@propagate_inbounds(
function Base.getindex(n::Iterator, i::UInt)
    @inbounds c = n.v[((i - 1) >> 1) + 1]
    return i & 1 == 1 ? c >> 4 : c & 0x0F
end)


const State = Tuple{UInt,UInt8}
const Value = Union{Nothing, Tuple{UInt8, State}}

Base.@propagate_inbounds(
function Base.iterate(n::Iterator, state::State = (1 % UInt, 0x00))::Value
    i, c = state
    if i > length(n.v)
        return nothing
    elseif c != 0x00
        return c & 0x0F, (i + 1, 0x00)
    else
        @inbounds c = n.v[i]
        return c >> 4, (i, c | 0xF0)
    end
end)


end # module Nibbles
