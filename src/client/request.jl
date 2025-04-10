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

function with_request(f::Function, client::Client, method, path, headers=nothing, body=nothing, chunkedbody=nothing, decompress::Union{Nothing, Bool}=nothing, userinfo=nothing, bearer=nothing, modifier=nothing, http2::Bool=false, cookies=true, cookiejar=COOKIEJAR, verbose=false)
    # create request
    req = Request(method, path, headers, nothing, http2, client.settings.allocator)
    # add headers to request
    h = req.headers
    if http2
        setscheme(h, client.settings.scheme)
        setauthority(h, client.settings.host)
    else
        setheader(h, "host", client.settings.host)
    end
    setheaderifabsent(h, "accept", "*/*")
    setheaderifabsent(h, "user-agent", something(USER_AGENT[], "-"))
    if decompress === nothing || decompress
        setheaderifabsent(h, "accept-encoding", "gzip")
    end
    if userinfo !== nothing
        setheaderifabsent(h, "authorization", "Basic $(base64encode(unescapeuri(userinfo)))")
    end
    if bearer !== nothing
        setheaderifabsent(h, "authorization", "Bearer $bearer")
    end
    if !http2 && chunkedbody !== nothing
        setheaderifabsent(h, "transfer-encoding", "chunked")
    end
    if headers !== nothing
        for (k, v) in headers
            addheader(h, k, v)
        end
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
        try
            setinputstream!(req, body)
        catch e
            @error "Failed to set input stream" exception=(e, catch_backtrace())
        end
    end
    # call user function
    verbose > 0 && print_request(stdout, req)
    ret = f(req)
    resp = getresponse(ret)
    verbose > 0 && print_response(stdout, resp)
    cookies === false || Cookies.setcookies!(cookiejar, client.settings.scheme, client.settings.host, req.path, resp.headers)
    return ret
end
