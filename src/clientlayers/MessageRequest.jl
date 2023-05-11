module MessageRequest

using URIs, LoggingExtras
using ..IOExtras, ..Messages, ..Parsers, ..Exceptions
using ..Messages, ..Parsers
using ..Strings: HTTPVersion
import ..DEBUG_LEVEL

export messagelayer

# like Messages.mkheaders, but we want to make a copy of user-provided headers
# and avoid double copy when no headers provided (very common)
mkreqheaders(::Nothing, ch) = Header[]
mkreqheaders(headers::Headers, ch) = ch ? copy(headers) : headers
mkreqheaders(h, ch) = mkheaders(h)

"""
    messagelayer(handler) -> handler

Construct a [`Request`](@ref) object from method, url, headers, and body.
Hard-coded as the first layer in the request pipeline.
"""
function messagelayer(handler)
    return function makerequest(method::String, url::URI, headers, body; copyheaders::Bool=true, response_stream=nothing, http_version=HTTPVersion(1, 1), verbose=DEBUG_LEVEL[], kw...)
        req = Request(method, resource(url), mkreqheaders(headers, copyheaders), body; url=url, version=http_version, responsebody=response_stream)
        local resp
        start_time = time()
        try
            # if debugging, enable by wrapping request in custom logger logic
            resp = if verbose > 0
                LoggingExtras.withlevel(Logging.Debug; verbosity=verbose) do
                    handler(req; verbose, response_stream, kw...)
                end
            else
                handler(req; verbose, response_stream, kw...)
            end
        catch e
            if e isa CapturedException
                e = e.ex
            end
            if e isa StatusError
                resp = e.response
            end
            rethrow(e)
        finally
            dur = (time() - start_time) * 1000
            req.context[:total_request_duration_ms] = dur
            if @isdefined(resp) && iserror(resp) && haskey(resp.request.context, :response_body)
                if isbytes(resp.body)
                    resp.body = resp.request.context[:response_body]
                else
                    write(resp.body, resp.request.context[:response_body])
                end
            end
        end
    end
end

end # module MessageRequest
