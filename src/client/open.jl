function _open_stream(conn::Ptr{aws_http_connection}, req::Request, decompress, readtimeout, allocator)
    http2 = aws_http_connection_get_version(conn) == AWS_HTTP_VERSION_2
    stream = Stream{Ptr{aws_http_connection}}(allocator, decompress, http2, false)
    stream.bufferstream = Base.BufferStream()
    stream.connection = conn
    stream.request = req
    stream.response = resp = Response(0, nothing, nothing, http2, allocator)
    resp.request = req
    GC.@preserve stream begin
        stream.request_options = aws_http_make_request_options(
            1,
            req.ptr,
            pointer_from_objref(stream),
            on_response_headers[],
            on_response_header_block_done[],
            on_response_body[],
            on_metrics[],
            on_complete[],
            on_destroy[],
            http2, # http2_use_manual_data_writes
            readtimeout * 1000 # response_first_byte_timeout_ms
        )
        stream_ptr = aws_http_connection_make_request(conn, FieldRef(stream, :request_options))
        stream_ptr == C_NULL && aws_throw_error()
        stream.ptr = stream_ptr
    end
    retain_stream!(stream)
    return stream
end

function open(f::Function, method::Union{String, Symbol}, url, h=Header[];
    allocator=default_aws_allocator(),
    headers=h,
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
    decompress::Union{Nothing, Bool}=nothing,
    status_exception::Bool=true,
    readtimeout::Int=0,
    modifier=nothing,
    verbose=0,
    # only client keywords in catch-all
    kw...)
    method_str = string(method)
    headers = mkreqheaders(headers, copyheaders)
    uri = parseuri(url, query, allocator)
    context = observelayers ? Dict{Symbol, Any}() : nothing
    context === nothing || _init_observations!(context)
    count = 0
    while true
        redirect_start = context === nothing ? 0.0 : time()
        redirect_url = nothing
        resp = nothing
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
        reqclient = @something(
            client,
            pool === nothing ?
                getclient(ClientSettings(scheme(uri), host(uri), getport(uri); client_kw...)) :
                getclient(ClientSettings(scheme(uri), host(uri), getport(uri); client_kw...), pool)
        )::Client
        resp = with_connection(reqclient; context=context) do conn
            http2 = aws_http_connection_get_version(conn) == AWS_HTTP_VERSION_2
            path = resource(uri)
            with_request(reqclient, method_str, path, headers, nothing, nothing, decompress, authinfo, bearer, modifier, http2, cookies, cookiejar, verbose;
                copyheaders=false,
                canonicalize_headers=canonicalize_headers,
                detect_content_type=detect_content_type,
                basicauth=apply_basicauth,
                observelayers=observelayers,
                context=context,
            ) do req
                if !http2 &&
                   method_str in ("POST", "PUT", "PATCH") &&
                   !hasheader(req.headers, "content-length") &&
                   !hasheader(req.headers, "transfer-encoding") &&
                   !hasheader(req.headers, "upgrade")
                    setheader(req.headers, "transfer-encoding", "chunked")
                end
                stream = _open_stream(conn, req, decompress, readtimeout, allocator)
                stream_start = context === nothing ? 0.0 : time()
                try
                    if redirect && issafe(method_str)
                        resp = startread(stream)
                        if (count < redirect_limit && isredirect(resp) && (location = getheader(resp.headers, "Location")) != "")
                            redirect_url = location
                            closeread(stream)
                            return resp
                        end
                    end
                    err = nothing
                    try
                        f(stream)
                    catch e
                        err = e
                    finally
                        closewrite(stream)
                    end
                    resp = closeread(stream)
                    err === nothing || throw(err)
                    return resp
                finally
                    context === nothing || _record_layer!(context, :streamlayer, stream_start)
                end
            end
        end
        context === nothing || _record_layer!(context, :redirectlayer, redirect_start)
        if redirect_url === nothing
            if status_exception && iserror(resp)
                if logerrors
                    @error "HTTP StatusError" method=method_str url=makeuri(uri) status=resp.status logtag=logtag
                end
                throw(StatusError(method_str, uri, resp))
            end
            return resp
        end
        if count == redirect_limit
            return resp
        end
        olduri = uri
        newuri = resolvereference(makeuri(uri), redirect_url)
        uri = parseuri(newuri, nothing, allocator)
        method_str = newmethod(method_str, resp.status, redirect_method)
        if forwardheaders
            headers = filter(headers) do (header, _)
                if headereq(String(header), "host")
                    return false
                elseif any(x -> headereq(x, String(header)), SENSITIVE_HEADERS) && !isdomainorsubdomain(host(uri), host(olduri))
                    return false
                elseif method_str == "GET" && (headereq(String(header), "content-type") || headereq(String(header), "content-length"))
                    return false
                else
                    return true
                end
            end
        else
            headers = Header[]
        end
        count += 1
    end
end
