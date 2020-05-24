module TestRequest
import HTTP: Layer, request, Response

abstract type TestLayer{Next <: Layer} <: Layer{Next} end
abstract type LastLayer{Next <: Layer} <: Layer{Next} end
export TestLayer, LastLayer, request

function request(::Type{TestLayer{Next}}, io::IO, req, body; kw...)::Response where Next
		return request(Next, io, req, body; kw...)
end

const FLAG = Ref(false)
function request(::Type{LastLayer{Next}}, resp)::Response where Next
    FLAG[] = true
		return request(Next, resp)
end

end
