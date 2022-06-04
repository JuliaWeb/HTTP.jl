module MessageRequest

using URIs
using ..Messages, ..Parsers

export messagelayer

"""
    messagelayer(method, ::URI, headers, body) -> HTTP.Response

Construct a [`Request`](@ref) object.
"""
function messagelayer(handler)
    return function(method::String, url::URI, headers::Headers, body; response_stream=nothing, http_version=v"1.1", kw...)
        req = Request(method, resource(url), headers, body; url=url, version=http_version, responsebody=response_stream)
        return handler(req; response_stream=response_stream, kw...)
    end
end

end # module MessageRequest
