module SocketRequest

import ..Layer, ..RequestStack.request
using ..Messages

abstract type SocketLayer <: Layer end
export SocketLayer


"""
    request(SocketLayer, ::IO, ::Request, ::Response)

Send a `Request` and receive a `Response`.
Run the `Request` in a background task if response body is a stream.
"""

function request(::Type{SocketLayer}, io::IO, req::Request, res::Response)

    if isstream(res.body)
        @schedule writeandread(io, req, res)
        waitforheaders(res)
        return res
    end
        
    return writeandread(io, req, res)
end


end # module SendRequest
