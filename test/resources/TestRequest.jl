module TestRequest
import HTTP: Layers, Layer, Response

abstract type TestLayer{Next <: Layer} <: Layer{Next} end
abstract type LastLayer{Next <: Layer} <: Layer{Next} end
export TestLayer, LastLayer

function Layers.request(::Type{TestLayer{Next}}, io::IO, req, body; kw...)::Response where Next
    return Layers.request(Next, io, req, body; kw...)
end

const FLAG = Ref(false)
function Layers.request(::Type{LastLayer{Next}}, resp)::Response where Next
    FLAG[] = true
    return Layers.request(Next, resp)
end

end
