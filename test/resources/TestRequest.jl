module TestRequest

export TestLayer, LastLayer

using HTTP, HTTP.Layers

struct TestLayer{Next <: Layer} <: InitialLayer
    next::Next
    wasincluded::Ref{Bool}
end
Layers.keywordforlayer(::Val{:httptestlayer}) = TestLayer
TestLayer(next; httptestlayer=Ref(false), kw...) = TestLayer(next, httptestlayer)

function Layers.request(layer::TestLayer, meth, url, headers, body; kw...)
    layer.wasincluded[] = true
    return Layers.request(layer.next, meth, url, headers, body; kw...)
end

struct LastLayer{Next <: Layer} <: ConnectionLayer
    next::Next
    wasincluded::Ref{Bool}
end
Layers.keywordforlayer(::Val{:httplastlayer}) = LastLayer
LastLayer(next; httplastlayer=Ref(false), kw...) = LastLayer(next, httplastlayer)

function Layers.request(layer::LastLayer, io::IO, req, body; kw...)
    resp = Layers.request(layer.next, io, req, body; kw...)
    layer.wasincluded[] = true
    return resp
end

end
