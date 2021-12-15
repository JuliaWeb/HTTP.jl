module Layers
export Layer, keywordforlayer

struct LayerNotFoundException <: Exception
    var::String
end

function Base.showerror(io::IO, e::LayerNotFoundException)
    println(io, typeof(e), ": ", e.var)
end

abstract type Layer end

abstract type InitialLayer <: Layer end
abstract type RequestLayer <: Layer end
abstract type ConnectionLayer <: Layer end

function keywordforlayer end

keywordforlayer(kw) = nothing
# custom layers must subtype one of above
# must register a keyword arg for layer
# must have a layer constructor like: Layer(next; kw...)
# must have a field to store `next` layer
# must overload: request(layer::MyLayer, args...; kw...)
# in `request` overload, must call: request(layer.next, args...; kw...)

"""
    next(::Type{S}) where {T, S<:Layer{T}}

Return the next `Layer` in the stack

Example:
stack = MessageLayer{ConnectionPoolLayer{StreamLayer{Union{}}}
next(stack)  # ConnectionPoolLayer{StreamLayer{Union{}}}
"""
next(::Type{S}) where {T, S<:Layer{T}} = T

"""
    top_layer(::Type{T}) where T <: Layer

Return the parametric type of the top most `Layer` in the stack

Example:
stack = MessageLayer{ConnectionPoolLayer{StreamLayer{Union{}}}
top_layer(stack)  # MessageLayer
"""
top_layer(::Type{T}) where T <: Layer = T.name.wrapper
top_layer(::Type{Union{}}) = Union{}

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

insert_default!(before::Type{<:Layer}, custom_layer::Type{<:Layer}) =
    push!(EXTRA_LAYERS, (before, custom_layer))

remove_default!(before::Type{<:Layer}, custom_layer::Type{<:Layer}) =
    delete!(EXTRA_LAYERS, (before, custom_layer))

end
