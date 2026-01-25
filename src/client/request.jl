const DEFAULT_USER_AGENT = let v = try Base.pkgversion(@__MODULE__) catch; nothing end
    v === nothing ? "HTTP.jl/dev" : "HTTP.jl/$(v)"
end
const USER_AGENT = Ref{Union{String, Nothing}}(DEFAULT_USER_AGENT)

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

function with_request(
    f::Function,
    client::Client,
    method,
    path,
    headers=nothing,
    body=nothing,
    chunkedbody=nothing,
    decompress::Union{Nothing, Bool}=nothing,
    userinfo=nothing,
    bearer=nothing,
    modifier=nothing,
    http2::Bool=false,
    cookies=true,
    cookiejar=COOKIEJAR,
    verbose=false;
    copyheaders::Bool=true,
    canonicalize_headers::Bool=false,
    detect_content_type::Bool=false,
    basicauth::Bool=true,
    observelayers::Bool=false,
    context=nothing,
)
    if chunkedbody === nothing && body isa IO && !(body isa IOStream) && !(body isa Form)
        chunkedbody = IOChunkedBody(body)
        body = nothing
    end
    if chunkedbody === nothing && body !== nothing && !(body isa RequestBodyTypes) && Base.isiterable(typeof(body))
        chunkedbody = body
        body = nothing
    end
    # create request
    mutable_headers = (headers isa AbstractVector{<:Pair} && !copyheaders) ? headers : nothing
    req_headers = mkreqheaders(headers, copyheaders)
    req = Request(method, path, req_headers, nothing, http2, client.settings.allocator; context=context)
    # add headers to request
    h = req.headers
    if http2
        setscheme(h, client.settings.scheme)
        setauthority(h, client.settings.host)
    else
        setheader(h, "host", client.settings.host)
    end
    setheaderifabsent(h, "accept", "*/*")
    if USER_AGENT[] !== nothing
        setheaderifabsent(h, "user-agent", USER_AGENT[])
    end
    if decompress === nothing || decompress
        setheaderifabsent(h, "accept-encoding", "gzip")
    end
    if basicauth && userinfo !== nothing && !isempty(userinfo)
        setheaderifabsent(h, "authorization", "Basic $(base64encode(unescapeuri(userinfo)))")
    end
    if bearer !== nothing
        setheaderifabsent(h, "authorization", "Bearer $bearer")
    end
    if !http2 && chunkedbody !== nothing
        setheaderifabsent(h, "transfer-encoding", "chunked")
    end
    if detect_content_type && !hasheader(h, "content-type") && !(body isa Form) && isbytes(body)
        setheader(h, "content-type", sniff(body))
    end
    if cookies === true || (cookies isa AbstractDict && !isempty(cookies))
        cookiestosend = Cookies.getcookies!(cookiejar, client.settings.scheme, client.settings.host, req.path)
        if !(cookies isa Bool)
            for (name, value) in cookies
                push!(cookiestosend, Cookie(name, value))
            end
        end
        if !isempty(cookiestosend)
            setheader(req.headers, "Cookie", stringify("", cookiestosend))
        end
    end
    # modifier
    if modifier !== nothing
        newbody = modifier(req, body)
        if newbody !== nothing
            setinputstream!(req, newbody)
        else
            setinputstream!(req, body)
        end
    elseif body !== nothing
        setinputstream!(req, body)
    end
    if canonicalize_headers && !http2
        canonicalizeheaders!(h)
    end
    if mutable_headers !== nothing
        sync_headers!(mutable_headers, h)
    end
    # call user function
    verbose > 0 && print_request(stdout, req)
    start_time = time()
    ret = nothing
    try
        ret = f(req)
        resp = getresponse(ret)
        if canonicalize_headers
            canonicalizeheaders!(resp.headers)
        end
        verbose > 0 && print_response(stdout, resp)
        cookies === false || Cookies.setcookies!(cookiejar, client.settings.scheme, client.settings.host, req.path, resp.headers)
        return ret
    finally
        req.context[:total_request_duration_ms] = (time() - start_time) * 1000
        observelayers && _record_layer!(req.context, :messagelayer, start_time)
    end
end
