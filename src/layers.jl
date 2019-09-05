module Layers
export Layer, next, top_layer, insert

include("exceptions.jl")

abstract type Layer{Next} end

"""
    next(::Type{S}) where {T, S<:Layer{T}}

Return the next `Layer` in the stack

Example:
stack = MessageLayer{ConnectionPoolLayer{StreamLayer{Union{}}}
next(stack)  # ConnectionPoolLayer{StreamLayer{Union{}}}
"""
next(::Type{S}) where {T, S<:Layer{T}} = return T

"""
    top_layer(::Type{T}) where T <: Layer

Return the parametric type of the top most `Layer` in the stack

Example:
stack = MessageLayer{ConnectionPoolLayer{StreamLayer{Union{}}}
top_layer(stack)  # MessageLayer
"""
top_layer(::Type{T}) where T <: Layer = return T.name.wrapper
top_layer(::Type{Union{}}) = return Union{}

"""
    insert(stack::Type{<:Layer}, layer_before::Type{<:Layer}, custom_layer::Type{<:Layer})

Insert your `custom_layer` in-front of the `layer_before`

Example:
stack = MessageLayer{ConnectionPoolLayer{StreamLayer{Union{}}}
result = insert(stack, MessageLayer, TestLayer)  # TestLayer{MessageLayer{ConnectionPoolLayer{StreamLayer{Union{}}}}}
"""
function insert(stack::Type{<:Layer}, layer_before::Type{<:Layer}, custom_layer::Type{<:Layer})
    new_stack = Union
    head_layer = top_layer(stack)
    rest_stack = stack

    while true
        if head_layer === layer_before
            return new_stack{custom_layer{rest_stack}}
        else
            head_layer === Union{} && break
            new_stack = new_stack{head_layer{T}} where T
            rest_stack = next(rest_stack)
            head_layer = top_layer(rest_stack)
        end
    end
    throw(LayerNotFoundException("$layer_before not found in $stack"))
end

end