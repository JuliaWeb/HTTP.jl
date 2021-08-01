module Layers
export Layer, next, top_layer, insert, insert_default!, remove_default!

const EXTRA_LAYERS = Set{Tuple{Union{UnionAll, Type{Union{}}}, UnionAll}}()

include("exceptions.jl")

"""
## Request Execution Stack

The Request Execution Stack is separated into composable layers.

Each layer is defined by a nested type `Layer{Next}` where the `Next`
parameter defines the next layer in the stack.
The `request` method for each layer takes a `Layer{Next}` type as
its first argument and dispatches the request to the next layer
using `request(Next, ...)`.

The example below defines three layers and three stacks each with
a different combination of layers.


```julia
abstract type Layer end
abstract type Layer1{Next <: Layer} <: Layer end
abstract type Layer2{Next <: Layer} <: Layer end
abstract type Layer3 <: Layer end

request(::Type{Layer1{Next}}, data) where Next = "L1", request(Next, data)
request(::Type{Layer2{Next}}, data) where Next = "L2", request(Next, data)
request(::Type{Layer3}, data) = "L3", data

const stack1 = Layer1{Layer2{Layer3}}
const stack2 = Layer2{Layer1{Layer3}}
const stack3 = Layer1{Layer3}
```

```julia
julia> request(stack1, "foo")
("L1", ("L2", ("L3", "foo")))

julia> request(stack2, "bar")
("L2", ("L1", ("L3", "bar")))

julia> request(stack3, "boo")
("L1", ("L3", "boo"))
```

This stack definition pattern gives the user flexibility in how layers are
combined but still allows Julia to do whole-stack compile time optimisations.

e.g. the `request(stack1, "foo")` call above is optimised down to a single
function:
```julia
julia> code_typed(request, (Type{stack1}, String))[1].first
CodeInfo(:(begin
    return (Core.tuple)("L1", (Core.tuple)("L2", (Core.tuple)("L3", data)))
end))
```
"""
abstract type Layer{Next} end

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
    insert(stack, layer_before::Type{<:Layer}, custom_layer::Type{<:Layer})

Insert your `custom_layer` in-front of the `layer_before`

Example:
stack = MessageLayer{ConnectionPoolLayer{StreamLayer{Union{}}}
result = insert(stack, MessageLayer, TestLayer)  # TestLayer{MessageLayer{ConnectionPoolLayer{StreamLayer{Union{}}}}}
"""
function insert(stack, layer_before::Type{<:Layer}, custom_layer::Type{<:Layer})
    new_stack = Union
    head_layer = top_layer(stack)
    rest_stack = stack

    while true
        if head_layer === layer_before
            return 1 # Stack{custom_layer}(rest_stack)
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
