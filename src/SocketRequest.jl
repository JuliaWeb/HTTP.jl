module SocketRequest

import ..Layer, ..RequestStack.request
using ..Messages
import ..@debug, ..DEBUG_LEVEL

abstract type SocketLayer <: Layer end
export SocketLayer


"""
    request(SocketLayer, ::IO, ::Request, ::Response)

Send a `Request` and receive a `Response`.
Run the `Request` in a background task if response body is a stream.
"""

function request(::Type{SocketLayer}, io::IO, req::Request, res::Response; kw...)

    if !isstream(res.body)
        return writeandread(io, req, res)
    end

    @schedule try
        writeandread(io, req, res)
    catch e
        if res.exception != e
            rethrow(e)
        end
        @debug 1 "Async HTTP Message Exception!\n$e\n$io\n$req\n$res"
    end
    waitforheaders(res)
    return res
end


end # module SendRequest
