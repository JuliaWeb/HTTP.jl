module HeadersRequest

export headerslayer, setuseragent!

using Base64, URIs, LoggingExtras
using ..Messages, ..Forms, ..IOExtras, ..Sniff, ..Forms, ..Strings

"""
    headerslayer(handler) -> handler

Sets default expected headers.
"""
function headerslayer(handler)
    return function defaultheaders(req; iofunction=nothing, decompress=nothing,
            basicauth::Bool=true, detect_content_type::Bool=false, canonicalize_headers::Bool=false, kw...)
        headers = req.headers
        ## basicauth
        if basicauth
            userinfo = unescapeuri(req.url.userinfo)
            if !isempty(userinfo) && !hasheader(headers, "Authorization")
                @debugv 1 "Adding Authorization: Basic header."
                setheader(headers, "Authorization" => "Basic $(base64encode(userinfo))")
            end
        end
        ## content type detection
        if detect_content_type && (!hasheader(headers, "Content-Type")
            && !isa(req.body, Form)
            && isbytes(req.body))

            sn = sniff(bytes(req.body))
            setheader(headers, "Content-Type" => sn)
            @debugv 1 "setting Content-Type header to: $sn"
        end
        ## default headers
        if isempty(req.url.port) ||
            (req.url.scheme == "http" && req.url.port == "80") ||
            (req.url.scheme == "https" && req.url.port == "443")
            hostheader = req.url.host
        else
            hostheader = req.url.host * ":" * req.url.port
        end
        defaultheader!(headers, "Host" => hostheader)
        defaultheader!(headers, "Accept" => "*/*")
        if USER_AGENT[] !== nothing
            defaultheader!(headers, "User-Agent" => USER_AGENT[])
        end

        if !hasheader(headers, "Content-Length") &&
        !hasheader(headers, "Transfer-Encoding") &&
        !hasheader(headers, "Upgrade")
            l = nbytes(req.body)
            if l !== nothing
                setheader(headers, "Content-Length" => string(l))
            elseif req.method == "GET" && iofunction isa Function
                setheader(headers, "Content-Length" => "0")
            end
        end
        if !hasheader(headers, "Content-Type") && req.body isa Form && req.method in ("POST", "PUT", "PATCH")
            # "Content-Type" => "multipart/form-data; boundary=..."
            setheader(headers, content_type(req.body))
        elseif !hasheader(headers, "Content-Type") && (req.body isa Union{AbstractDict, NamedTuple}) && req.method in ("POST", "PUT", "PATCH")
            setheader(headers, "Content-Type" => "application/x-www-form-urlencoded")
        end
        if decompress === nothing || decompress
            defaultheader!(headers, "Accept-Encoding" => "gzip")
        end
        ## canonicalize headers
        if canonicalize_headers
            req.headers = canonicalizeheaders(headers)
        end
        res = handler(req; iofunction, decompress, kw...)
        if canonicalize_headers
            res.headers = canonicalizeheaders(res.headers)
        end
        return res
    end
end

canonicalizeheaders(h::T) where {T} = T([tocameldash(k) => v for (k,v) in h])

const USER_AGENT = Ref{Union{String, Nothing}}("HTTP.jl/$VERSION")

"""
    setuseragent!(x::Union{String, Nothing})

Set the default User-Agent string to be used in each HTTP request.
Can be manually overridden by passing an explicit `User-Agent` header.
Setting `nothing` will prevent the default `User-Agent` header from being passed.
"""
function setuseragent!(x::Union{String, Nothing})
    USER_AGENT[] = x
    return
end

end # module
