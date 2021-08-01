module TestRequest
import HTTP: Stack, Layer, request, Response

abstract type TestLayer <: Layer end
abstract type LastLayer <: Layer end
export TestLayer, LastLayer, request

function request(stack::Stack{TestLayer}, io::IO, req, body; kw...)::Response
    return request(stack.next, io, req, body; kw...)
end

const FLAG = Ref(false)
function request(stack::Stack{LastLayer}, resp)::Response
    FLAG[] = true
    return request(stack.next, resp)
end

end
