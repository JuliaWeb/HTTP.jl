get(a...; kw...) = request("GET", a...; kw...)
put(a...; kw...) = request("PUT", a...; kw...)
post(a...; kw...) = request("POST", a...; kw...)
delete(a...; kw...) = request("DELETE", a...; kw...)
patch(a...; kw...) = request("PATCH", a...; kw...)
head(a...; kw...) = request("HEAD", a...; kw...)
options(a...; kw...) = request("OPTIONS", a...; kw...)

const COOKIEJAR = CookieJar()
const DEFAULT_PROXY = Symbol("__HTTP_DEFAULT_PROXY__")

_something(x, y) = x === nothing ? y : x

# proxy keyword handling
function proxy_kwargs(proxy, req_scheme)
    if proxy === DEFAULT_PROXY
        return NamedTuple()
    elseif proxy === nothing || proxy === false
        return (proxy_allow_env_var=false,)
    elseif proxy isa AbstractString || proxy isa URI
        p = proxy isa URI ? proxy : URI(String(proxy))
        isempty(p.host) && throw(ArgumentError("proxy URL must include a host"))
        port = isempty(p.port) ? (p.scheme == "https" ? 443 : 80) : parse(Int, p.port)
        conn_type = req_scheme in ("https", "wss") ? :tunnel : :forward
        if isempty(p.userinfo)
            return (proxy_allow_env_var=false, proxy_host=p.host, proxy_port=UInt32(port), proxy_connection_type=conn_type)
        end
        parts = split(p.userinfo, ":"; limit=2)
        proxy_user = unescapeuri(parts[1])
        proxy_pass = length(parts) == 2 ? unescapeuri(parts[2]) : ""
        return (proxy_allow_env_var=false, proxy_host=p.host, proxy_port=UInt32(port), proxy_connection_type=conn_type,
            proxy_auth=:basic, proxy_username=proxy_user, proxy_password=proxy_pass)
    else
        throw(ArgumentError("proxy must be a URL String, URI, nothing, or false"))
    end
end

# main entrypoint for making an HTTP request
# can provide method, url, headers, body, along with various keyword arguments
function request(method, url, h=Header[], b=nothing;
    allocator=default_aws_allocator(),
    headers=h,
    body=b,
    chunkedbody=nothing,
    copyheaders::Bool=true,
    canonicalize_headers::Bool=false,
    detect_content_type::Bool=false,
    username=nothing,
    password=nothing,
    bearer=nothing,
    query=nothing,
    client::Union{Nothing, Client}=nothing,
    basicauth::Bool=true,
    proxy=DEFAULT_PROXY,
    pool=nothing,
    logerrors::Bool=false,
    logtag=nothing,
    observelayers::Bool=false,
    retry_check=nothing,
    retry_delays=nothing,
    # redirect options
    redirect=true,
    redirect_limit=3,
    redirect_method=nothing,
    forwardheaders=true,
    # cookie options
    cookies=true,
    cookiejar::CookieJar=COOKIEJAR,
    # response options
    response_stream=nothing, # compat
    response_body=response_stream,
    decompress::Union{Nothing, Bool}=nothing,
    status_exception::Bool=true,
    readtimeout::Int=0, # only supported for HTTP 1.1, not HTTP 2 (current aws limitation)
    retry_non_idempotent::Bool=false,
    modifier=nothing,
    verbose=0,
    # only client keywords in catch-all
    kw...)
    context = observelayers ? Dict{Symbol, Any}() : nothing
    context === nothing || _init_observations!(context)
    if chunkedbody === nothing && body isa IO && !(body isa IOStream) && !(body isa Form)
        chunkedbody = IOChunkedBody(body)
        body = nothing
    end
    if chunkedbody === nothing && body !== nothing && !(body isa RequestBodyTypes) && Base.isiterable(typeof(body))
        chunkedbody = body
        body = nothing
    end
    retryable_body = chunkedbody === nothing && (
        body === nothing ||
        body isa AbstractString ||
        body isa AbstractVector{UInt8} ||
        body isa AbstractDict ||
        body isa NamedTuple ||
        body isa Form
    )
    headers = mkreqheaders(headers, copyheaders)
    uri = parseuri(url, query, allocator)
    proxy_kw = proxy_kwargs(proxy, scheme(uri))
    client_kw = (; allocator=allocator, kw...)
    if pool isa Pool && pool.max_connections !== nothing && !haskey(client_kw, :max_connections)
        client_kw = merge(client_kw, (; max_connections=pool.max_connections))
    end
    if !isempty(proxy_kw)
        client_kw = merge(client_kw, proxy_kw)
    end
    authinfo = (username !== nothing && password !== nothing) ? "$username:$password" : userinfo(uri)
    apply_basicauth = (username !== nothing && password !== nothing) ? true : basicauth
    return with_redirect(allocator, method, uri, headers, body, redirect, redirect_limit, redirect_method, forwardheaders; context=context) do method, uri, headers, body
        reqclient = @something(
            client,
            pool === nothing ?
                getclient(ClientSettings(scheme(uri), host(uri), getport(uri); client_kw...)) :
                getclient(ClientSettings(scheme(uri), host(uri), getport(uri); client_kw...), pool)
        )::Client
        req_ref = Ref{Any}(nothing)
        with_retry_token(reqclient; logerrors=logerrors, logtag=logtag, method=method, uri=uri,
            retry_check=retry_check, retry_delays=retry_delays,
            retry_non_idempotent=retry_non_idempotent, retryable_body=retryable_body, req_ref=req_ref, context=context) do
            resp = if reqclient.http2_stream_manager != C_NULL
                path = resource(uri)
                with_request(reqclient, method, path, headers, body, chunkedbody, decompress, authinfo, bearer, modifier, true, cookies, cookiejar, verbose;
                    copyheaders=false,
                    canonicalize_headers=canonicalize_headers,
                    detect_content_type=detect_content_type,
                    basicauth=apply_basicauth,
                    observelayers=observelayers,
                    context=context,
                ) do req
                    req_ref[] = req
                    if response_body isa AbstractVector{UInt8}
                        ref = Ref(1)
                        GC.@preserve ref begin
                            on_stream_response_body = BufferOnResponseBody(response_body, Base.unsafe_convert(Ptr{Int}, ref))
                            with_stream_manager(reqclient, req, chunkedbody, on_stream_response_body, decompress, readtimeout, allocator; context=context)
                        end
                    elseif response_body isa IO
                        on_stream_response_body = IOOnResponseBody(response_body)
                        with_stream_manager(reqclient, req, chunkedbody, on_stream_response_body, decompress, readtimeout, allocator; context=context)
                    else
                        with_stream_manager(reqclient, req, chunkedbody, response_body, decompress, readtimeout, allocator; context=context)
                    end
                end
            else
                with_connection(reqclient; context=context) do conn
                    http2 = aws_http_connection_get_version(conn) == AWS_HTTP_VERSION_2
                    path = resource(uri)
                    with_request(reqclient, method, path, headers, body, chunkedbody, decompress, authinfo, bearer, modifier, http2, cookies, cookiejar, verbose;
                        copyheaders=false,
                        canonicalize_headers=canonicalize_headers,
                        detect_content_type=detect_content_type,
                        basicauth=apply_basicauth,
                        observelayers=observelayers,
                        context=context,
                    ) do req
                        req_ref[] = req
                        if response_body isa AbstractVector{UInt8}
                            ref = Ref(1)
                            GC.@preserve ref begin
                                on_stream_response_body = BufferOnResponseBody(response_body, Base.unsafe_convert(Ptr{Int}, ref))
                                with_stream(conn, req, chunkedbody, on_stream_response_body, decompress, http2, readtimeout, allocator; context=context)
                            end
                        elseif response_body isa IO
                            on_stream_response_body = IOOnResponseBody(response_body)
                            with_stream(conn, req, chunkedbody, on_stream_response_body, decompress, http2, readtimeout, allocator; context=context)
                        else
                            with_stream(conn, req, chunkedbody, response_body, decompress, http2, readtimeout, allocator; context=context)
                        end
                    end
                end
            end
            # status error check
            if status_exception && iserror(resp)
                if logerrors
                    @error "HTTP StatusError" method=method url=makeuri(uri) status=resp.status logtag=logtag
                end
                throw(StatusError(method, uri, resp))
            end
            return resp
        end
    end
end
