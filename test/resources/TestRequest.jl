module TestRequest
	import HTTP: Layer, request, Response

	abstract type TestLayer{Next <: Layer} <: Layer{Next} end
	export TestLayer, request

	function request(::Type{TestLayer{Next}}, io::IO, req, body; kw...)::Response where Next
		return request(Next, io, req, body; kw...)
	end
end