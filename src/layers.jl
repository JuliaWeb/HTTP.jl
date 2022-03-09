module Layers
export Layer, InitialLayer, RequestLayer, ConnectionLayer, ResponseLayer

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
abstract type ResponseLayer <: Layer end

const LAYERS = Dict

function shouldinclude end

shouldinclude(T; kw...) = true
# custom layers must subtype one of above
# must register a keyword arg for layer
# must have a layer constructor like: Layer(next; kw...)
# must have a field to store `next` layer
# must overload: request(layer::MyLayer, args...; kw...)
# in `request` overload, must call: request(layer.next, args...; kw...)

function request end

end
