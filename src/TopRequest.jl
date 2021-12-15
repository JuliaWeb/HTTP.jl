module TopRequest

import ..Layer, ..request

export TopLayer

"""
    request(TopLayer, args...; kwargs...)

This layer is at the top of every stack, and does nothing.
It's useful for inserting a custom layer at the top of the stack.
"""
struct TopLayer{Next <: Layer} <: Layer{Next} end

request(::Type{TopLayer{Next}}, args...; kwargs...) where Next =
    request(Next, args...; kwargs...)

end
