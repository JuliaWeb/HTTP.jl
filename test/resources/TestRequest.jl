module TestRequest

export TestLayer, LastLayer

using HTTP, HTTP.Layers

struct TestLayer{Next <: Layer} <: InitialLayer
    next::Next
    wasincluded::Ref{Bool}
end
TestLayer(next; httptestlayer=Ref(false), kw...) = TestLayer(next, httptestlayer)

function Layers.request(layer::TestLayer, ctx, meth, url, headers, body)
    layer.wasincluded[] = true
    return Layers.request(layer.next, ctx, meth, url, headers, body)
end

HTTP.@client TestLayer

# struct LastLayer{Next <: Layer} <: ConnectionLayer
#     next::Next
#     wasincluded::Ref{Bool}
# end
# Layers.keywordforlayer(::Val{:httplastlayer}) = LastLayer
# LastLayer(next; httplastlayer=Ref(false), kw...) = LastLayer(next, httplastlayer)

# function Layers.request(layer::LastLayer, io::IO, req, body; kw...)
#     resp = Layers.request(layer.next, io, req, body; kw...)
#     layer.wasincluded[] = true
#     return resp
# end

end
